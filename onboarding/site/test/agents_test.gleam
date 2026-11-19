import gleam/list
import pages/agents
import pages/agents/gate
import pages/agents/ladder
import pages/agents/plug
import pages/agents/point
import site/context
import site/motion
import site/progress
import site/tour.{Free, Guided, Paused}

// THE POLICY GATE -------------------------------------------------------------

fn outcomes(g: gate.Gate) -> List(gate.Outcome) {
  list.map(gate.outcomes(g), fn(pair) { pair.1 })
}

pub fn the_default_policy_runs_waits_and_denies_test() {
  let g = gate.new()
  assert outcomes(g)
    == [
      gate.Ran(read_only: True),
      gate.Ran(read_only: False),
      gate.WaitingForPerson,
      gate.Denied("closing accounts needs a human"),
    ]
  assert gate.run(g) == gate.SuspendedForApproval
}

pub fn an_approval_lets_the_run_finish_test() {
  let g = gate.answer(gate.new(), gate.RefundSetupCharge, gate.Approved)
  assert list.contains(outcomes(g), gate.ApprovedThenRan)
  assert gate.run(g) == gate.FinishedWithAnswer
  let g = gate.answer(gate.new(), gate.RefundSetupCharge, gate.Rejected)
  assert list.contains(outcomes(g), gate.RejectedByPerson)
  assert gate.run(g) == gate.FinishedWithAnswer
}

pub fn handing_over_withdraws_the_rest_of_the_reply_test() {
  let g =
    gate.new()
    |> gate.answer(gate.RefundSetupCharge, gate.Approved)
    |> gate.set_rule(gate.SmallRefunds, gate.refund_desk)
  assert outcomes(g)
    == [gate.Ran(True), gate.HandedOver, gate.Withdrawn, gate.Withdrawn]
  assert gate.run(g) == gate.FinishedHandedOver
  // Rewriting a rule withdraws earlier answers.
  assert gate.reset_approvals(g).answers == g.answers
}

pub fn a_denied_large_refund_carries_its_own_reason_test() {
  let g =
    gate.set_rule(
      gate.new(),
      gate.LargeRefunds,
      gate.large_refunds_need_a_human,
    )
  assert outcomes(g)
    == [
      gate.Ran(True),
      gate.Ran(False),
      gate.Denied("refunds over €100 need a human"),
      gate.Denied("closing accounts needs a human"),
    ]
  assert gate.run(g) == gate.FinishedWithAnswer
}

// PULL THE PLUG ---------------------------------------------------------------

pub fn what_survives_depends_on_the_store_test() {
  let killed = fn(store) { plug.new() |> plug.pick_store(store) |> plug.kill }
  assert plug.refund(plug.new()) == plug.NotKilledYet
  assert plug.refund(killed(plug.InMemory)) == plug.LostWithTheRecord
  assert plug.after_restart(killed(plug.InMemory)) == "Nothing to recover."
  assert plug.refund(killed(plug.Directory)) == plug.MarkedUncertain
  assert plug.refund(killed(plug.Postgres)) == plug.MarkedUncertain
  assert plug.after_restart(killed(plug.Postgres)) == "Recoverable by run id."
  let idle = plug.new() |> plug.toggle_flight |> plug.kill
  assert plug.refund(idle) == plug.NothingWasInFlight
  // Changing the scenario brings the VM back.
  assert plug.toggle_flight(idle).vm == plug.Running
  assert plug.pick_store(idle, plug.InMemory).vm == plug.Running
}

// THE DECISION POINT ----------------------------------------------------------

fn stages(p: point.Point) -> List(String) {
  list.map(p.occurrence.path, point.stage)
}

pub fn v1_asks_finance_and_one_approval_releases_test() {
  let p = point.perform(point.new(), point.ReadPolicy)
  assert p.occurrence.phase == point.Awaiting(0)
  assert point.verb_label(p, point.Approve) == "Bia approves"
  let p = point.perform(p, point.Approve)
  assert p.occurrence.phase == point.Settled(point.Released)
  assert stages(p) == ["recommended", "awaiting", "released"]
  assert p.occurrence.entries
    == [
      "released: refund sent to the gated tool, once, in this transaction",
      "accepted → release check passed",
      "approve by Bia (1/1)",
      "policy v1: ask finance (1 approval needed)",
      "recommend: refund €40 · confidence 95% · key msg-4471",
    ]
}

