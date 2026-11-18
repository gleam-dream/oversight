import gleam/list
import gleam/string
import pages/beam
import pages/beam/processes.{
  CrashedHere, Delivered, DiedToo, Dropped, ExitSignal, HandledOne, Linked,
  StartedAgain, Unlinked,
}
import pages/beam/scheduler.{Cooperative, Preemptive, WellBehaved, WithGreedy}
import site/context
import site/motion
import site/progress
import site/tour.{Free, Guided, Paused}

// PROCESSES -------------------------------------------------------------------

fn get(p: processes.Processes, id: Int) -> processes.Process {
  let assert Ok(process) = processes.find(p, id)
  process
}

pub fn five_processes_start_with_empty_mailboxes_test() {
  let p = processes.new()
  assert list.length(p.processes) == 5
  assert processes.running_count(p) == 5
  assert list.all(p.processes, fn(process) { processes.mailbox(process) == [] })
  assert processes.next_message(p) == "add_item"
}

pub fn a_send_copies_into_the_mailbox_and_cycles_the_message_test() {
  let p = processes.new() |> processes.send |> processes.send
  assert processes.mailbox(get(p, 1)) == ["add_item", "get_total"]
  assert processes.next_message(p) == "charge"
  assert p.trace == [Delivered(0, 1, "add_item"), Delivered(0, 1, "get_total")]
  let assert [newest, ..] = p.log
  assert newest
    == "web copied \"get_total\" into cart’s mailbox and moved on without waiting."
}

pub fn handling_takes_the_oldest_message_test() {
  let p =
    processes.new() |> processes.send |> processes.send |> processes.handle(1)
  assert processes.mailbox(get(p, 1)) == ["get_total"]
  assert processes.handled(get(p, 1)) == 1
  let assert [_, _, last] = p.trace
  assert last == HandledOne(1, "add_item")
}

pub fn a_crash_loses_the_mailbox_and_spares_the_others_test() {
  let p =
    processes.new()
    |> processes.pick_recipient(2)
    |> processes.send
    |> processes.crash(2)
  assert !processes.is_alive(get(p, 2))
  assert processes.mailbox(get(p, 2)) == []
  assert processes.running_count(p) == 4
  let assert [newest, ..] = p.log
  assert newest
    == "payment crashed. Its memory and 1 queued message(s) are gone. web, cart, mailer, cache kept running untouched."
}

pub fn sending_to_a_dead_process_drops_the_message_test() {
  let p =
    processes.new()
    |> processes.crash(2)
    |> processes.pick_recipient(2)
    |> processes.send
  assert p.sent == 1
  let assert [_, dropped] = p.trace
  assert dropped == Dropped(0, 2, "add_item")
}

pub fn a_dead_sender_sends_nothing_test() {
  let p = processes.new() |> processes.crash(0) |> processes.send
  assert p.sent == 0
  assert p.trace == [CrashedHere(0)]
  let assert [newest, ..] = p.log
  assert newest == "web is not running, so it cannot send anything."
}

pub fn a_linked_crash_takes_the_partner_down_test() {
  let p = processes.new() |> processes.toggle_link |> processes.crash(1)
  assert p.link == Linked
  assert !processes.is_alive(get(p, 2))
  assert p.trace == [CrashedHere(1), ExitSignal(1, 2), DiedToo(2)]
  let p = processes.toggle_link(p)
  assert p.link == Unlinked
}

pub fn a_restart_is_fresh_test() {
  let p =
    processes.new()
    |> processes.send
    |> processes.handle(1)
    |> processes.crash(1)
  assert processes.handled(get(p, 1)) == 1
  let p = processes.restart(p, 1)
  assert processes.is_alive(get(p, 1))
  assert processes.handled(get(p, 1)) == 0
  let assert Ok(last) = list.last(p.trace)
  assert last == StartedAgain(1)
}

pub fn spawning_stops_at_ten_processes_test() {
  let p =
    list.fold(list.repeat(Nil, 7), processes.new(), fn(p, _) {
      processes.spawn(p)
    })
  assert list.length(p.processes) == 10
  let assert Ok(last) = list.last(p.processes)
  assert last.name == "worker-9"
  let assert [newest, ..] = p.log
  assert string.starts_with(newest, "That’s enough for this demo.")
}

pub fn the_log_and_trace_are_capped_test() {
  let p =
    list.fold(list.repeat(Nil, 15), processes.new(), fn(p, _) {
      processes.send(p)
    })
  assert list.length(p.log) == 12
  assert list.length(p.trace) == 10
  let assert [oldest, ..] = p.trace
  // Sends 6 to 15 remain; the sixth send carried the sixth name.
  assert oldest == Delivered(0, 1, "refresh")
}

