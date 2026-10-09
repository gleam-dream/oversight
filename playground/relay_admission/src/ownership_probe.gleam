//// A BEAM mechanism experiment, not a Relay implementation or API proposal.

import admission_probe.{stop_process, with_cleanup}
import gleam/erlang/process

@external(erlang, "admission_fixture", "await_exit")
fn await_exit(pid: process.Pid) -> Nil

pub type MailboxObservation {
  MailboxObservation(
    direct_owner_is_caller: Bool,
    worker_owner_is_caller: Bool,
    worker_owner_alive_after_return: Bool,
  )
}

/// The exact same callback creates a usable caller mailbox inline and a dead
/// worker mailbox when an otherwise transparent wrapper spawns it then exits.
pub fn mailbox() -> MailboxObservation {
  let callback = fn() { process.new_subject() }
  let direct = callback()
  let replies = process.new_subject()
  let worker =
    process.spawn_unlinked(fn() { process.send(replies, callback()) })
  use <- with_cleanup(_, fn() { stop_process(worker) })
  let assert Ok(from_worker) = process.receive(replies, 2000)
  let assert Ok(owner) = process.subject_owner(from_worker)
  let assert True = owner == worker
  await_exit(worker)
  MailboxObservation(
    process.subject_owner(direct) == Ok(process.self()),
    process.subject_owner(from_worker) == Ok(process.self()),
    process.is_alive(worker),
  )
}

type Children {
  Children(linked: process.Pid, trapped: process.Pid, detached: process.Pid)
}

pub type CleanupObservation {
  CleanupObservation(
    linked_alive: Bool,
    trapped_alive: Bool,
    detached_alive: Bool,
    borrowed_alive: Bool,
  )
}

/// Killing the callback stops its ordinary linked child, but cannot establish
/// cleanup of arbitrary children or resources. Borrowed resources stay alive.
pub fn kill_callback() -> CleanupObservation {
  let borrowed = process.spawn_unlinked(fn() { process.sleep_forever() })
  use <- with_cleanup(_, fn() { stop_process(borrowed) })
  let replies = process.new_subject()
  let worker =
    process.spawn_unlinked(fn() {
      let linked = process.spawn(fn() { process.sleep_forever() })
      let ready = process.new_subject()
      let trapped =
        process.spawn(fn() {
          process.trap_exits(True)
          process.send(ready, Nil)
          process.sleep_forever()
        })
      let assert Ok(Nil) = process.receive(ready, 2000)
      let detached = process.spawn_unlinked(fn() { process.sleep_forever() })
      process.send(replies, Children(linked, trapped, detached))
      process.sleep_forever()
    })
  use <- with_cleanup(_, fn() { stop_process(worker) })
  let assert Ok(children) = process.receive(replies, 2000)
  use <-
    with_cleanup(_, fn() {
      stop_process(children.linked)
      stop_process(children.trapped)
      stop_process(children.detached)
    })
  stop_process(worker)
  await_exit(children.linked)
  CleanupObservation(
    process.is_alive(children.linked),
    process.is_alive(children.trapped),
    process.is_alive(children.detached),
    process.is_alive(borrowed),
  )
}
