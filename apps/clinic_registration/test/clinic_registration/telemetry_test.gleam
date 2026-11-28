//// The telemetry collector's handlers live exactly as long as the
//// application.

import clinic_registration/app
import clinic_registration/scripted
import clinic_registration/telemetry
import support

/// The collector's process owns the handlers: they are attached while the
/// application runs and record what it does. Once the application stops
/// they are detached and the collector holds nothing.
pub fn telemetry_handlers_live_as_long_as_the_application_test() {
  let assert Ok(services) = scripted.start()
  let env = support.boot(services, support.fresh_database(), fn(c) { c })
  // One handler for each of the clinic's five events.
  assert support.handlers(["clinic"]) == 5
  let message = support.message(support.phone(), "Ana", support.ana_says)
  let assert Ok(_) = app.admit(env.app, message)
  assert telemetry.mentioning(env.app.collector, message.id) != []
  app.stop(env.app)
  scripted.stop(services)
  assert support.eventually(2000, fn() { support.handlers(["clinic"]) == 0 })
  assert telemetry.lines(env.app.collector) == []
}
