//// The composition root: the supervision tree that owns and stops every
//// process of the application.
////
//// ```text
//// root (rest for one)
//// ├── store owner      the record and the platform's rows, in memory
//// ├── platform         seeds an empty store: authors, threads, policy 1
//// ├── collector        the operator's counts; owns the telemetry handlers
//// ├── desk (one for one)
//// │   └── one process per person on duty
//// └── runtime          decisions_otp/runtime: sweeper, dispatcher, workers
//// ```
////
//// | Child | Killed: what is lost | What restarts it |
//// | --- | --- | --- |
//// | store owner | everything: the record, the backlog and the platform's rows live in its memory | the root, with an empty store under the same name; every later child restarts with it and takes the new handle |
//// | platform | nothing; it only seeds a store that holds no policy | the root |
//// | collector | the counts so far, and its handlers, which sinal detaches with it | the root; the new process attaches the handlers again under the same ids |
//// | desk person | the card being read and its verdict transaction; the claim row survives and names the person | the desk supervisor; the new process finds its claim again |
//// | runtime | the transaction in hand, which rolls back; its job stays in the backlog, because each child acts on rows and keeps none | the runtime's own supervisor for a child, the root for the runtime |
////
//// The root is rest for one because every later child uses the store:
//// when the store restarts, they must restart and take a handle to the
//// new one (`store.named`). The desk comes before the runtime and
//// neither uses the other, so a runtime restart leaves the desk running.

import decisions.{type Desk}
import decisions/learning
import decisions/store as port
import decisions/vocabulary
import decisions_otp/runtime
import decisions_otp/store.{type Store, type Tx}
import gleam/erlang/process.{type Name, type Pid}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import moderation_desk/desk.{type Person, Moderating, Person, Reviewing}
import moderation_desk/domain.{type Action, type Post}
import moderation_desk/followers
import moderation_desk/intake
import moderation_desk/models
import moderation_desk/point
import moderation_desk/scripted.{type Fault}
import moderation_desk/telemetry
import moderation_desk/wiring

/// Everything the application can be started with.
pub type Config {
  Config(
    store: store.Config,
    /// How many triggers are worked at once.
    workers: Int,
    /// How long an idle runtime process waits before it looks again.
    poll: Duration,
    /// How many failed attempts set a trigger aside.
    attempts: Int,
    timing: models.Timing,
    faults: fn(Post, Int) -> Fault,
    people: List(Person),
    /// The port every desk of the application writes the record through.
    /// A test wraps the store's own port to make a write fail.
    port: port.Port(Tx),
  )
}

/// Two moderators, a senior and a reviewer, all on duty and quick; eight
/// workers; a rule model with 100 ms and a classifier with 300 ms to
/// answer; the scripted faults. A failed job waits 20 ms before it is
/// tried again. Escalation and expiry happen when the application moves
/// the store's clock with `store.advance`.
pub fn config() -> Config {
  Config(
    store: store.Config(
      ..store.defaults(),
      retry_backoff: duration.milliseconds(20),
    ),
    workers: 8,
    poll: duration.milliseconds(10),
    attempts: 3,
    timing: models.Timing(
      rules_within: duration.milliseconds(100),
      classifier_within: duration.milliseconds(300),
      classifier_ms: 0,
    ),
    faults: scripted.fault,
    people: [
      person(desk.moderator("ana"), Moderating),
      person(desk.moderator("bruno"), Moderating),
      person(desk.senior("carla"), Moderating),
      person(desk.reviewer("dev"), Reviewing),
    ],
    port: store.port(),
  )
}

/// A person on duty who reads each card at once.
pub fn person(validator: vocabulary.Validator, role: desk.Role) -> Person {
  Person(validator:, role:, think_ms: 0, poll_ms: 50, on_duty: True)
}

