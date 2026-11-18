//// The supervision tree simulator: a root supervisor with four children, a
//// restart strategy and a restart intensity of three restarts in a window.
//// A fourth crash inside the window makes the supervisor give up and
//// escalate.
////
//// Restarts happen a moment after a crash. `crash` reports which children
//// the supervisor will restart; the page schedules `restart` for them under
//// the tree's epoch, so a restart scheduled before a reset is ignored.

import gleam/int
import gleam/list
import gleam/string
import site/msc

pub type Strategy {
  OneForOne
  OneForAll
  RestForOne
}

/// In the order the strategy picker shows them.
pub const strategies = [OneForOne, OneForAll, RestForOne]

/// The children, in start order.
pub type Child {
  DatabasePool
  HttpClient
  JobRuntime
  WebServer
}

pub const children = [DatabasePool, HttpClient, JobRuntime, WebServer]

pub type Status {
  Running
  Crashed
  /// Stopped by the supervisor, about to start again.
  Restarting
  /// Stopped for good: the supervisor gave up.
  Stopped
}

pub type ChildState {
  ChildState(child: Child, status: Status, pid: Int, restarts: Int)
}

pub type Supervisor {
  Watching
  GaveUp
}

/// What the tree last reported to the reader.
pub type News {
  AllRunning
  ChildCrashed(Child)
  Escalated(Child)
  RestartedFresh(List(Child))
  WindowCleared
  WaitedAfterGivingUp
}

pub type Tree {
  Tree(
    strategy: Strategy,
    supervisor: Supervisor,
    /// Restarts counted in the current intensity window.
    window: Int,
    children: List(ChildState),
    last_pid: Int,
    news: News,
    events: List(msc.Event),
    /// Bumped on every reset; a restart carries the epoch it was scheduled in.
    epoch: Int,
  )
}

/// Restarts allowed in one window before the supervisor gives up.
pub const intensity = 3

/// How long the supervisor takes to restart children, in milliseconds.
pub const restart_ms = 800

pub fn new(epoch: Int) -> Tree {
  Tree(
    strategy: OneForOne,
    supervisor: Watching,
    window: 0,
    children: list.index_map(children, fn(child, i) {
      ChildState(child:, status: Running, pid: 201 + i, restarts: 0)
    }),
    last_pid: 210,
    news: AllRunning,
    events: [],
    epoch:,
  )
}

/// Start the application again, forgetting every pending restart.
pub fn reset(tree: Tree) -> Tree {
  new(tree.epoch + 1)
}

pub fn pick(tree: Tree, strategy: Strategy) -> Tree {
  Tree(..tree, strategy:)
}

/// A child crashes. Returns the next tree and the children the supervisor
/// will restart, if any.
pub fn crash(tree: Tree, child: Child) -> #(Tree, List(Child)) {
  case tree.supervisor {
    GaveUp -> #(tree, [])
    Watching -> {
      let window = tree.window + 1
      let at = lane(child)
      case window > intensity {
        True -> #(
          Tree(
            ..tree,
            window:,
            supervisor: GaveUp,
            children: list.map(tree.children, fn(c) {
              ChildState(..c, status: case c.child == child {
                True -> Crashed
                False -> Stopped
              })
            }),
            events: cap(
              list.append(tree.events, [
                msc.Crash(at, "crash #4"),
                msc.Message(at, 0, "EXIT", msc.Red, msc.Dashed),
                msc.Crash(0, "too many restarts: gives up"),
              ]),
            ),
            news: Escalated(child),
          ),
          [],
        )
        False -> {
          let affected = affected(tree.strategy, child)
          let stops =
            affected
            |> list.filter(fn(c) { c != child })
            |> list.map(fn(c) { msc.send(0, lane(c), "stop", msc.Amber) })
          #(
            Tree(
              ..tree,
              window:,
              children: list.map(tree.children, fn(c) {
                case c.child == child, list.contains(affected, c.child) {
                  True, _ -> ChildState(..c, status: Crashed)
                  False, True -> ChildState(..c, status: Restarting)
                  False, False -> c
                }
              }),
              news: ChildCrashed(child),
              events: cap(
                list.flatten([
                  tree.events,
                  [
                    msc.Crash(at, "crash"),
                    msc.Message(at, 0, "EXIT", msc.Red, msc.Dashed),
                  ],
                  stops,
                ]),
              ),
            ),
            affected,
          )
        }
      }
    }
  }
}