// SCHEDULER -------------------------------------------------------------------

fn lanes(schedule: scheduler.Schedule) -> List(String) {
  list.map(schedule.cores, fn(core) {
    string.concat(list.map(core, scheduler.label))
  })
}

pub fn well_behaved_processes_share_the_cores_test() {
  let schedule = scheduler.run(Preemptive, WellBehaved)
  assert lanes(schedule) == ["ACACACACACACACAC", "BDBDBDBDBDBDBDBD"]
  assert schedule.longest_wait == 1
  assert scheduler.run(Cooperative, WellBehaved) == schedule
}

pub fn a_greedy_process_hogs_a_cooperative_core_test() {
  let schedule = scheduler.run(Cooperative, WithGreedy)
  assert lanes(schedule) == ["ACGGGGGGGGGGGGGG", "BDABCDABCDABCDAB"]
  assert schedule.longest_wait == 3
}

pub fn preemption_keeps_the_greedy_process_to_its_share_test() {
  let schedule = scheduler.run(Preemptive, WithGreedy)
  assert lanes(schedule) == ["ACGBDACGBDACGBDA", "BDACGBDACGBDACGB"]
  assert schedule.longest_wait == 2
}

// TOURS -----------------------------------------------------------------------

fn send(
  model: beam.Model,
  id: beam.TourId,
  command: tour.Command,
) -> beam.Model {
  let context = context.new(motion.On, progress.empty())
  beam.update(model, beam.Tour(id, command), context).0
}

fn steps(model: beam.Model, id: beam.TourId, count: Int) -> beam.Model {
  list.fold(list.repeat(Nil, count), model, fn(m, _) { send(m, id, tour.Next) })
}

pub fn the_process_tour_tells_the_whole_story_test() {
  let model = steps(beam.init(), beam.ProcessTour, 1)
  assert processes.mailbox(get(model.processes, 1)) == ["add_item"]
  let model = steps(model, beam.ProcessTour, 2)
  assert !processes.is_alive(get(model.processes, 2))
  let model = steps(model, beam.ProcessTour, 1)
  let assert Ok(dropped) = list.last(model.processes.trace)
  assert dropped == Dropped(0, 2, "get_total")
  let model = steps(model, beam.ProcessTour, 1)
  assert processes.is_alive(get(model.processes, 2))
  assert model.processes.link == Linked
  let model = steps(model, beam.ProcessTour, 1)
  assert !processes.is_alive(get(model.processes, 1))
  assert !processes.is_alive(get(model.processes, 2))
  assert processes.running_count(model.processes) == 3
  assert model.processes.trace
    == [
      Delivered(0, 1, "add_item"),
      HandledOne(1, "add_item"),
      CrashedHere(2),
      Dropped(0, 2, "get_total"),
      StartedAgain(2),
      CrashedHere(1),
      ExitSignal(1, 2),
      DiedToo(2),
    ]
  assert tour.phase(tour.get(model.tours, beam.ProcessTour))
    == Guided(6, Paused)
  let model = steps(model, beam.ProcessTour, 2)
  assert tour.phase(tour.get(model.tours, beam.ProcessTour)) == Free
}

pub fn going_back_replays_the_process_tour_test() {
  let model = steps(beam.init(), beam.ProcessTour, 6)
  let model = send(model, beam.ProcessTour, tour.Back)
  // Back at step 5: payment restarted and linked, nobody crashed yet.
  assert processes.running_count(model.processes) == 5
  assert model.processes.link == Linked
  assert list.length(model.processes.trace) == 5
}

pub fn the_scheduler_tour_adds_greedy_then_preempts_test() {
  let model = steps(beam.init(), beam.SchedulerTour, 1)
  assert model.scheduling == Cooperative
  assert model.workload == WithGreedy
  let model = steps(model, beam.SchedulerTour, 1)
  assert model.scheduling == Preemptive
  assert model.workload == WithGreedy
  // Going back to step 1 resets, then replays adding G cooperatively.
  let model = send(model, beam.SchedulerTour, tour.Back)
  assert model.scheduling == Cooperative
  assert model.workload == WithGreedy
  let model = send(model, beam.SchedulerTour, tour.Skip)
  let model = send(model, beam.SchedulerTour, tour.Replay)
  assert model.scheduling == Preemptive
  assert model.workload == WellBehaved
}