/// A running application.
pub opaque type App {
  App(
    root: Pid,
    source: String,
    store: store.Name,
    control: runtime.Control,
    collector: Name(telemetry.Message),
    people: List(#(String, Name(desk.Message))),
  )
}

/// Start the application, linked to the caller.
pub fn start(config: Config) -> Result(App, String) {
  // Every name is made once here: names are atoms, never collected.
  let source = "moderation_desk-" <> int.to_string(unique())
  let store_name = store.new_name("moderation_desk_store")
  let control = runtime.new_control("moderation_desk_runtime")
  let collector = process.new_name("moderation_desk_collector")
  let people =
    list.map(config.people, fn(person) {
      #(person, process.new_name("moderation_desk_person"))
    })
  let desk = wiring.desk_over(config.port)
  let desk_tree =
    list.fold(
      people,
      supervisor.new(supervisor.OneForOne)
        |> supervisor.restart_tolerance(intensity: 100, period: 5),
      fn(builder, pair) {
        supervisor.add(
          builder,
          desk.supervised(store_name, desk, pair.0, pair.1, source:),
        )
      },
    )
  let started =
    supervisor.new(supervisor.RestForOne)
    |> supervisor.restart_tolerance(intensity: 10, period: 5)
    |> supervisor.add(store.supervised(config.store, named: store_name))
    |> supervisor.add(platform(store_name))
    |> supervisor.add(telemetry.supervised(collector, source:))
    |> supervisor.add(supervisor.supervised(desk_tree))
    |> supervisor.add(
      runtime.supervised_from(fn() {
        store.named(store_name)
        |> result.replace_error("no store is running")
        |> result.map(runtime_config(_, config, source, control))
      }),
    )
    |> supervisor.start
  case started {
    Ok(root) ->
      Ok(App(
        root: root.pid,
        source:,
        store: store_name,
        control:,
        collector:,
        people: list.map(people, fn(pair) {
          #({ pair.0 }.validator.subject, pair.1)
        }),
      ))
    Error(error) -> Error(string.inspect(error))
  }
}

fn runtime_config(
  s: Store,
  config: Config,
  source: String,
  control: runtime.Control,
) -> runtime.Config(Tx) {
  let desk = wiring.desk_over(config.port)
  let env =
    models.Env(
      store: s,
      desk:,
      source:,
      timing: config.timing,
      faults: config.faults,
    )
  runtime.Config(
    ..runtime.config(
      store.backlog(s),
      points: [runtime.point(desk, settled: followers.settled)],
      work: models.work(env),
    ),
    workers: config.workers,
    poll: config.poll,
    attempts: config.attempts,
    name: source,
    control: Some(control),
  )
}

/// A child that seeds the store when it holds no policy, then idles. It
/// starts after the store, so an empty store after a restart is seeded
/// again.
fn platform(name: store.Name) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    use s <- result.try(
      store.named(name) |> result.replace_error(actor.InitFailed("no store")),
    )
    use Nil <- result.try(intake.seed(s) |> result.map_error(actor.InitFailed))
    actor.new(Nil)
    |> actor.start
    |> result.map(fn(started) { actor.Started(..started, data: Nil) })
  })
}

/// Stop every process of the application. Everything the store held is
/// lost.
pub fn stop(app: App) -> Nil {
  process.unlink(app.root)
  stop_supervisor(app.root)
}

/// The store as it runs now. After the store restarts, this is the new,
/// empty one.
pub fn store_of(app: App) -> Store {
  let assert Ok(s) = store.named(app.store)
  s
}

/// Who the application is, as its telemetry events say.
pub fn source(app: App) -> String {
  app.source
}

/// The desk over the application's store.
pub fn desk_of(_app: App) -> Desk(Action, Tx) {
  wiring.desk()
}

pub fn root(app: App) -> Pid {
  app.root
}

pub fn numbers(app: App) -> telemetry.Numbers {
  telemetry.numbers(app.collector)
}

/// The name of a person's desk process.
pub fn person_named(app: App, name: String) -> Result(Name(desk.Message), Nil) {
  list.key_find(app.people, name)
}

/// The runtime's control: pause and resume it, find its supervisor and
/// its children.
pub fn control(app: App) -> runtime.Control {
  app.control
}

