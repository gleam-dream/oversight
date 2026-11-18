import gleam/list
import gleam/option.{Some}
import pages/outside_world
import pages/outside_world/flows.{
  type Walk, AnswersDirectly, AsksForInput, ChooseHandler, ChooseMail,
  ChooseOutcome, ChoosePolicy, ChooseToken, ChooseTool, CorreioFlow,
  HellhoundFlow, LlmWireFlow, MagicLink, MissingToken, OutcomeUnknown, Refuses,
  RelayFlow,
}
import site/context
import site/motion
import site/msc
import site/progress
import site/tour.{Free, Guided, Paused}

// FLOWS -----------------------------------------------------------------------

fn titles(walk: Walk) -> List(String) {
  list.map(flows.steps(walk), fn(step) { step.title })
}

pub fn llm_wire_grows_a_tool_round_test() {
  assert flows.total(flows.start) == 10
  let direct = flows.flip(flows.start, ChooseTool(AnswersDirectly))
  assert flows.total(direct) == 6
  let refused = flows.flip(flows.start, ChoosePolicy(Refuses))
  assert list.contains(titles(refused), "Refuse it")
  assert !list.contains(titles(refused), "Authorize and run it")
}

pub fn the_policy_option_only_shows_with_a_tool_request_test() {
  let rows = flows.option_rows(LlmWireFlow, flows.default_choices)
  assert list.length(rows) == 2
  let direct = flows.choose(flows.default_choices, ChooseTool(AnswersDirectly))
  assert list.length(flows.option_rows(LlmWireFlow, direct)) == 1
  // The hidden choice is remembered.
  let refused = flows.choose(flows.default_choices, ChoosePolicy(Refuses))
  let back =
    refused
    |> flows.choose(ChooseTool(AnswersDirectly))
    |> flows.choose(ChooseTool(flows.AsksForTool))
  assert back.policy == Refuses
}

pub fn relay_rejects_a_missing_token_before_any_handler_test() {
  let walk =
    flows.pick_flow(flows.start, RelayFlow)
    |> flows.flip(ChooseToken(MissingToken))
  assert titles(walk) == ["Discover tools", "Admit the request", "Rejected"]
  assert list.length(flows.option_rows(RelayFlow, walk.choices)) == 1
  let asking =
    flows.pick_flow(flows.start, RelayFlow)
    |> flows.flip(ChooseHandler(AsksForInput))
  assert list.contains(titles(asking), "Your handler: Ask for more input")
}

pub fn hellhound_and_correio_paths_test() {
  let hell = flows.pick_flow(flows.start, HellhoundFlow)
  assert flows.total(hell) == 9
  let hell = flows.flip(hell, flows.ChooseLater(flows.StopsAtSignIn))
  assert flows.total(hell) == 6
  let mail =
    flows.pick_flow(flows.start, CorreioFlow)
    |> flows.flip(ChooseOutcome(OutcomeUnknown))
  assert list.drop(titles(mail), 4) == ["OutcomeUnknown", "Decide"]
  let magic = flows.flip(mail, ChooseMail(MagicLink))
  assert flows.total(magic) == 7
  assert list.length(flows.option_rows(CorreioFlow, magic.choices)) == 1
}

pub fn stepping_stays_inside_the_flow_test() {
  let walk = flows.start
  assert flows.current(walk) == 1
  assert flows.current(flows.back(walk)) == 1
  let walk = flows.forward(walk) |> flows.forward
  assert flows.current(walk) == 3
  let all = flows.show_all(walk)
  assert flows.current(all) == 10
  assert flows.current(flows.forward(all)) == 10
}

pub fn a_shorter_path_clamps_the_step_and_a_longer_one_restores_it_test() {
  let all = flows.show_all(flows.start)
  let direct = flows.flip(all, ChooseTool(AnswersDirectly))
  assert flows.current(direct) == 6
  assert flows.current(flows.back(direct)) == 5
  let restored = flows.flip(direct, ChooseTool(flows.AsksForTool))
  assert flows.current(restored) == 10
}

pub fn picking_a_flow_starts_at_its_first_step_test() {
  let walk = flows.show_all(flows.start) |> flows.pick_flow(HellhoundFlow)
  assert flows.current(walk) == 1
}

pub fn the_chart_turns_lane_changes_into_messages_test() {
  let events = flows.events(flows.steps(flows.start))
  let assert [first, second, ..] = events
  assert first == msc.Note(at: 0, label: "Build a request", colour: msc.Amber)
  assert second == msc.send(0, 1, "prepare", msc.Pink)
  let chart = flows.chart(flows.forward(flows.start))
  assert chart.upto == Some(2)
  assert chart.active == Some(1)
  assert chart.lane_gap == 190
}

// THE TOUR --------------------------------------------------------------------

fn send(
  model: outside_world.Model,
  command: tour.Command,
) -> outside_world.Model {
  let context = context.new(motion.On, progress.empty())
  outside_world.update(
    model,
    outside_world.Tour(outside_world.Flows, command),
    context,
  ).0
}

fn tour_phase(model: outside_world.Model) -> tour.Phase {
  tour.phase(tour.get(model.tours, outside_world.Flows))
}

pub fn the_flows_tour_visits_all_four_flows_test() {
  let model = send(outside_world.init(), tour.Next)
  assert model.walk.flow == LlmWireFlow
  assert flows.current(model.walk) == 3
  let model = send(model, tour.Next)
  assert flows.current(model.walk) == 10
  let model = send(model, tour.Next)
  assert model.walk.flow == RelayFlow
  assert model.walk.choices.token == MissingToken
  assert flows.current(model.walk) == 3
  let model = send(model, tour.Next)
  assert model.walk.flow == HellhoundFlow
  assert flows.current(model.walk) == 9
  let model = send(model, tour.Next)
  assert model.walk.flow == CorreioFlow
  assert model.walk.choices.outcome == OutcomeUnknown
  assert flows.current(model.walk) == 6
  let model = send(model, tour.Next)
  assert tour_phase(model) == Guided(6, Paused)
  let model = send(model, tour.Next)
  assert tour_phase(model) == Free
}

pub fn going_back_restores_the_default_options_test() {
  let model =
    outside_world.init()
    |> send(tour.Next)
    |> send(tour.Next)
    |> send(tour.Next)
    |> send(tour.Next)
    |> send(tour.Back)
  // Back to the Relay step: replayed from a reset, so the token is missing
  // again but nothing else from later steps survives.
  assert model.walk.flow == RelayFlow
  assert model.walk.choices.token == MissingToken
  let model = send(model, tour.Back)
  assert model.walk.flow == LlmWireFlow
  assert model.walk.choices == flows.default_choices
  assert flows.current(model.walk) == 10
}

pub fn replay_resets_the_playground_test() {
  let model =
    outside_world.init()
    |> send(tour.Next)
    |> send(tour.Next)
    |> send(tour.Next)
    |> send(tour.Skip)
  assert tour_phase(model) == Free
  let model = send(model, tour.Replay)
  assert model.walk == flows.start
}

pub fn the_flows_tour_has_seven_steps_test() {
  assert list.length(outside_world.script(outside_world.Flows).steps) == 7
}
