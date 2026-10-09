import admission_probe as probe
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn check_blocked(admission: probe.Admission, carrier: probe.Carrier) {
  let observed = probe.blocked(admission, carrier)
  observed.before_release |> should.equal(Error(Nil))
  observed.capacity_before_release |> should.equal(503)
  observed.after_release |> should.equal(Ok(200))
  observed.capacity_after_release |> should.equal(200)
  observed.dispatched |> should.equal(Ok("acme"))
  observed.subject_owned_by_callback |> should.be_true
  observed.child_alive_past_deadline |> should.be_true
  observed.callback_runs_in_caller |> should.equal(carrier == probe.Buffered)
}

pub fn buffered_context_is_outside_timeout_test() {
  check_blocked(probe.Context, probe.Buffered)
}

pub fn buffered_verifier_is_outside_timeout_test() {
  check_blocked(probe.Verification, probe.Buffered)
}

pub fn listener_context_is_outside_timeout_test() {
  check_blocked(probe.Context, probe.Listener)
}

pub fn listener_verifier_is_outside_timeout_test() {
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
  observed.capacity_while_disconnected |> should.equal(503)
  observed.callback_alive |> should.be_true
  observed.child_alive |> should.be_true
  // Dispatch after release races disconnect observation; absence is not an
  // existing guarantee. The proposed contract must eliminate that race.
}

pub fn disconnect_does_not_interrupt_context_test() {
  check_disconnect(probe.Context)
}

pub fn disconnect_does_not_interrupt_verifier_test() {
  check_disconnect(probe.Verification)
}

pub fn default_endpoint_works_test() {
  probe.defaults() |> should.equal(200)
}

pub fn buffered_dispatch_gets_fresh_budget_test() {
  probe.shared_budget(probe.Buffered)
  |> should.equal(probe.BudgetObservation(Error(Nil), Ok(200)))
}

pub fn listener_dispatch_gets_fresh_budget_test() {
  probe.shared_budget(probe.Listener)
  |> should.equal(probe.BudgetObservation(Error(Nil), Ok(200)))
}
