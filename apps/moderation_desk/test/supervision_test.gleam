//// The application's tree under kills. A runtime child or a moderator
//// killed in the middle of its work loses only the transaction in hand,
//// which rolls back; the store owner's death loses everything and the
//// tree restarts on an empty, seeded store; and a chaos run that keeps
//// killing while thousands of posts move ends with every invariant
//// holding.

import decisions
import decisions/occurrence
import decisions_otp/backlog
import decisions_otp/runtime.{Dispatcher, Sweeper, Worker}
import decisions_otp/store
import gleam/erlang/process
import gleam/list
import gleam/string
import gleam/time/duration
import moderation_desk/app.{type App}
import moderation_desk/desk.{Moderating, Person}
import moderation_desk/domain
import moderation_desk/models
import moderation_desk/point
import moderation_desk/scripted
import moderation_desk/wiring
import support

fn runtime_child(a: App, role: runtime.Role) -> process.Pid {
  let assert Ok(children) = runtime.children_of(app.control(a))
  let assert Ok(pid) = list.key_find(children, role)
  pid
}

fn workers(a: App) -> List(process.Pid) {
  let assert Ok(children) = runtime.children_of(app.control(a))
  children
  |> list.filter_map(fn(pair) {
    case pair.0 {
      Worker(_) -> Ok(pair.1)
      _ -> Error(Nil)
    }
  })
}

fn off_duty(name: String) -> desk.Person {
  Person(
    validator: desk.moderator(name),
    role: Moderating,
    think_ms: 0,
    poll_ms: 20,
    on_duty: False,
  )
}

/// Killed: the store owner. Lost: everything the store held. Restarted
/// by: the root, with an empty store under the same name; every child
/// after it restarts and takes the new handle, the platform seeds it
/// again, and new posts are moderated.
pub fn the_store_owner_killed_restarts_the_tree_on_an_empty_store_test() {
  let a = support.start(app.config())
  let first = scripted.post(1)
  support.receive_all(a, [first])
  support.settle(a, [first], within: 5000)
  let old = store.owner(app.store_of(a))
  let assert Ok(old_runtime) = runtime.supervisor_of(app.control(a))
  support.kill(old)
  let assert True =
    app.wait_until(
      fn() {
        case runtime.supervisor_of(app.control(a)) {
          Ok(pid) -> pid != old_runtime
          Error(Nil) -> False
        }
      },
      within: 5000,
    )
  assert store.owner(app.store_of(a)) != old
  // The record went with the old owner.
  assert store.heads(support.handle(a)) == []
  let next = scripted.post(2)
  support.receive_all(a, [next])
  support.settle(a, [next], within: 5000)
  assert support.check(a).occurrences == 1
  app.stop(a)
}