/// Stop the runtime from delivering anything, leaving its processes, the
/// store and the desk running.
pub fn pause_runtime(app: App) -> Result(Nil, Nil) {
  runtime.pause(app.control)
}

/// Let a paused runtime deliver again.
pub fn resume_runtime(app: App) -> Result(Nil, Nil) {
  runtime.resume(app.control)
}

/// Stop the runtime's whole tree. The root starts it again over the same
/// store; the desk keeps running.
pub fn restart_runtime(app: App) -> Result(Nil, Nil) {
  use pid <- result.map(runtime.supervisor_of(app.control))
  let monitor = process.monitor(pid)
  process.kill(pid)
  let _ =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(5000)
  Nil
}

/// Receive a post.
pub fn receive(app: App, post: Post) -> Result(intake.Receipt, String) {
  intake.receive(store_of(app), post, source: app.source)
}

/// Wait until `condition` holds, checking every 5 ms, for at most `ms`.
pub fn wait_until(condition: fn() -> Bool, within ms: Int) -> Bool {
  case condition(), ms <= 0 {
    True, _ -> True
    False, True -> False
    False, False -> {
      process.sleep(5)
      wait_until(condition, ms - 5)
    }
  }
}

/// Whether every one of these posts' current revisions has settled and
/// its settlement has been delivered.
pub fn all_settled(app: App, posts: List(Post)) -> Bool {
  let s = store_of(app)
  let handle = store.handle(s)
  let undelivered = case store.backlog(s).undelivered(1) {
    Ok([]) -> True
    _ -> False
  }
  undelivered
  && list.all(posts, fn(post) {
    case wiring.visibility(handle, post.id) {
      Ok(domain.Pending) | Error(Nil) -> False
      Ok(_) -> True
    }
  })
}

/// Whether every one of these posts is settled, as `all_settled`, or
/// accepted and held in its undo window.
pub fn all_settled_or_held(app: App, posts: List(Post)) -> Bool {
  let s = store_of(app)
  let handle = store.handle(s)
  let heads = store.heads(handle)
  list.all(posts, fn(post) {
    case wiring.visibility(handle, post.id) {
      Ok(domain.Pending) | Error(Nil) ->
        case list.key_find(heads, wiring.key(post)) {
          Ok(head) -> head.status == port.Held
          Error(Nil) -> False
        }
      Ok(_) -> True
    }
  })
}

/// How triggers fared before a recommendation, over every record of the
/// point: expected, superseded before a recommendation, still expected.
pub fn coverage(app: App) -> learning.Coverage {
  let s = store_of(app)
  let handle = store.handle(s)
  records(handle, None, [])
  |> list.filter_map(fn(id) {
    decisions.read_record(wiring.desk(), handle, key: id)
    |> result.replace_error(Nil)
  })
  |> learning.coverage
}

fn records(
  handle: Tx,
  after: option.Option(store.Cursor),
  so_far: List(String),
) -> List(String) {
  let page = store.occurrences_of(handle, point.name, after:, limit: 1000)
  let so_far = list.append(so_far, page.ids)
  case page.next {
    Some(next) -> records(handle, Some(next), so_far)
    None -> so_far
  }
}

/// Silence the logger, so that killed processes print no crash report.
@external(erlang, "moderation_desk_ffi", "quiet")
pub fn quiet() -> Nil

@external(erlang, "moderation_desk_ffi", "stop_supervisor")
fn stop_supervisor(pid: Pid) -> Nil

/// The number of schedulers online.
@external(erlang, "moderation_desk_ffi", "schedulers")
pub fn schedulers() -> Int

/// The machine, as one line.
@external(erlang, "moderation_desk_ffi", "machine")
pub fn machine() -> String

/// Microseconds on a clock that only moves forward.
@external(erlang, "moderation_desk_ffi", "monotonic_us")
pub fn monotonic_us() -> Int

@external(erlang, "erlang", "unique_integer")
fn unique_integer(options: List(UniqueOption)) -> Int

type UniqueOption {
  Positive
}

fn unique() -> Int {
  unique_integer([Positive])
}
