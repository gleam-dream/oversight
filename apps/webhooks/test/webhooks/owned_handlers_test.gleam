//// The telemetry collector's process owns its handlers.

import gleam/erlang/process
import webhooks/receiver
import webhooks/support
import webhooks/telemetry

@external(erlang, "owned_handlers_ffi", "handlers_with_id_prefix")
fn collector_handlers(prefix: String) -> Int

/// The collector's handlers record a delivery while the service runs, and
/// once the service stops they are detached and the collector holds
/// nothing.
pub fn telemetry_handlers_live_as_long_as_the_service_test() {
  let collector = {
    use svc <- support.with_service(support.options())
    let rx = receiver.start()
    let assert Ok(#(_, secret)) =
      support.subscribe(svc, "ops", receiver.url(rx, "/ok"))
    receiver.trust(rx, "/ok", secret)
    let raw = "{\"type\":\"order.created\",\"id\":\"evt_owned\",\"data\":{}}"
    let assert [#(delivery_id, _)] = support.publish(svc, "ops", raw)
    assert support.drain(svc) == Ok(1)
    support.settle()
    assert telemetry.trace(svc.collector, delivery_id) != []
    svc.collector
  }
  assert eventually(2000, fn() {
    collector_handlers("sinal/collector:webhooks_telemetry") == 0
  })
  assert telemetry.lines(collector) == []
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
