//// Two cores running processes in real time. Four well-behaved processes
//// wake when a message arrives, queue for a core, do a short burst of work
//// and go back to sleep. The reader can add a greedy process that never
//// stops working, and switch between cooperative and preemptive scheduling.
////
//// Time is simulated in fixed steps, so the same seed and the same steps
//// always give the same picture. A work budget is slowed down to half a
//// second so the reader can watch it drain.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/order
import site/rng.{type Rng}

pub type Scheduling {
  /// Most runtimes: a process keeps the core until it gives it back.
  Cooperative
  /// The BEAM: every process is cut off after its work budget.
  Preemptive
}

pub type Workload {
  WellBehaved
  WithGreedy
}

pub type Task {
  A
  B
  C
  D
  /// The greedy process, G.
  Greedy
}

pub const cores = 2

/// One work budget, in simulated seconds: also the width of a time slice.
pub const budget = 0.5

/// The time slices each core's timeline shows.
pub const timeline = 16

/// The simulation advances in steps of this many seconds.
pub const step_seconds = 0.05

/// How far back the longest wait looks.
const wait_window = 4.0

const normal = [A, B, C, D]

const core_numbers = [0, 1]

const seed = 5

// MODEL -----------------------------------------------------------------------

pub type Phase {
  /// Waiting for its next message; it needs no core until then.
  Asleep(wakes_at: Float)
  /// Runnable, in the run queue since `since`.
  Ready(since: Float)
  /// On a core (0 or 1) since `since`, when its current turn began.
  Running(core: Int, since: Float)
}

pub type Work {
  /// Work left in this burst, in seconds of a core.
  Burst(left: Float)
  /// The greedy process: never finishes, never yields.
  Endless
}

pub type Process {
  Process(task: Task, phase: Phase, work: Work)
}

pub opaque type Sim {
  Sim(
    clock: Float,
    rng: Rng,
    processes: List(Process),
    /// Per core, the task that held it in each recent time slice, oldest
    /// first; `None` when the core was idle.
    timelines: List(List(Option(Task))),
    next_slice: Float,
    /// When each recent turn began and how long it had waited for it.
    waits: List(#(Float, Float)),
  )
}

/// A simulation already four seconds into calm running, so the picture
/// opens with processes on the cores rather than everyone asleep.
pub fn new() -> Sim {
  start() |> run(4.0, Preemptive)
}

fn start() -> Sim {
  let #(processes, rng) =
    list.fold(normal, #([], rng.seed(seed)), fn(acc, task) {
      let #(processes, rng) = acc
      let #(r, rng) = rng.next(rng)
      let process = Process(task, Asleep(wakes_at: r *. 1.5), Burst(0.0))
      #([process, ..processes], rng)
    })
  Sim(
    clock: 0.0,
    rng:,
    processes: list.reverse(processes),
    timelines: list.repeat([], cores),
    next_slice: budget,
    waits: [],
  )
}

// OBSERVATIONS ----------------------------------------------------------------

pub fn clock(sim: Sim) -> Float {
  sim.clock
}

pub fn processes(sim: Sim) -> List(Process) {
  sim.processes
}

/// The run queue, head first: ready processes in the order they became
/// ready. It is derived, so it can never disagree with the processes.
pub fn queue(sim: Sim) -> List(Process) {
  sim.processes
  |> list.filter(fn(p) {
    case p.phase {
      Ready(..) -> True
      _ -> False
    }
  })
  |> list.sort(fn(a, b) {
    case a.phase, b.phase {
      Ready(x), Ready(y) ->
        case float.compare(x, y) {
          order.Eq -> int.compare(rank(a.task), rank(b.task))
          other -> other
        }
      _, _ -> order.Eq
    }
  })
}

/// The process on each core, core 1 first.
pub fn running(sim: Sim) -> List(Option(Process)) {
  list.map(core_numbers, fn(core) {
    list.find(sim.processes, fn(p) {
      case p.phase {
        Running(core: c, ..) -> c == core
        _ -> False
      }
    })
    |> option.from_result
  })
}

pub fn timelines(sim: Sim) -> List(List(Option(Task))) {
  sim.timelines
}

/// The longest any normal process has waited for a core in the last few
/// seconds, counting those still waiting.
pub fn longest_wait(sim: Sim) -> Float {
  let past =
    sim.waits
    |> list.filter(fn(w) { w.0 >=. sim.clock -. wait_window })
    |> list.fold(0.0, fn(longest, w) { float.max(longest, w.1) })
  queue(sim)
  |> list.filter(fn(p) { p.task != Greedy })
  |> list.fold(past, fn(longest, p) {
    case p.phase {
      Ready(since) -> float.max(longest, sim.clock -. since)
      _ -> longest
    }
  })
}

/// The share of recent time slices a core was busy, from 0 to 100.
pub fn busy(sim: Sim, core: Int) -> Int {
  case list.drop(sim.timelines, core) {
    [slices, ..] ->
      case list.length(slices) {
        0 -> 0
        n -> list.count(slices, option.is_some) * 100 / n
      }
    [] -> 0
  }
}

// TRANSITIONS -----------------------------------------------------------------

/// Put the greedy process in (it is ready at once) or take it out.
pub fn set_workload(sim: Sim, workload: Workload) -> Sim {
  let present = list.any(sim.processes, fn(p) { p.task == Greedy })
  case workload, present {
    WithGreedy, False ->
      Sim(
        ..sim,
        processes: list.append(sim.processes, [
          Process(Greedy, Ready(since: sim.clock), Endless),
        ]),
      )
    WellBehaved, True ->
      Sim(
        ..sim,
        processes: list.filter(sim.processes, fn(p) { p.task != Greedy }),
      )
      |> dispatch
    _, _ -> sim
  }
}

