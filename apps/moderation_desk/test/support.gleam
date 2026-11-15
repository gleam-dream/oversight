//// Test support: an application with chosen people, waits, readings of
//// the record and a process that holds a lock.

import decisions
import decisions/occurrence.{type Occurrence}
import decisions/testing
import decisions_otp/store.{type Store, type Tx}
import gleam/erlang/process.{type Name}
import gleam/list
import gleam/result
import moderation_desk/app.{type App}
import moderation_desk/desk.{type Person}
import moderation_desk/domain.{type Action, type Post}
import moderation_desk/point
import moderation_desk/wiring

/// The default configuration with these people at the desk.
pub fn with_people(people: List(Person)) -> app.Config {
  app.Config(..app.config(), people:)
}

pub fn start(config: app.Config) -> App {
  let assert Ok(a) = app.start(config)
  a
}

pub fn person(a: App, name: String) -> Name(desk.Message) {
  let assert Ok(found) = app.person_named(a, name)
  found
}

pub fn receive_all(a: App, posts: List(Post)) -> Nil {
  list.each(posts, fn(post) {
    let assert Ok(_) = app.receive(a, post)
  })
}

/// Wait for every post's current revision to be decided and delivered.
pub fn settle(a: App, posts: List(Post), within ms: Int) -> Nil {
  let assert True =
    app.wait_until(fn() { app.all_settled(a, posts) }, within: ms)
  Nil
}

/// Publish policy version 2 with classifier version 2.
pub fn publish_version_2(a: App) -> Nil {
  let assert Ok(Nil) =
    store.transaction(app.store_of(a), fn(tx) {
      wiring.publish(tx, point.version_2(), "2")
      |> result.replace_error(Nil)
    })
  Nil
}

pub fn handle(a: App) -> Tx {
  store.handle(app.store_of(a))
}

/// The occurrence about a post's current revision.
pub fn occurrence(a: App, post: Post) -> Occurrence(Action) {
  let assert Ok(known) =
    decisions.read(app.desk_of(a), handle(a), occurrence: wiring.key(post))
  known
}

/// The sets an occurrence about this post waits for.
pub fn awaiting(a: App, post: Post) -> List(String) {
  store.heads(handle(a))
  |> list.key_find(wiring.key(post))
  |> result.map(fn(head) { head.awaiting })
  |> result.unwrap([])
}

/// Run the invariant checker over the store, counting the gated tool's
/// effects.
pub fn check(a: App) -> testing.Summary {
  let assert Ok(summary) =
    testing.check(handle(a), store.inspection(), [
      testing.audit(app.desk_of(a), effects: fn(tx) {
        Ok(store.count(tx, wiring.released))
      }),
    ])
  summary
}

/// Notifications per occurrence: `#(occurrence, how many)`.
pub fn notified(a: App) -> List(#(String, Int)) {
  wiring.notifications(handle(a))
  |> list.fold([], fn(counts, triple) {
    let #(_, occurrence, _) = triple
    list.key_set(
      counts,
      occurrence,
      list.key_find(counts, occurrence) |> result.unwrap(0) |> fn(n) { n + 1 },
    )
  })
}

/// Hold the lock on an occurrence in a transaction of another process
/// until the returned function is called. The function waits until that
/// transaction has ended.
pub fn hold_occurrence(s: Store, id: String) -> fn() -> Nil {
  hold(s, fn(tx) {
    let _ = decisions.read(wiring.desk(), tx, occurrence: id)
    Nil
  })
}

/// Hold the lock on a post's visibility the same way.
pub fn hold_visibility(s: Store, id: String) -> fn() -> Nil {
  hold(s, fn(tx) {
    let assert Ok(Nil) = wiring.lock_visibility(tx, id)
    Nil
  })
}

fn hold(s: Store, take: fn(Tx) -> Nil) -> fn() -> Nil {
  let locked = process.new_subject()
  let done = process.new_subject()
  process.spawn(fn() {
    let release = process.new_subject()
    let _ =
      store.transaction(s, fn(tx) {
        take(tx)
        process.send(locked, release)
        let _ = process.receive(release, 10_000)
        Ok(Nil)
      })
    process.send(done, Nil)
  })
  let assert Ok(release) = process.receive(locked, 5000)
  fn() {
    process.send(release, Nil)
    let assert Ok(Nil) = process.receive(done, 5000)
    Nil
  }
}

/// Kill `pid` and wait until it is gone.
pub fn kill(pid: process.Pid) -> Nil {
  let monitor = process.monitor(pid)
  process.kill(pid)
  let _ =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(5000)
  Nil
}

pub fn visibility(a: App, post: Post) -> Result(domain.Visibility, Nil) {
  wiring.visibility(handle(a), post.id)
}
