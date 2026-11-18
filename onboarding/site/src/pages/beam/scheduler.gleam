//// Two cores sharing time between four well-behaved processes and, if the
//// reader adds it, one greedy process that never stops working. A pure
//// function of the scheduling style and the workload.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

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

pub const slices = 16

const normal = [A, B, C, D]

/// Each core's time slices, in order, and the longest wait any normal
/// process had between turns (counting to the end of the window).
pub type Schedule {
  Schedule(cores: List(List(Task)), longest_wait: Int)
}

pub fn run(scheduling: Scheduling, workload: Workload) -> Schedule {
  let queue = case workload {
    WellBehaved -> normal
    WithGreedy -> list.append(normal, [Greedy])
  }
  let #(by_time, _, _) =
    int.range(0, slices, #([], queue, [None, None]), fn(acc, _) {
      let #(rows, queue, hogs) = acc
      let #(row, queue, hogs) = tick(scheduling, queue, hogs)
      #([row, ..rows], queue, hogs)
    })
  let by_time = list.reverse(by_time)
  Schedule(cores: list.transpose(by_time), longest_wait: longest_wait(by_time))
}

/// One time slice on every core, core 1 first.
fn tick(
  scheduling: Scheduling,
  queue: List(Task),
  hogs: List(Option(Task)),
) -> #(List(Task), List(Task), List(Option(Task))) {
  let #(row, queue, hogs) =
    list.fold(hogs, #([], queue, []), fn(acc, hog) {
      let #(row, queue, hogs) = acc
      case hog, queue {
        Some(task), _ -> #([task, ..row], queue, [hog, ..hogs])
        None, [task, ..rest] -> {
          let queue = list.append(rest, [task])
          case scheduling, task {
            Cooperative, Greedy -> #(
              [task, ..row],
              list.filter(queue, fn(t) { t != Greedy }),
              [Some(Greedy), ..hogs],
            )
            _, _ -> #([task, ..row], queue, [None, ..hogs])
          }
        }
        None, [] -> #(row, queue, [None, ..hogs])
      }
    })
  #(list.reverse(row), queue, list.reverse(hogs))
}

fn longest_wait(by_time: List(List(Task))) -> Int {
  let #(last, wait) =
    list.index_fold(by_time, #(dict.new(), 0), fn(acc, row, t) {
      list.fold(row, acc, fn(acc, task) {
        let #(last, wait): #(Dict(Task, Int), Int) = acc
        case task {
          Greedy -> acc
          _ -> {
            let wait = case dict.get(last, task) {
              Ok(previous) -> int.max(wait, t - previous - 1)
              Error(Nil) -> wait
            }
            #(dict.insert(last, task, t), wait)
          }
        }
      })
    })
  list.fold(normal, wait, fn(wait, task) {
    case dict.get(last, task) {
      Ok(previous) -> int.max(wait, slices - 1 - previous)
      Error(Nil) -> slices
    }
  })
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
      "Four well-behaved processes share two cores. Everyone gets a turn every couple of slices."
    WithGreedy, Cooperative ->
      "Cooperative scheduling: the greedy process grabbed core 1 and never gave it back. Everyone else now squeezes onto one core, and if a second greedy process appeared the system would freeze. This is how a single bad loop takes down services on many runtimes."
    WithGreedy, Preemptive ->
      "Preemptive scheduling, the BEAM way: the greedy process is cut off after its budget like everyone else. It gets its fair share and nothing more, so the system stays responsive."
  }
}
