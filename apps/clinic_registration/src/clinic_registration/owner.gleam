//// A process that starts linked servers (Mist listeners, a pool) and ends
//// them in order. Each server is started from the owner, so the owner is
//// its parent; `stop` makes the owner exit with `shutdown`, which a
//// supervisor treats as its parent asking it to stop: it stops its
//// children and reports nothing.

import gleam/erlang/process.{type Pid, type Subject}
import gleam/result

pub opaque type Owner {
  Owner(pid: Pid, stop: Subject(Nil))
}

/// Run `start` in a new owner process and return what it returned.
pub fn start(start: fn() -> Result(a, String)) -> Result(#(a, Owner), String) {
  let reply = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let stop = process.new_subject()
      process.send(reply, #(start(), stop))
      let _ = process.receive_forever(stop)
      exit_shutdown()
    })
  use #(started, stop) <- result.try(
    process.receive(reply, 10_000)
    |> result.replace_error("the owner process did not start"),
  )
  result.map(started, fn(value) { #(value, Owner(pid:, stop:)) })
}

/// Stop everything the owner started, and wait until the owner is gone.
pub fn stop(owner: Owner) -> Nil {
  let monitor = process.monitor(owner.pid)
  process.send(owner.stop, Nil)
  let _ =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(5000)
  Nil
}

@external(erlang, "clinic_registration_ffi", "exit_shutdown")
fn exit_shutdown() -> Nil
