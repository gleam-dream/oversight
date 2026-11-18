import gleam/float
import gleam/list
import gleam/option
import gleam/string
import pages/beam
import pages/beam/processes.{
  CrashedHere, Delivered, DiedToo, Dropped, ExitSignal, HandledOne, Linked,
  StartedAgain, Unlinked,
}
import pages/beam/scheduler.{Cooperative, Preemptive, WellBehaved, WithGreedy}
import pages/beam/scheduler_widget
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

/// Every step of `seconds` of simulation under one setting.
fn trace(
  sim: scheduler.Sim,
  seconds: Float,
  scheduling: scheduler.Scheduling,
) -> List(scheduler.Sim) {
  let steps = float.round(seconds /. scheduler.step_seconds)
  list.scan(list.repeat(Nil, steps), sim, fn(sim, _) {
    scheduler.step(sim, scheduling)
  })
}

fn holder(sim: scheduler.Sim, core: Int) -> option.Option(scheduler.Task) {
  case list.drop(scheduler.running(sim), core) {
    [option.Some(p), ..] -> option.Some(p.task)
    _ -> option.None
  }
}

pub fn the_simulation_is_the_same_on_every_visit_test() {
  let run = fn() {
    scheduler.new()
    |> scheduler.set_workload(WithGreedy)
    |> scheduler.run(12.0, Preemptive)
  }
  assert run() == run()
}

pub fn a_core_runs_one_process_and_every_process_is_in_one_place_test() {
  let sims =
    scheduler.new()
    |> scheduler.set_workload(WithGreedy)
    |> trace(30.0, Preemptive)
  list.each(sims, fn(sim) {
    let on_cores =
      list.filter_map(scheduler.running(sim), fn(p) { option.to_result(p, Nil) })
    assert list.length(list.unique(list.map(on_cores, fn(p) { p.task })))
      == list.length(on_cores)
    // Nobody waits while a core is idle.
    case list.any(scheduler.running(sim), option.is_none) {
      True -> {
        assert scheduler.queue(sim) == []
      }
      False -> Nil
    }
  })
}

pub fn the_run_queue_is_first_come_first_served_test() {
  let sims = scheduler.new() |> trace(30.0, Cooperative)
  list.each(sims, fn(sim) {
    let since =
      list.map(scheduler.queue(sim), fn(p) {
        case p.phase {
          scheduler.Ready(since) -> since
          _ -> -1.0
        }
      })
    assert since == list.sort(since, float.compare)
  })
}

pub fn a_cooperative_greedy_process_never_gives_its_core_back_test() {
  let sims =
    scheduler.new()
    |> scheduler.set_workload(WithGreedy)
    |> trace(30.0, Cooperative)
  let assert Ok(start) =
    list.find(sims, fn(sim) {
      holder(sim, 0) == option.Some(scheduler.Greedy)
      || holder(sim, 1) == option.Some(scheduler.Greedy)
    })
  let core = case holder(start, 0) == option.Some(scheduler.Greedy) {
    True -> 0
    False -> 1
  }
  let after = list.drop_while(sims, fn(sim) { sim != start })
  list.each(after, fn(sim) {
    assert holder(sim, core) == option.Some(scheduler.Greedy)
  })
}

pub fn preemption_cuts_every_turn_at_the_budget_test() {
  let sims =
    scheduler.new()
    |> scheduler.set_workload(WithGreedy)
    |> trace(30.0, Preemptive)
  list.each(sims, fn(sim) {
    list.each(scheduler.processes(sim), fn(p) {
      case p.phase {
        scheduler.Running(since:, ..) -> {
          assert scheduler.clock(sim) -. since
            <. scheduler.budget +. scheduler.step_seconds
        }
        _ -> Nil
      }
    })
  })
}

pub fn the_greedy_process_doubles_waits_unless_preempted_test() {
  let wait = fn(scheduling, workload) {
    scheduler.new()
    |> scheduler.set_workload(workload)
    |> scheduler.run(24.0, scheduling)
    |> scheduler.longest_wait
  }
  let calm = wait(Preemptive, WellBehaved)
  let hogged = wait(Cooperative, WithGreedy)
  let fair = wait(Preemptive, WithGreedy)
  assert calm <. scheduler.budget *. 1.5
  assert hogged >. fair *. 2.0
  assert fair <. scheduler.budget *. 2.5
}

pub fn removing_the_greedy_process_frees_its_core_test() {
  let sim =
    scheduler.new()
    |> scheduler.set_workload(WithGreedy)
    |> scheduler.run(10.0, Cooperative)
    |> scheduler.set_workload(WellBehaved)
  assert list.all(scheduler.processes(sim), fn(p) { p.task != scheduler.Greedy })
  // The freed core went to whoever was waiting.
  case scheduler.queue(sim) {
    [] -> Nil
    _ -> {
      assert !list.any(scheduler.running(sim), option.is_none)
    }
  }
}

pub fn the_timelines_keep_the_last_sixteen_slices_test() {
  let sim = scheduler.new() |> scheduler.run(20.0, Preemptive)
  list.each(scheduler.timelines(sim), fn(slices) {
    assert list.length(slices) == scheduler.timeline
  })
}

pub fn the_widget_controls_survive_their_attribute_test() {
  let controls =
    scheduler_widget.Controls(
      scheduling: Cooperative,
      workload: WithGreedy,
      resets: 3,
      advances: 12,
    )
  assert scheduler_widget.decode(scheduler_widget.encode(controls))
    == option.Some(controls)
  assert scheduler_widget.decode("sideways greedy 1 2") == option.None
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

pub fn without_motion_the_scheduler_tour_runs_the_widget_ahead_test() {
  let still = context.new(motion.Off, progress.empty())
  let next = fn(model) {
    beam.update(model, beam.Tour(beam.SchedulerTour, tour.Next), still).0
  }
  let model = beam.init() |> next
  // Step 2 adds G cooperatively and runs eight seconds ahead.
  assert model.scheduler_advances == 8
  let model = next(model)
  assert model.scheduler_advances == 14
  // Back resets the widget and replays step 2.
  let model =
    beam.update(model, beam.Tour(beam.SchedulerTour, tour.Back), still).0
  assert model.scheduler_resets == 1
  assert model.workload == WithGreedy
}
