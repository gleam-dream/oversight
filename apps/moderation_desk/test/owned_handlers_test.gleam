//// The collector's process owns the telemetry handlers.

import moderation_desk/app
import moderation_desk/scripted
import support

@external(erlang, "telemetry_test_ffi", "handlers_with_id_prefix")
fn handlers(prefix: String) -> Int

/// The handlers are attached by the collector while it starts: all twelve
/// are there while the application runs and count what it does, and sinal
/// detaches them once the application stops.
pub fn telemetry_handlers_live_as_long_as_the_application_test() {
  let a = support.start(app.config())
  let source = app.source(a) <> ":"
  assert handlers(source) == 12
  let post = scripted.post(1)
  support.receive_all(a, [post])
  support.settle(a, [post], within: 5000)
  assert app.numbers(a).received == 1
  app.stop(a)
  assert app.wait_until(fn() { handlers(source) == 0 }, within: 2000)
}