/// Run the simulation forward by `seconds`, in whole steps.
pub fn run(sim: Sim, seconds: Float, scheduling: Scheduling) -> Sim {
  let steps = float.round(seconds /. step_seconds)
  list.fold(list.repeat(Nil, steps), sim, fn(sim, _) { step(sim, scheduling) })
}

/// One step: running processes work, finish or are preempted; sleepers wake;
/// idle cores take the head of the run queue; each finished time slice is
/// written to the timelines.
pub fn step(sim: Sim, scheduling: Scheduling) -> Sim {
  let now = sim.clock +. step_seconds
  let sim = Sim(..sim, clock: now)
  let #(processes, rng) =
    list.fold(sim.processes, #([], sim.rng), fn(acc, process) {
      let #(done, rng) = acc
      let #(process, rng) = advance(process, now, scheduling, rng)
      #([process, ..done], rng)
    })
  Sim(..sim, processes: list.reverse(processes), rng:)
  |> dispatch
  |> record
}

fn advance(
  process: Process,
  now: Float,
  scheduling: Scheduling,
  rng: Rng,
) -> #(Process, Rng) {
  case process.phase, process.work {
    // Finished its burst: it yields and sleeps until its next message.
    Running(..), Burst(left) if left <=. step_seconds -> {
      let #(r, rng) = rng.next(rng)
      #(
        Process(
          ..process,
          phase: Asleep(wakes_at: now +. 0.5 +. r),
          work: Burst(0.0),
        ),
        rng,
      )
    }
    Running(since:, ..), work -> {
      let work = case work {
        Burst(left) -> Burst(left -. step_seconds)
        Endless -> Endless
      }
      let spent = now -. since >=. budget -. 0.0001
      case scheduling, spent {
        // Out of budget: back of the run queue.
        Preemptive, True -> #(Process(..process, phase: Ready(now), work:), rng)
        _, _ -> #(Process(..process, work:), rng)
      }
    }
    // A message arrives: it wakes with a new burst of work.
    Asleep(wakes_at), _ if wakes_at <=. now -> {
      let #(r, rng) = rng.next(rng)
      #(
        Process(..process, phase: Ready(now), work: Burst(0.3 +. r *. 0.7)),
        rng,
      )
    }
    _, _ -> #(process, rng)
  }
}

/// Give every idle core the head of the run queue, core 1 first.
fn dispatch(sim: Sim) -> Sim {
  let busy_cores =
    list.filter_map(sim.processes, fn(p) {
      case p.phase {
        Running(core:, ..) -> Ok(core)
        _ -> Error(Nil)
      }
    })
  let idle =
    list.filter(core_numbers, fn(core) { !list.contains(busy_cores, core) })
  let picks = list.zip(idle, queue(sim))
  list.fold(picks, sim, fn(sim, pick) {
    let #(core, chosen) = pick
    let waited = case chosen.phase {
      Ready(since) -> sim.clock -. since
      _ -> 0.0
    }
    let waits = case chosen.task {
      Greedy -> sim.waits
      _ -> [#(sim.clock, waited), ..sim.waits] |> list.take(64)
    }
    Sim(
      ..sim,
      waits:,
      processes: list.map(sim.processes, fn(p) {
        case p.task == chosen.task {
          True -> Process(..p, phase: Running(core:, since: sim.clock))
          False -> p
        }
      }),
    )
  })
}

/// At the end of each time slice, note who holds each core.
fn record(sim: Sim) -> Sim {
  case sim.clock >=. sim.next_slice -. 0.0001 {
    False -> sim
    True -> {
      let holders =
        list.map(running(sim), fn(p) { option.map(p, fn(p) { p.task }) })
      let timelines =
        list.map2(sim.timelines, holders, fn(slices, holder) {
          list.append(slices, [holder])
          |> list.drop(int.max(0, list.length(slices) + 1 - timeline))
        })
      Sim(..sim, timelines:, next_slice: sim.next_slice +. budget)
    }
  }
}

// PRESENTATION ----------------------------------------------------------------

fn rank(task: Task) -> Int {
  case task {
    A -> 0
    B -> 1
    C -> 2
    D -> 3
    Greedy -> 4
  }
}

pub fn label(task: Task) -> String {
  case task {
    A -> "A"
    B -> "B"
    C -> "C"
    D -> "D"
    Greedy -> "G"
  }
}

/// Background and ink of a task's square.
pub fn colours(task: Task) -> #(String, String) {
  case task {
    A -> #("#DCD9FF", "#241F6B")
    B -> #("#C9E8FF", "#0B3A66")
    C -> #("#DDF3F0", "#0B4A45")
    D -> #("#FDF0DC", "#6B3404")
    Greedy -> #("#B42318", "#FFFFFF")
  }
}

pub fn note(scheduling: Scheduling, workload: Workload) -> String {
  case workload, scheduling {
    WellBehaved, _ ->
      "Four well-behaved processes share two cores. Each wakes when a message arrives, works briefly and sleeps again, so everyone gets a turn within a slice or two."
    WithGreedy, Cooperative ->
      "Cooperative scheduling: the greedy process grabbed a core and never gives it back. Everyone else now squeezes onto the other core, the run queue backs up and waits climb. If a second greedy process appeared the system would freeze. This is how a single bad loop takes down services on many runtimes."
    WithGreedy, Preemptive ->
      "Preemptive scheduling, the BEAM way: the greedy process is cut off when its budget runs out, like everyone else, and goes to the back of the queue. It gets its fair share and nothing more, so the system stays responsive."
  }
}
