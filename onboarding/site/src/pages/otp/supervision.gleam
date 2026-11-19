//// The supervision tree simulator: a root supervisor with four children, a
//// restart strategy and a restart intensity of three restarts in a window.
//// A fourth crash inside the window makes the supervisor give up and
//// escalate.
////
//// Restarts happen a moment after a crash. `crash` reports the restart the
//// supervisor scheduled; the page runs `restart` with it later. Each child
//// waiting to start again names the restart that will start it, so a later
//// crash that takes a child into a newer restart supersedes the older one
//// for that child, and a restart scheduled before a reset is ignored.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
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
  /// Crashed; restart number `restart` will start it again.
  Crashed(restart: Int)
  /// Stopped by the supervisor; restart number `restart` will start it again.
  Restarting(restart: Int)
  /// Crashed, and nothing will start it again: the supervisor gave up.
  CrashedForGood
  /// Stopped for good: the supervisor gave up.
  Stopped
}

/// A restart the supervisor scheduled: the tree's epoch when it was
/// scheduled, and its number within that epoch.
pub type Restart {
  Restart(epoch: Int, id: Int)
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
    /// The number of the latest restart scheduled in this epoch.
    last_restart: Int,
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
    last_restart: 0,
  )
}

/// Start the application again, forgetting every pending restart.
pub fn reset(tree: Tree) -> Tree {
  new(tree.epoch + 1)
}

pub fn pick(tree: Tree, strategy: Strategy) -> Tree {
  Tree(..tree, strategy:)
}

/// A child crashes. Returns the next tree and the restart the supervisor
/// scheduled, if any.
pub fn crash(tree: Tree, child: Child) -> #(Tree, Option(Restart)) {
  case tree.supervisor {
    GaveUp -> #(tree, None)
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
                True -> CrashedForGood
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
          None,
        )
        False -> {
          let affected = affected(tree.strategy, child)
          let id = tree.last_restart + 1
          // The supervisor stops the others in reverse start order.
          let stops =
            affected
            |> list.filter(fn(c) { c != child })
            |> list.reverse
            |> list.map(fn(c) { msc.send(0, lane(c), "stop", msc.Amber) })
          #(
            Tree(
              ..tree,
              window:,
              last_restart: id,
              children: list.map(tree.children, fn(c) {
                case c.child == child, list.contains(affected, c.child) {
                  True, _ -> ChildState(..c, status: Crashed(id))
                  False, True -> ChildState(..c, status: Restarting(id))
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
            Some(Restart(epoch: tree.epoch, id:)),
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

/// The supervisor restarts children from a clean state, in start order. It
/// starts only the children still waiting for this restart: a child a later
/// crash took into a newer restart waits for that one instead. A restart
/// scheduled before a reset, or after the supervisor gave up, does nothing.
pub fn restart(tree: Tree, restart: Restart) -> Tree {
  case restart.epoch == tree.epoch, tree.supervisor {
    True, Watching -> {
      let #(last_pid, children) =
        list.map_fold(tree.children, tree.last_pid, fn(pid, c) {
          case pending(c.status) == Some(restart.id) {
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
      case waiting_for(tree, restart) {
        [] -> tree
        started ->
          Tree(
            ..tree,
            children:,
            last_pid:,
            news: RestartedFresh(started),
            events: cap(list.append(
              tree.events,
              list.map(started, fn(c) {
                msc.send(0, lane(c), "start", msc.Green)
              }),
            )),
          )
      }
    }
    _, _ -> tree
  }
}

/// The children still waiting for a restart, in start order.
pub fn waiting_for(tree: Tree, restart: Restart) -> List(Child) {
  case restart.epoch == tree.epoch {
    False -> []
    True ->
      list.filter_map(tree.children, fn(c) {
        case pending(c.status) == Some(restart.id) {
          True -> Ok(c.child)
          False -> Error(Nil)
        }
      })
  }
}

/// The restart a child is waiting for, if any.
fn pending(status: Status) -> Option(Int) {
  case status {
    Crashed(restart:) | Restarting(restart:) -> Some(restart)
    Running | CrashedForGood | Stopped -> None
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
    Crashed(..) | CrashedForGood -> "crashed"
    Restarting(..) -> "restarting"
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
