import admission_probe as probe
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn check_blocked(admission: probe.Admission, carrier: probe.Carrier) {
  let observed = probe.blocked(admission, carrier)
  observed.before_release |> should.equal(Ok(504))
  observed.capacity_before_release |> should.equal(200)
  observed.after_release |> should.equal(Ok(504))
  observed.capacity_after_release |> should.equal(200)
  observed.dispatched |> should.equal(Error(Nil))
  observed.subject_owned_by_callback |> should.be_true
  observed.child_alive_past_deadline |> should.be_false
  observed.child_alive_after_response |> should.be_false
  observed.callback_runs_in_caller |> should.be_false
}

pub fn buffered_context_shares_deadline_test() {
  check_blocked(probe.Context, probe.Buffered)
}

pub fn buffered_verifier_shares_deadline_test() {
  check_blocked(probe.Verification, probe.Buffered)
}

pub fn listener_context_shares_deadline_test() {
  check_blocked(probe.Context, probe.Listener)
}

pub fn listener_verifier_shares_deadline_test() {
  check_blocked(probe.Verification, probe.Listener)
}

pub fn buffered_authentication_refusal_and_recovery_test() {
  probe.authorization_control(probe.Buffered)
  |> should.equal(#(200, 401, 200, ["acme", "acme"]))
}

pub fn listener_authentication_refusal_and_recovery_test() {
  probe.authorization_control(probe.Listener)
  |> should.equal(#(200, 401, 200, ["acme", "acme"]))
}

fn check_disconnect(admission: probe.Admission) {
  let observed = probe.disconnect(admission)
  observed.capacity_while_disconnected |> should.equal(200)
  observed.callback_alive |> should.be_false
  observed.child_alive |> should.be_false
  observed.dispatched_after_release |> should.equal(Error(Nil))
}

pub fn disconnect_cancels_context_test() {
  check_disconnect(probe.Context)
}

pub fn disconnect_cancels_verifier_test() {
  check_disconnect(probe.Verification)
}

pub fn default_endpoint_works_test() {
  probe.defaults() |> should.equal(200)
}

fn check_budget(carrier: probe.Carrier) {
  let observed = probe.shared_budget(carrier)
  // Expiry may be HTTP 504 or an MCP invocation outcome carried by HTTP 200.
  // An unrelated endpoint failure does not prove the shared budget contract.
  {
    observed.before_handler_release == Ok(200)
    || observed.before_handler_release == Ok(504)
  }
  |> should.be_true
  observed.after_handler_release
  |> should.equal(observed.before_handler_release)
}

pub fn buffered_dispatch_receives_remaining_budget_test() {
  check_budget(probe.Buffered)
}

pub fn listener_dispatch_receives_remaining_budget_test() {
  check_budget(probe.Listener)
}