/// Which children a crash stops and restarts under a strategy, in start order.
pub fn affected(strategy: Strategy, crashed: Child) -> List(Child) {
  case strategy {
    OneForOne -> [crashed]
    OneForAll -> children
    RestForOne -> list.filter(children, fn(c) { lane(c) >= lane(crashed) })
  }
}

/// The supervisor restarts children from a clean state, in start order. A
/// restart scheduled before a reset, or after the supervisor gave up, does
/// nothing.
pub fn restart(tree: Tree, epoch: Int, affected: List(Child)) -> Tree {
  case epoch == tree.epoch, tree.supervisor {
    True, Watching -> {
      let #(last_pid, children) =
        list.map_fold(tree.children, tree.last_pid, fn(pid, c) {
          case list.contains(affected, c.child) {
            True -> #(
              pid + 1,
              ChildState(
                ..c,
                status: Running,
                pid: pid + 1,
                restarts: c.restarts + 1,
              ),
            )
            False -> #(pid, c)
          }
        })
      Tree(
        ..tree,
        children:,
        last_pid:,
        news: RestartedFresh(affected),
        events: cap(list.append(
          tree.events,
          list.map(affected, fn(c) { msc.send(0, lane(c), "start", msc.Green) }),
        )),
      )
    }
    _, _ -> tree
  }
}

/// Five quiet seconds pass and the restart window clears.
pub fn wait(tree: Tree) -> Tree {
  Tree(..tree, window: 0, news: case tree.supervisor {
    Watching -> WindowCleared
    GaveUp -> WaitedAfterGivingUp
  })
}

/// The restart count as shown: never more than the intensity.
pub fn shown_window(tree: Tree) -> Int {
  int.min(tree.window, intensity)
}

pub fn can_crash(tree: Tree, state: ChildState) -> Bool {
  tree.supervisor == Watching && state.status == Running
}

/// The chart lane of a child; the supervisor is lane 0.
pub fn lane(child: Child) -> Int {
  case child {
    DatabasePool -> 1
    HttpClient -> 2
    JobRuntime -> 3
    WebServer -> 4
  }
}

// TEXT ------------------------------------------------------------------------

pub fn strategy_name(strategy: Strategy) -> String {
  case strategy {
    OneForOne -> "One for one"
    OneForAll -> "One for all"
    RestForOne -> "Rest for one"
  }
}

pub fn strategy_short(strategy: Strategy) -> String {
  string.lowercase(strategy_name(strategy))
}

pub fn strategy_description(strategy: Strategy) -> String {
  case strategy {
    OneForOne ->
      "Only the crashed child restarts. Use it when children are independent of each other."
    OneForAll ->
      "Every child restarts. Use it when the children only make sense together."
    RestForOne ->
      "The crashed child and every child started after it restart. Use it when later children depend on earlier ones, like a web server that needs the database pool."
  }
}

pub fn child_name(child: Child) -> String {
  case child {
    DatabasePool -> "Database pool"
    HttpClient -> "HTTP client"
    JobRuntime -> "Job runtime"
    WebServer -> "Web server"
  }
}

pub fn child_what(child: Child) -> String {
  case child {
    DatabasePool -> "Connections to PostgreSQL"
    HttpClient -> "An HTTP Gun pool for outbound calls"
    JobRuntime -> "Grind queues and workers"
    WebServer -> "Accepts incoming requests"
  }
}

pub fn status_label(status: Status) -> String {
  case status {
    Running -> "running"
    Crashed -> "crashed"
    Restarting -> "restarting"
    Stopped -> "stopped"
  }
}

pub fn news_text(news: News) -> String {
  case news {
    AllRunning -> "Everything is running."
    ChildCrashed(child) ->
      child_name(child) <> " crashed. The supervisor got the exit signal…"
    Escalated(child) ->
      child_name(child)
      <> " crashed a 4th time within 5 seconds. Restarting clearly isn’t helping, so the supervisor stops every child and crashes itself. Its parent decides what next; here the application stops. That’s escalation."
    RestartedFresh(affected) ->
      "Restarted "
      <> string.join(list.map(affected, child_name), ", ")
      <> " from a clean state"
      <> case affected {
        [_, _, ..] -> ", in their original start order."
        _ -> ". Its neighbours never noticed."
      }
    WindowCleared ->
      "Five quiet seconds passed. The restart window is clear again."
    WaitedAfterGivingUp ->
      "Time passed, but the supervisor already gave up. Press Reset to start the application again."
  }
}

/// Reference charts keep their latest nine events.
fn cap(events: List(msc.Event)) -> List(msc.Event) {
  list.drop(events, list.length(events) - 9)
}
