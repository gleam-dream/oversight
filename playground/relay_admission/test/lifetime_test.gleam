import admission_probe as probe
import gleeunit/should
import lifetime_probe as lifetime

pub fn retiring_callback_retains_capacity_until_termination_test() {
  probe.retirement()
  |> should.equal(probe.RetirementObservation(
    Ok(504),
    True,
    503,
    True,
    200,
    Error(Nil),
  ))
}

pub fn positive_context_return_after_deadline_cannot_dispatch_test() {
  probe.late_context_success()
  |> should.equal(probe.LateAdmissionObservation(
    Ok(504),
    True,
    Error(Nil),
    True,
    200,
  ))
}

fn check_lifetime(carrier: probe.Carrier) {
  lifetime.resource_lifetime(carrier)
  |> should.equal(lifetime.LifetimeObservation(
    False,
    True,
    True,
    Ok(200),
    True,
    True,
  ))
}

pub fn buffered_callback_subject_lives_through_tool_test() {
  check_lifetime(probe.Buffered)
}

pub fn listener_callback_subject_lives_through_tool_test() {
  check_lifetime(probe.Listener)
}

pub fn endpoint_stop_cleans_callback_and_preserves_borrowed_actor_test() {
  lifetime.shutdown(lifetime.EndpointStop)
  |> should.equal(lifetime.ShutdownObservation(True, True, Error(Nil)))
}

pub fn buffered_caller_death_cleans_callback_and_preserves_borrowed_actor_test() {
  lifetime.shutdown(lifetime.CallerDeath)
  |> should.equal(lifetime.ShutdownObservation(True, True, Error(Nil)))
}

pub fn callback_panic_returns_500_and_preserves_caller_test() {
  lifetime.callback_panic()
  |> should.equal(lifetime.PanicObservation(Ok(500), True, 200))
}

pub fn policy_returning_after_deadline_cannot_dispatch_test() {
  let observed = lifetime.delayed_policy()
  observed.response_before_release |> should.equal(Ok(504))
  observed.dispatched |> should.equal(Error(Nil))
}