/// Killed: every worker while the classifier computes. Lost: the model
/// run in hand, whose process dies with its worker, and the workers'
/// claims on their triggers. Restarted by: the runtime's supervisor; a
/// new worker classifies the post again, and there is one occurrence with
/// no failed attempt.
pub fn a_worker_killed_mid_model_loses_nothing_test() {
  let config =
    app.Config(
      ..app.config(),
      timing: models.Timing(
        rules_within: duration.milliseconds(100),
        classifier_within: duration.seconds(2),
        classifier_ms: 0,
      ),
    )
  let a = support.start(config)
  let slow = scripted.faulty(scripted.post(50), "[slow]")
  support.receive_all(a, [slow])
  process.sleep(100)
  let killed = workers(a)
  list.each(killed, support.kill)
  support.settle(a, [slow], within: 5000)
  assert list.all(workers(a), fn(pid) { !list.contains(killed, pid) })
  let known = support.occurrence(a, slow)
  assert known.attempts == []
  assert support.notified(a) == [#(wiring.key(slow), 1)]
  support.check(a)
  app.stop(a)
}

/// Killed: the sweeper, inside the transaction that delivers an
/// escalation, while it waits for the occurrence's lock. Lost: that
/// transaction; the wake-up stays due. Restarted by: the runtime's
/// supervisor; the new sweeper delivers it once.
pub fn the_sweeper_killed_mid_delivery_loses_nothing_test() {
  let a = support.start(support.with_people([off_duty("ana")]))
  let s = app.store_of(a)
  let insult = scripted.post(88)
  support.receive_all(a, [insult])
  let assert True =
    app.wait_until(
      fn() { support.awaiting(a, insult) == [point.moderators] },
      within: 5000,
    )
  let release = support.hold_occurrence(s, wiring.key(insult))
  store.advance(s, duration.minutes(31))
  // The sweeper takes the wake-up and waits for the lock.
  process.sleep(100)
  let sweeper = runtime_child(a, Sweeper)
  support.kill(sweeper)
  release()
  let assert True =
    app.wait_until(
      fn() { support.awaiting(a, insult) == [point.seniors] },
      within: 5000,
    )
  assert runtime_child(a, Sweeper) != sweeper
  let known = support.occurrence(a, insult)
  assert list.length(occurrence.policy_answers(known)) == 2
  support.check(a)
  app.stop(a)
}

/// Killed: the dispatcher, inside what follows a settlement, while it
/// waits for the lock on the post's visibility. Lost: that transaction;
/// the notice stays undelivered. Restarted by: the runtime's supervisor; the post is
/// published and its author told once.
pub fn the_dispatcher_killed_mid_handler_loses_nothing_test() {
  let a = support.start(app.config())
  let s = app.store_of(a)
  let thanks = scripted.post(30)
  let release = support.hold_visibility(s, thanks.id)
  support.receive_all(a, [thanks])
  let assert True =
    app.wait_until(
      fn() {
        case
          decisions.read(
            app.desk_of(a),
            store.handle(s),
            occurrence: wiring.key(thanks),
          )
        {
          Ok(known) -> occurrence.is_settled(known.status)
          Error(_) -> False
        }
      },
      within: 5000,
    )
  process.sleep(100)
  let dispatcher = runtime_child(a, Dispatcher)
  support.kill(dispatcher)
  release()
  support.settle(a, [thanks], within: 5000)
  assert runtime_child(a, Dispatcher) != dispatcher
  assert support.visibility(a, thanks) == Ok(domain.Published)
  assert support.notified(a) == [#(wiring.key(thanks), 1)]
  app.stop(a)
}

/// Killed: a moderator, inside the transaction that gives her verdict,
/// while it waits for the occurrence's lock. Lost: that transaction and
/// the card she was reading; her claim row survives.
/// Restarted by: the desk's supervisor; the new process finds her claim,
/// opens the card again and decides once.
pub fn a_moderator_killed_mid_verdict_loses_nothing_test() {
  let ana =
    Person(
      validator: desk.moderator("ana"),
      role: Moderating,
      think_ms: 300,
      poll_ms: 20,
      on_duty: True,
    )
  let a = support.start(support.with_people([ana]))
  let s = app.store_of(a)
  let insult = scripted.post(88)
  let key = wiring.key(insult)
  support.receive_all(a, [insult])
  let assert True =
    app.wait_until(
      fn() { store.get(store.handle(s), wiring.claims, key) == Ok("ana") },
      within: 5000,
    )
  let release = support.hold_occurrence(s, key)
  // Her thinking ends and her verdict waits for the lock.
  process.sleep(400)
  let assert Ok(name) = app.person_named(a, "ana")
  let assert Ok(pid) = process.named(name)
  support.kill(pid)
  release()
  support.settle(a, [insult], within: 5000)
  let assert Ok(again) = process.named(name)
  assert again != pid
  let known = support.occurrence(a, insult)
  let assert [#("ana", _)] = occurrence.verdicts(known)
  assert support.visibility(a, insult) == Ok(domain.Hidden(domain.Abuse))
  support.check(a)
  app.stop(a)
}

// -- Chaos ---------------------------------------------------------------------------

type Chaos {
  Stop(reply: process.Subject(Int))
}

/// Kill one process every `every` ms, cycling through a worker, the
/// sweeper, the dispatcher and a person at the desk, until told to stop.
/// Returns how many it killed.
fn start_chaos(a: App, every: Int) -> process.Subject(Chaos) {
  let reply = process.new_subject()
  process.spawn(fn() {
    let control = process.new_subject()
    process.send(reply, control)
    chaos(a, control, every, 0)
  })
  let assert Ok(control) = process.receive(reply, 1000)
  control
}

fn chaos(
  a: App,
  control: process.Subject(Chaos),
  every: Int,
  killed: Int,
) -> Nil {
  case process.receive(control, every) {
    Ok(Stop(reply)) -> process.send(reply, killed)
    Error(Nil) -> {
      let target = case killed % 4 {
        0 -> list.shuffle(workers(a)) |> list.first
        1 -> Ok(runtime_child(a, Sweeper))
        2 -> Ok(runtime_child(a, Dispatcher))
        _ -> {
          let names = ["ana", "bruno", "carla", "dev"]
          let assert Ok(name) = list.shuffle(names) |> list.first
          let assert Ok(person) = app.person_named(a, name)
          process.named(person)
        }
      }
      case target {
        Ok(pid) -> process.kill(pid)
        Error(Nil) -> Nil
      }
      chaos(a, control, every, killed + 1)
    }
  }
}

/// 3 000 posts under version 1, so that more than half wait for a
/// person, while a worker, the sweeper, the dispatcher or a person at the
/// desk is killed every 50 ms. Some posts hang their classifier once and
/// two always raise. At the end every invariant holds, every healthy post
/// settled exactly once with one notification, and the two broken ones
/// are set aside after exactly three counted failures. Their records hold
/// at least three failed attempts: a worker killed after its failed
/// attempt was recorded and before the runtime counted it leaves one
/// attempt on the record that the runtime never counted.
pub fn chaos_while_thousands_of_posts_move_test() {
  let a = support.start(app.config())
  let posts =
    scripted.posts(1, 3000)
    |> list.map(fn(post) {
      case post.id {
        "post-1555" | "post-2555" -> scripted.faulty(post, "[raise]")
        _ ->
          case string.ends_with(post.id, "50") {
            True -> scripted.faulty(post, "[hang-once]")
            False -> post
          }
      }
    })
  let #(broken, healthy) =
    list.partition(posts, fn(post) { string.contains(post.text, "[raise]") })
  let control = start_chaos(a, 50)
  support.receive_all(a, posts)
  support.settle(a, healthy, within: 120_000)
  let killed = process.call(control, 5000, Stop)
  assert killed > 20
  // Let anything in flight finish before reading the record.
  process.sleep(200)
  let summary = support.check(a)
  assert summary.occurrences == list.length(healthy)
  assert summary.settled == list.length(healthy)
  let notified = support.notified(a)
  assert list.length(notified) == list.length(healthy)
  assert list.all(notified, fn(pair) { pair.1 == 1 })
  let s = app.store_of(a)
  let assert Ok(aside) = store.backlog(s).aside()
  assert list.all(aside, fn(job) { job.attempts == 3 })
  let aside_keys = list.map(aside, runtime_key)
  assert list.sort(aside_keys, string.compare)
    == list.sort(list.map(broken, wiring.key), string.compare)
  list.each(broken, fn(post) {
    let assert Error(decisions.NotRecommended(attempts:)) =
      decisions.read(
        app.desk_of(a),
        store.handle(s),
        occurrence: wiring.key(post),
      )
    assert list.length(attempts) >= 3
  })
  // The tree is whole after all of it.
  assert list.length(workers(a)) == app.config().workers
  app.stop(a)
}

fn runtime_key(aside: backlog.Aside) -> String {
  backlog.about(aside.job).1
}
