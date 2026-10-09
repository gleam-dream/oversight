//// Proposed contract, intentionally red against the current Relay runtime.
//// Run separately from the passing characterization suite. All fixtures clean
//// up before their observations are asserted, including on the red path.

import admission_probe as probe
import gleam/io
import gleam/list
import gleam/string

fn admission_checks(
  admission: probe.Admission,
  carrier: probe.Carrier,
) -> List(Bool) {
  let observed = probe.blocked(admission, carrier)
  io.println(string.inspect(#(admission, carrier, observed)))
  [
    observed.before_release == Ok(504),
    observed.capacity_before_release == 200,
    observed.dispatched == Error(Nil),
    observed.child_alive_past_deadline == False,
  ]
}

fn disconnect_checks(admission: probe.Admission) -> List(Bool) {
  let observed = probe.disconnect(admission)
  io.println(string.inspect(#(admission, observed)))
  [
    observed.capacity_while_disconnected == 200,
    observed.callback_alive == False,
    observed.child_alive == False,
    observed.dispatched_after_release == Error(Nil),
  ]
}

fn budget_checks(carrier: probe.Carrier) -> List(Bool) {
  let observed = probe.shared_budget(carrier)
  io.println(string.inspect(#(carrier, observed)))
  // Dispatch may classify expiry as its MCP invocation error instead of HTTP
  // 504. The required invariant here is termination on the original budget.
  [
    case observed.before_handler_release {
      Ok(_) -> True
      Error(_) -> False
    },
  ]
}

pub fn main() {
  let checks =
    list.flatten([
      admission_checks(probe.Context, probe.Buffered),
      admission_checks(probe.Verification, probe.Buffered),
      admission_checks(probe.Context, probe.Listener),
      admission_checks(probe.Verification, probe.Listener),
      disconnect_checks(probe.Context),
      disconnect_checks(probe.Verification),
      budget_checks(probe.Buffered),
      budget_checks(probe.Listener),
    ])
  let failed = list.count(checks, fn(passed) { !passed })
  io.println("Failed proposed invariants: " <> string.inspect(failed))
  let assert 0 = failed
    as "Relay admission does not yet satisfy the proposed deadline contract"
}