pub fn v3_holds_and_finance_can_withdraw_test() {
  let p =
    point.new()
    |> point.publish(point.V3)
    |> point.perform(point.ReadPolicy)
  assert p.occurrence.phase == point.Held
  assert list.first(p.occurrence.entries)
    == Ok("policy v3: proceed (≤ €100, ≥ 90%) with a 10-minute hold")
  let p = point.perform(p, point.WithdrawInHold)
  assert p.occurrence.phase == point.Settled(point.Withdrawn)
  assert point.verbs(p) == [point.StartAgain]
}

pub fn v4_needs_two_people_from_500_test() {
  let p =
    point.new()
    |> point.load(600, 95, point.V4)
    |> point.perform(point.ReadPolicy)
  assert p.occurrence.phase == point.Awaiting(0)
  let p = point.perform(p, point.Approve)
  assert p.occurrence.phase == point.Awaiting(1)
  assert point.verb_label(p, point.Approve) == "Caio approves"
  assert point.title(p) == "Awaiting finance (1 of 2)"
  // The path does not repeat a stage the occurrence stays in.
  assert stages(p) == ["recommended", "awaiting"]
  let p = point.perform(p, point.Approve)
  assert p.occurrence.phase == point.Settled(point.Released)
}

pub fn the_gated_tool_can_refuse_or_be_unsure_test() {
  let accepted =
    point.new()
    |> point.publish(point.V2)
    |> point.perform(point.ReadPolicy)
  assert accepted.occurrence.phase == point.Accepted
  let unsure =
    point.set_tool(accepted, point.IsUnsure) |> point.perform(point.Release)
  assert unsure.occurrence.phase == point.Accepted
  let refused =
    point.set_tool(accepted, point.Refuses) |> point.perform(point.Release)
  assert refused.occurrence.phase == point.Awaiting(0)
  let held =
    point.new()
    |> point.publish(point.V3)
    |> point.set_tool(point.Refuses)
    |> point.perform(point.ReadPolicy)
    |> point.perform(point.EndHold)
  assert held.occurrence.phase == point.Settled(point.Refused)
}

pub fn verbs_not_on_offer_change_nothing_test() {
  let p = point.new()
  assert point.perform(p, point.Approve) == p
  assert point.perform(p, point.EndHold) == p
}

pub fn changing_the_case_starts_a_new_occurrence_test() {
  let p =
    point.new()
    |> point.perform(point.ReadPolicy)
    |> point.set_amount(120)
  assert p.occurrence == point.recommend(120, 95)
}

pub fn each_version_reaches_its_share_of_recent_cases_test() {
  assert list.map(point.versions, point.reach) == [0, 12, 12, 12]
}

// UP THE LADDER ---------------------------------------------------------------

pub fn the_cases_match_the_reference_draws_test() {
  let cases = ladder.cases()
  assert list.length(cases) == 400
  let assert [first, second, ..] = cases
  assert first.amount == 33
  assert first.confidence == 88
  assert !first.wrong
  assert second.amount == 41
  assert second.confidence == 59
  assert second.wrong
  assert ladder.fixed(ladder.x(first.drawn_amount), 1) == "232.5"
  assert ladder.fixed(ladder.y(first.drawn_confidence), 1) == "81.0"
  assert ladder.fixed(ladder.x(500.0), 1) == "620.7"
}

pub fn the_tallies_match_the_reference_test() {
  let cases = ladder.cases()
  assert ladder.tally(point.V1, cases) == ladder.Tally(0, 400, 0, 0, 66, 0)
  assert ladder.tally(point.V2, cases) == ladder.Tally(109, 291, 0, 3, 66, 0)
  assert ladder.tally(point.V3, cases) == ladder.Tally(109, 291, 0, 3, 66, 0)
  assert ladder.tally(point.V4, cases) == ladder.Tally(109, 291, 39, 3, 66, 0)
  assert ladder.minutes_text(ladder.minutes(ladder.tally(point.V1, cases)))
    == "13.3 hours"
  assert ladder.minutes_text(ladder.minutes(ladder.tally(point.V4, cases)))
    == "11.0 hours"
  assert ladder.minutes_text(42) == "42 minutes"
}

// TOURS -----------------------------------------------------------------------

fn send(model: agents.Model, msg: agents.Msg) -> agents.Model {
  let context = context.new(motion.On, progress.empty())
  agents.update(model, msg, context).0
}

fn next(model: agents.Model, id: agents.TourId) -> agents.Model {
  send(model, agents.Tour(id, tour.Next))
}

fn phase(model: agents.Model, id: agents.TourId) -> tour.Phase {
  tour.phase(tour.get(model.tours, id))
}

