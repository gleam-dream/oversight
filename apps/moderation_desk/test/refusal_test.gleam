//// A verdict the gated tool refuses at release is kept on the record as a
//// `verdict_refused` entry, and the card ends, superseded by the refused
//// release, in the same transaction: it leaves every moderator's queue,
//// and its settlement says the release was refused. When that write
//// fails, the desk process does not carry on as if the entry were there:
//// it crashes, its supervisor starts it again, and the new process opens
//// the card again and records the refusal of that showing.

import decisions/occurrence
import decisions/store as port
import decisions/vocabulary.{Superseded}
import decisions_otp/store.{type Tx}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/otp/actor
import moderation_desk/app.{type App}
import moderation_desk/desk.{Moderating, Person}
import moderation_desk/domain
import moderation_desk/followers
import moderation_desk/point
import moderation_desk/scripted
import moderation_desk/wiring
import support

type Fault {
  Spend(reply: Subject(Bool))
}

/// How many writes of a refusal are still to fail.
fn faults(count: Int) -> Subject(Fault) {
  let assert Ok(started) =
    actor.new(count)
    |> actor.on_message(fn(left, message) {
      case message {
        Spend(reply:) -> {
          process.send(reply, left > 0)
          actor.continue(int.max(left - 1, 0))
        }
      }
    })
    |> actor.start
  started.data
}

/// The store's port, except that a write of a `verdict_refused` entry
/// fails while `faults` has failures left.
fn failing_refusals(faults: Subject(Fault)) -> port.Port(Tx) {
  let real = store.port()
  port.Port(..real, append: fn(tx, id, head, entries) {
    let refusal =
      list.any(entries, fn(entry: port.Stored) {
        entry.kind == "verdict_refused"
      })
    case refusal && process.call(faults, 1000, Spend) {
      True -> Error(port.Unavailable("the refusal was not written"))
      False -> real.append(tx, id, head, entries)
    }
  })
}

fn refusals(a: App, id: String) -> Int {
  store.entries(support.handle(a), id)
  |> list.count(fn(entry: port.Stored) { entry.kind == "verdict_refused" })
}

/// Ana opens a card; while she reads it, the post is deleted, so the
/// gated tool refuses her approval. The first write of that refusal
/// fails. Her process crashes and is started again; the new process finds
/// her claim, opens the card again, and the refusal ends up on the record
/// once: with the refusal recorded, the card has ended.
pub fn a_failed_refusal_write_restarts_the_moderator_test() {
  let ana =
    Person(
      validator: desk.moderator("ana"),
      role: Moderating,
      think_ms: 200,
      poll_ms: 60_000,
      on_duty: True,
    )
  let a =
    support.start(
      app.Config(
        ..support.with_people([ana]),
        port: failing_refusals(faults(1)),
      ),
    )
  let name = support.person(a, "ana")
  let assert Ok(first) = process.named(name)
  let post = scripted.post(50)
  let key = wiring.key(post)
  support.receive_all(a, [post])
  let assert True =
    app.wait_until(
      fn() { store.get(support.handle(a), wiring.claims, key) == Ok("ana") },
      within: 5000,
    )
  let assert Ok(Nil) =
    store.transaction(app.store_of(a), fn(tx) {
      store.remove(tx, wiring.posts, post.id)
      Ok(Nil)
    })
    as "the post is deleted"
  let assert True = app.wait_until(fn() { refusals(a, key) >= 1 }, within: 5000)
    as "the refusal is on the record"
  // The recorded refusal is the restarted process's: the first process
  // crashed on the failed write.
  let assert Ok(now) = process.named(name)
  assert now != first
  // Nobody takes the card again once the refusal is on the record.
  assert !app.wait_until(fn() { refusals(a, key) > 1 }, within: 1000)
  app.stop(a)
}

fn moderator(name: String, on_duty: Bool) -> desk.Person {
  Person(
    validator: desk.moderator(name),
    role: Moderating,
    think_ms: 200,
    poll_ms: 60_000,
    on_duty:,
  )
}

/// Ana and Bea moderate. While Ana reads a card, its post is deleted, so
/// the gated tool refuses her approval. The tool refused the verdict, not
/// Ana: the card leaves every queue, so Bea, on duty afterwards, never
/// opens it. The record ends the card as superseded by the refused
/// release, and its settlement, that the release was refused, is
/// delivered.
pub fn a_refused_verdict_takes_the_card_off_every_queue_test() {
  let a =
    support.start(
      support.with_people([moderator("ana", True), moderator("bea", False)]),
    )
  let post = scripted.post(50)
  let key = wiring.key(post)
  support.receive_all(a, [post])
  let assert True =
    app.wait_until(
      fn() { store.get(support.handle(a), wiring.claims, key) == Ok("ana") },
      within: 5000,
    )
  let assert Ok(Nil) =
    store.transaction(app.store_of(a), fn(tx) {
      store.remove(tx, wiring.posts, post.id)
      Ok(Nil)
    })
    as "the post is deleted"
  let assert True = app.wait_until(fn() { refusals(a, key) >= 1 }, within: 5000)
    as "the refusal is on the record"
  // Bea comes on duty and looks; the snapshot answers after the look.
  let bea = support.person(a, "bea")
  desk.on_duty(bea, True)
  desk.look(bea)
  assert desk.snapshot(bea).last == None
  assert refusals(a, key) == 1
  let known = support.occurrence(a, post)
  assert known.status == occurrence.Expired(Superseded(point.release_refused))
  assert followers.settlement(known)
    == Ok(domain.Unreleased(domain.ReleaseRefused))
  assert app.wait_until(
    fn() { store.backlog(app.store_of(a)).undelivered(1) == Ok([]) },
    within: 5000,
  )
  assert store.get(support.handle(a), wiring.claims, key) == Error(Nil)
  app.stop(a)
}
