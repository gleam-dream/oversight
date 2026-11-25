//// The telemetry collector's process owns its handlers.

import gleam/erlang/process
import research_agent/events
import research_agent/telemetry

@external(erlang, "owned_handlers_ffi", "handlers")
fn handlers(prefix: List(String)) -> Int

/// The collector's handlers are attached while it runs and record events
/// emitted from any process. Once it stops they are detached and it holds
/// nothing.
pub fn telemetry_handlers_live_as_long_as_the_collector_test() {
  let before = handlers(["research_agent"])
  let assert Ok(observed) = telemetry.start()
  assert handlers(["research_agent"]) == before + 1
  let done = process.new_subject()
  process.spawn(fn() {
    events.announce("r-owned", events.Queued)
    process.send(done, Nil)
  })
  let assert Ok(Nil) = process.receive(done, 1000)
  let assert [_] = telemetry.trace(observed, "r-owned").events
  telemetry.stop(observed)
  assert eventually(2000, fn() { handlers(["research_agent"]) == before })
  assert telemetry.trace(observed, "r-owned").events == []
}

fn eventually(within: Int, ready: fn() -> Bool) -> Bool {
  case ready() {
    True -> True
    False if within <= 0 -> False
    False -> {
      process.sleep(25)
      eventually(within - 25, ready)
    }
  }
}