pub fn the_gate_tour_test() {
  let model =
    agents.init() |> send(agents.ReaderRejectedCall(gate.RefundSetupCharge))
  let model = next(model, agents.GateTour)
  assert gate.run(model.gate) == gate.SuspendedForApproval
  let model = next(model, agents.GateTour)
  assert gate.run(model.gate) == gate.FinishedWithAnswer
  let model = next(model, agents.GateTour)
  assert gate.run(model.gate) == gate.FinishedHandedOver
  let model = next(model, agents.GateTour)
  assert phase(model, agents.GateTour) == Guided(4, Paused)
  let back = send(model, agents.Tour(agents.GateTour, tour.Back))
  assert gate.run(back.gate) == gate.FinishedHandedOver
  let model = next(model, agents.GateTour)
  assert phase(model, agents.GateTour) == Free
}

pub fn the_plug_tour_test() {
  let model =
    agents.init()
    |> send(agents.ReaderToggledInFlight)
    |> next(agents.PlugTour)
  assert model.plug.store == plug.InMemory
  assert plug.refund(model.plug) == plug.NothingWasInFlight
  let replay =
    send(model, agents.Tour(agents.PlugTour, tour.Skip))
    |> send(agents.Tour(agents.PlugTour, tour.Replay))
  // The reset puts a refund back in flight.
  assert replay.plug == plug.new()
  let model = next(replay, agents.PlugTour)
  assert plug.refund(model.plug) == plug.LostWithTheRecord
  let model = next(model, agents.PlugTour)
  assert model.plug.store == plug.Directory
  assert plug.refund(model.plug) == plug.MarkedUncertain
  let model = next(model, agents.PlugTour)
  assert model.plug.store == plug.Postgres
  assert model.plug.vm == plug.Killed
  let model = model |> next(agents.PlugTour) |> next(agents.PlugTour)
  assert phase(model, agents.PlugTour) == Free
}

pub fn the_point_tour_test() {
  let model = next(agents.init(), agents.PointTour)
  assert model.point.occurrence.phase == point.Awaiting(0)
  let model = next(model, agents.PointTour)
  assert model.point.occurrence.phase == point.Settled(point.Released)
  let model = next(model, agents.PointTour)
  assert model.point.version == point.V3
  assert model.point.occurrence.phase == point.Held
  let model = next(model, agents.PointTour)
  assert model.point.occurrence.phase == point.Settled(point.Withdrawn)
  let model = next(model, agents.PointTour)
  assert model.point.version == point.V4
  assert model.point.amount == 600
  assert point.title(model.point) == "Awaiting finance (0 of 2)"
  // Back replays the steps up to the previous one from the reset.
  let back = send(model, agents.Tour(agents.PointTour, tour.Back))
  assert back.point.amount == 40
  assert back.point.occurrence.phase == point.Settled(point.Withdrawn)
  let model = model |> next(agents.PointTour) |> next(agents.PointTour)
  assert phase(model, agents.PointTour) == Free
}

pub fn the_ladder_tour_and_a_dot_sent_up_test() {
  let model = next(agents.init(), agents.LadderTour)
  assert model.ladder == point.V1
  let model = next(model, agents.LadderTour)
  assert model.ladder == point.V2
  let model = next(model, agents.LadderTour)
  assert model.ladder == point.V4
  let model = model |> next(agents.LadderTour) |> next(agents.LadderTour)
  assert phase(model, agents.LadderTour) == Free
  let assert [first, ..] = model.cases
  let model = send(model, agents.ReaderSentCaseUp(first))
  assert model.point.amount == 33
  assert model.point.confidence == 88
  assert model.point.version == point.V4
  assert model.point.occurrence == point.recommend(33, 88)
}

pub fn a_keyboard_reader_can_send_any_case_up_test() {
  let context = context.new(motion.On, progress.empty())
  let update = fn(model, msg) { agents.update(model, msg, context).0 }
  let model = update(agents.init(), agents.ReaderPickedLadderCase(37))
  assert model.ladder_case == 37
  // Out-of-range numbers stay within the four hundred cases.
  assert update(model, agents.ReaderPickedLadderCase(9000)).ladder_case == 400
  assert update(model, agents.ReaderPickedLadderCase(-3)).ladder_case == 1
  let assert [case_, ..] = list.drop(model.cases, 36)
  let sent = update(model, agents.ReaderSentCaseUp(case_))
  assert sent.point
    == point.load(model.point, case_.amount, case_.confidence, model.ladder)
}
