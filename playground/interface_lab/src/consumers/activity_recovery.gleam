// THROWAWAY: Which recovery outcomes preserve effects, budget, and uncertainty?
import lab/blueprint
import lab/saga
import lab/value

pub type PaymentReference {
  PaymentReference(String)
}

pub type PaymentError {
  PaymentOutcomeUnknown(PaymentReference)
  ReconciliationRequired(PaymentReference)
  PaymentRejected(String)
}

pub type PaymentCleanupError {
  ReservationCleanupUncertain(PaymentReference)
  ReservationUndoAttempted(PaymentReference)
  PaymentRepairFailed(String)
}

@external(erlang, "sinal_scripted_backend", "put")
fn set_counter(key: Int, value: Int) -> Nil

@external(erlang, "sinal_scripted_backend", "get")
fn get_counter(key: Int, default: Int) -> Int

@external(erlang, "erlang", "unique_integer")
fn new_counter_key() -> Int

pub fn probe() -> Nil {
  probe_payment_cancellation()
  probe_retry_budget_and_wakes()
  probe_retained_native_input()
  probe_direct_unresolved()
  probe_replacement_compensation()
  probe_explicit_abort()
  Nil
}

fn probe_payment_cancellation() -> Nil {
  let definition = payment_workflow()
  let assert Ok(started) = saga.start_local(definition, "order-7")
  let #(after_input, input_descriptor) = complete_paused(started)
  let assert True = input_descriptor == saga.LocalInputEncoding
  let #(after_reservation, reserve_descriptor) = complete_paused(after_input)
  let assert True =
    reserve_descriptor == saga.LocalActivityAt(address("payment.reserve"))
  let #(recovery_ready, payment_descriptor) = complete_paused(after_reservation)
  let assert True =
    payment_descriptor == saga.LocalActivityAt(address("payment.charge"))
  let #(transition, recovery_descriptor) = complete_next(recovery_ready)
  let assert True =
    recovery_descriptor
    == saga.LocalRecoveryAt(address("payment.charge"), attempts_used: 1)
  let assert saga.LocalRetryScheduled(waiting, wake, delay) = transition
  let assert True = saga.retry_delay_milliseconds(delay) == 500

  // Safe retry policy does not grant permission to undo an unknown charge.
  let assert saga.LocalExecutionUnresolved(unresolved, reason) =
    saga.advance_local(waiting, saga.CancelLocal)
  let reference = PaymentReference("provider-transaction-7")
  let assert saga.LocalUnresolvedActivity(
    at: failed_node,
    cause: PaymentOutcomeUnknown(actual_reference),
    evidence: ReconciliationRequired(actual_evidence),
    cleanup_failures: [
      saga.LocalUndoFailed(
        cleanup_node,
        ReservationCleanupUncertain(cleanup_reference),
      ),
    ],
  ) = reason
  let assert True = failed_node == address("payment.charge")
  let assert True = cleanup_node == address("payment.charge")
  let assert True = actual_reference == reference
  let assert True = actual_evidence == reference
  let assert True = cleanup_reference == reference
  let assert saga.LocalControlRejected(
    _,
    saga.LocalEffectUnresolvedRequiresResolution,
  ) = saga.advance_local(unresolved, saga.ContinueLocal)
  let assert saga.LocalControlRejected(
    _,
    saga.LocalEffectUnresolvedRequiresResolution,
  ) = saga.advance_local(unresolved, saga.CancelLocal)
  let assert saga.LocalControlRejected(_, saga.LocalWakeNotExpected) =
    saga.advance_local(unresolved, saga.WakeLocal(wake))
  Nil
}

fn probe_retry_budget_and_wakes() -> Nil {
  let definition = retry_workflow()
  let assert Ok(started) = saga.start_local(definition, "agent-request")
  let #(after_input, _) = complete_paused(started)
  let #(after_reservation, _) = complete_paused(after_input)
  let #(recovery_ready, _) = complete_paused(after_reservation)
  let #(first_transition, first_recovery) = complete_next(recovery_ready)
  let assert True =
    first_recovery == saga.LocalRecoveryAt(address("agent.invoke"), 1)
  let assert saga.LocalRetryScheduled(waiting, first_wake, first_delay) =
    first_transition
  let assert True = saga.retry_delay_milliseconds(first_delay) == 100

  // A wake from another execution cannot authorize this execution's retry.
  let assert Ok(other_started) = saga.start_local(definition, "other-request")
  let #(other_after_input, _) = complete_paused(other_started)
  let #(other_after_reservation, _) = complete_paused(other_after_input)
  let #(other_ready, _) = complete_paused(other_after_reservation)
  let #(other_transition, _) = complete_next(other_ready)
  let assert saga.LocalRetryScheduled(other_waiting, other_wake, _) =
    other_transition
  let assert saga.LocalControlRejected(_, saga.LocalWakeDoesNotMatch) =
    saga.advance_local(waiting, saga.WakeLocal(other_wake))

  let assert saga.LocalExecutionPaused(retry_ready) =
    saga.advance_local(waiting, saga.WakeLocal(first_wake))
  let assert saga.LocalControlRejected(_, saga.LocalWakeNotExpected) =
    saga.advance_local(retry_ready, saga.WakeLocal(first_wake))

  let #(second_recovery_ready, retry_descriptor) = complete_paused(retry_ready)
  let assert True =
    retry_descriptor == saga.LocalActivityAt(address("agent.invoke"))
  let #(second_transition, second_recovery) =
    complete_next(second_recovery_ready)
  let assert True =
    second_recovery == saga.LocalRecoveryAt(address("agent.invoke"), 2)
  let assert saga.LocalRetryScheduled(second_waiting, second_wake, second_delay) =
    second_transition
  let assert True = saga.retry_delay_milliseconds(second_delay) == 200
  let assert saga.LocalControlRejected(_, saga.LocalWakeDoesNotMatch) =
    saga.advance_local(second_waiting, saga.WakeLocal(first_wake))

  let assert saga.LocalExecutionPaused(third_retry_ready) =
    saga.advance_local(second_waiting, saga.WakeLocal(second_wake))
  let #(third_recovery_ready, _) = complete_paused(third_retry_ready)
  let #(blocked_transition, third_recovery) =
    complete_next(third_recovery_ready)
  let assert True =
    third_recovery == saga.LocalRecoveryAt(address("agent.invoke"), 3)
  let assert saga.LocalRetryBlocked(blocked) = blocked_transition
  let assert saga.LocalControlRejected(_, saga.LocalRetryBudgetExhausted) =
    saga.advance_local(blocked, saga.ContinueLocal)

  // At exhausted budget the effect remains held because the policy still
  // does not authorize rollback.
  let assert saga.LocalExecutionUnresolved(
    blocked_unresolved,
    saga.LocalUnresolvedActivity(
      at: blocked_node,
      cause: "agent-temporarily-unavailable",
      evidence: "budget-exhausted-effect-uncertain",
      cleanup_failures: [
        saga.LocalUndoFailed(cleanup_node, "agent-cleanup-unknown"),
      ],
    ),
  ) = saga.advance_local(blocked, saga.CancelLocal)
  let assert True = blocked_node == address("agent.invoke")
  let assert True = cleanup_node == address("agent.invoke")
  let assert saga.LocalControlRejected(
    _,
    saga.LocalEffectUnresolvedRequiresResolution,
  ) = saga.advance_local(blocked_unresolved, saga.CancelLocal)

  // Cancel during a retry wait follows the same explicit policy; a late wake
  // cannot restart the canceled execution.
  let assert saga.LocalExecutionPaused(wait_cancelled) =
    saga.advance_local(other_waiting, saga.CancelLocal)
  let assert saga.LocalControlRejected(_, saga.LocalWakeNotExpected) =
    saga.advance_local(wait_cancelled, saga.WakeLocal(other_wake))
  let cancel_report = drive_to_report(wait_cancelled)
  let assert saga.LocalExecutionFailed(
    saga.LocalCancelled([saga.LocalUndoFailed(_, "reservation-release-failed")]),
    [],
  ) = cancel_report
  Nil
}

fn probe_direct_unresolved() -> Nil {
  let definition =
    single_activity(
      "direct-unresolved",
      fn(_) { Error("tool-outcome-unknown") },
      saga.Uncompensated,
      WithRecovery(fn(_, cause, _) {
        let assert True = cause == "tool-outcome-unknown"
        saga.SuspendUnresolved("provider supplied no final receipt", [
          "cleanup-pending",
        ])
      }),
    )
  let assert Ok(started) = saga.start_local(definition, "request")
  let #(after_input, _) = complete_paused(started)
  let #(recovery_ready, _) = complete_paused(after_input)
  let #(transition, recovery_descriptor) = complete_next(recovery_ready)
  let assert True =
    recovery_descriptor
    == saga.LocalRecoveryAt(address("direct-unresolved"), attempts_used: 1)
  let assert saga.LocalExecutionUnresolved(
    unresolved,
    saga.LocalUnresolvedActivity(
      at: node,
      cause: "tool-outcome-unknown",
      evidence: "provider supplied no final receipt",
      cleanup_failures: [saga.LocalUndoFailed(cleanup_node, "cleanup-pending")],
    ),
  ) = transition
  let assert True = node == address("direct-unresolved")
  let assert True = cleanup_node == address("direct-unresolved")
  let assert saga.LocalControlRejected(
    _,
    saga.LocalEffectUnresolvedRequiresResolution,
  ) = saga.advance_local(unresolved, saga.ContinueLocal)
  Nil
}

fn probe_replacement_compensation() -> Nil {
  let definition = replacement_workflow()
  let assert Ok(started) = saga.start_local(definition, "batch-4")
  let report = drive_to_report(started)
  let assert saga.LocalExecutionFailed(
    saga.LocalFailed(
      saga.LocalApplicationCause(failed_node, "sink-failed"),
      undo_failures,
    ),
    [],
  ) = report
  let assert True = failed_node == address("etl.sink")
  let assert True =
    undo_failures
    == [
      saga.LocalUndoFailed(address("etl.transform"), "replacement-undo-failed"),
      saga.LocalUndoFailed(address("etl.reserve"), "reservation-undo-failed"),
    ]
  Nil
}

fn probe_retained_native_input() -> Nil {
  let decode_key = new_counter_key()
  let execute_key = new_counter_key()
  set_counter(decode_key, 0)
  set_counter(execute_key, 0)
  let target_input =
    blueprint.new(fn(text) { Ok(value.Text(text)) }, fn(raw) {
      let count = bump_counter(decode_key)
      case raw {
        value.Text(text) if count == 1 -> Ok("native:" <> text)
        value.Text(_) ->
          Error(blueprint.CannotDecode("retry decoded the input again"))
        _ -> Error(blueprint.CannotDecode("expected text"))
      }
    })
  let contract =
    saga.ActivityContract(
      saga.VersionedCodec(required_version(1), target_input),
      versioned_text(),
      versioned_text(),
      versioned_text(),
    )
  let activity =
    saga.activity(
      step("native.retry"),
      required_version(1),
      contract,
      fn(native_input) {
        let assert True = native_input == "native:request"
        case bump_counter(execute_key) {
          1 -> Error("retry-once")
          2 -> Ok("settled")
          _ -> panic as "the local retry must execute exactly once more"
        }
      },
      saga.Uncompensated,
    )
  let recovering =
    saga.recover_activity(activity, required_limit(2), fn(_, cause, _) {
      let assert True = cause == "retry-once"
      saga.RetryAfter(required_delay(0), saga.CompensateOnCancel)
    })
  let #(builder, input) =
    saga.begin(blueprint.text(), blueprint.text(), blueprint.text())
  let assert Ok(#(builder, output)) =
    saga.add_activity(builder, input, node("native.retry"), recovering)
  let definition = finish(builder, output, "native.retry")
  let assert Ok(started) = saga.start_local(definition, "request")
  let #(after_input, _) = complete_paused(started)
  let #(recovery_ready, activity_descriptor) = complete_paused(after_input)
  let assert True =
    activity_descriptor == saga.LocalActivityAt(address("native.retry"))
  let #(retry_transition, _) = complete_next(recovery_ready)
  let assert saga.LocalRetryScheduled(waiting, wake, _) = retry_transition
  let assert saga.LocalExecutionPaused(retry_ready) =
    saga.advance_local(waiting, saga.WakeLocal(wake))
  let #(after_retry, retry_descriptor) = complete_paused(retry_ready)
  let assert True =
    retry_descriptor == saga.LocalActivityAt(address("native.retry"))
  let assert True = get_counter(decode_key, 0) == 1
  let assert True = get_counter(execute_key, 0) == 2
  let assert saga.LocalExecutionSucceeded("settled", [saga.NamedAddress(_)]) =
    drive_to_report(after_retry)
  Nil
}

fn probe_explicit_abort() -> Nil {
  let definition = abort_workflow()
  let assert Ok(started) = saga.start_local(definition, "batch-9")
  let report = drive_to_report(started)
  let assert saga.LocalExecutionFailed(
    saga.LocalFailed(
      saga.LocalApplicationCause(failed_node, "operator-authorized-abort"),
      undo_failures,
    ),
    [],
  ) = report
  let assert True = failed_node == address("abort.process")
  let assert True =
    undo_failures
    == [
      saga.LocalUndoFailed(address("abort.process"), "recovery-cleanup-failed"),
      saga.LocalUndoFailed(address("abort.reserve"), "prior-undo-failed"),
    ]
  Nil
}

fn payment_workflow() -> saga.Definition(
  String,
  String,
  PaymentError,
  PaymentCleanupError,
) {
  let reference = PaymentReference("provider-transaction-7")
  let error_codec = payment_error_codec()
  let cleanup_codec = payment_cleanup_codec()
  let #(builder, input) =
    saga.begin(blueprint.text(), error_codec, cleanup_codec)
  let assert Ok(#(builder, reserved)) =
    saga.add_activity(
      builder,
      input,
      node("payment.reserve"),
      payment_activity(
        "payment.reserve",
        fn(order) { Ok("reserved:" <> order) },
        saga.Compensate(fn(_, _) { Error(ReservationUndoAttempted(reference)) }),
        NoPaymentRecovery,
      ),
    )
  let assert Ok(#(builder, charged)) =
    saga.add_activity(
      builder,
      reserved,
      node("payment.charge"),
      payment_activity(
        "payment.charge",
        fn(_) { Error(PaymentOutcomeUnknown(reference)) },
        saga.Uncompensated,
        WithPaymentRecovery(fn(_, cause, budget) {
          let assert PaymentOutcomeUnknown(actual_reference) = cause
          let assert True = saga.retry_budget_attempts_used(budget) == 1
          saga.RetryAfter(
            required_delay(500),
            saga.HoldOnCancel(ReconciliationRequired(actual_reference), [
              ReservationCleanupUncertain(actual_reference),
            ]),
          )
        }),
      ),
    )
  let assert Ok(definition) =
    saga.finish(
      builder,
      charged,
      definition_id("payment.uncertain"),
      required_version(1),
      "recovery:payment.uncertain",
    )
  definition
}

fn retry_workflow() -> saga.Definition(String, String, String, String) {
  let #(builder, input) =
    saga.begin(blueprint.text(), blueprint.text(), blueprint.text())
  let assert Ok(#(builder, reserved)) =
    saga.add_activity(
      builder,
      input,
      node("agent.reserve"),
      make_activity(
        "agent.reserve",
        fn(request) { Ok("reserved:" <> request) },
        saga.Compensate(fn(_, _) { Error("reservation-release-failed") }),
        NoRecovery,
      ),
    )
  let assert Ok(#(builder, invoked)) =
    saga.add_activity(
      builder,
      reserved,
      node("agent.invoke"),
      make_activity(
        "agent.invoke",
        fn(_) { Error("agent-temporarily-unavailable") },
        saga.Uncompensated,
        WithRecovery(fn(_, cause, budget) {
          let assert True = cause == "agent-temporarily-unavailable"
          case saga.retry_budget_attempts_remaining(budget) {
            2 -> saga.RetryAfter(required_delay(100), saga.CompensateOnCancel)
            1 -> saga.RetryAfter(required_delay(200), saga.CompensateOnCancel)
            0 ->
              saga.RetryAfter(
                required_delay(300),
                saga.HoldOnCancel("budget-exhausted-effect-uncertain", [
                  "agent-cleanup-unknown",
                ]),
              )
            _ -> panic as "attempt budget must be bounded by its opaque limit"
          }
        }),
      ),
    )
  finish(builder, invoked, "agent.retry")
}

fn replacement_workflow() -> saga.Definition(String, String, String, String) {
  let #(builder, input) =
    saga.begin(blueprint.text(), blueprint.text(), blueprint.text())
  let assert Ok(#(builder, reserved)) =
    saga.add_activity(
      builder,
      input,
      node("etl.reserve"),
      make_activity(
        "etl.reserve",
        fn(batch) { Ok("reserved:" <> batch) },
        saga.Compensate(fn(_, _) { Error("reservation-undo-failed") }),
        NoRecovery,
      ),
    )
  let assert Ok(#(builder, transformed)) =
    saga.add_activity(
      builder,
      reserved,
      node("etl.transform"),
      make_activity(
        "etl.transform",
        fn(_) { Error("transform-effect-uncertain") },
        saga.Compensate(fn(_, _) { Error("wrong-original-undo-ran") }),
        WithRecovery(fn(_, _, _) {
          saga.UseOutput(
            "recovered-transform",
            saga.Compensate(fn(_, _) { Error("replacement-undo-failed") }),
          )
        }),
      ),
    )
  let assert Ok(#(builder, output)) =
    saga.add_activity(
      builder,
      transformed,
      node("etl.sink"),
      make_activity(
        "etl.sink",
        fn(_) { Error("sink-failed") },
        saga.Uncompensated,
        NoRecovery,
      ),
    )
  finish(builder, output, "etl.recovery")
}

fn abort_workflow() -> saga.Definition(String, String, String, String) {
  let #(builder, input) =
    saga.begin(blueprint.text(), blueprint.text(), blueprint.text())
  let assert Ok(#(builder, reserved)) =
    saga.add_activity(
      builder,
      input,
      node("abort.reserve"),
      make_activity(
        "abort.reserve",
        fn(batch) { Ok("reserved:" <> batch) },
        saga.Compensate(fn(_, _) { Error("prior-undo-failed") }),
        NoRecovery,
      ),
    )
  let assert Ok(#(builder, processed)) =
    saga.add_activity(
      builder,
      reserved,
      node("abort.process"),
      make_activity(
        "abort.process",
        fn(_) { Error("process-failed") },
        saga.Uncompensated,
        WithRecovery(fn(_, _, _) {
          saga.AbortAndCompensate("operator-authorized-abort", [
            "recovery-cleanup-failed",
          ])
        }),
      ),
    )
  finish(builder, processed, "abort.workflow")
}

fn make_activity(
  name: String,
  execute: fn(String) -> Result(String, String),
  compensation: saga.Compensation(String, String, String),
  recovery: RecoverySpec,
) -> saga.Activity(String, String, String, String) {
  let descriptor =
    saga.activity(
      step(name),
      required_version(1),
      saga.ActivityContract(
        versioned_text(),
        versioned_text(),
        versioned_text(),
        versioned_text(),
      ),
      execute,
      compensation,
    )
  case recovery {
    NoRecovery -> descriptor
    WithRecovery(recover) ->
      saga.recover_activity(descriptor, required_limit(3), recover)
  }
}

fn single_activity(
  name: String,
  execute: fn(String) -> Result(String, String),
  compensation: saga.Compensation(String, String, String),
  recovery: RecoverySpec,
) -> saga.Definition(String, String, String, String) {
  saga.define(
    definition_id(name),
    required_version(1),
    "recovery:" <> name,
    make_activity(name, execute, compensation, recovery),
  )
}

fn payment_activity(
  name: String,
  execute: fn(String) -> Result(String, PaymentError),
  compensation: saga.Compensation(String, String, PaymentCleanupError),
  recovery: PaymentRecoverySpec,
) -> saga.Activity(String, String, PaymentError, PaymentCleanupError) {
  let activity =
    saga.activity(
      step(name),
      required_version(1),
      saga.ActivityContract(
        versioned_text(),
        versioned_text(),
        saga.VersionedCodec(required_version(1), payment_error_codec()),
        saga.VersionedCodec(required_version(1), payment_cleanup_codec()),
      ),
      execute,
      compensation,
    )
  case recovery {
    NoPaymentRecovery -> activity
    WithPaymentRecovery(recover) ->
      saga.recover_activity(activity, required_limit(3), recover)
  }
}

fn payment_error_codec() -> blueprint.Codec(PaymentError) {
  blueprint.new(
    fn(error) {
      let raw = case error {
        PaymentOutcomeUnknown(PaymentReference(reference)) ->
          value.Array([value.Text("unknown"), value.Text(reference)])
        ReconciliationRequired(PaymentReference(reference)) ->
          value.Array([value.Text("reconcile"), value.Text(reference)])
        PaymentRejected(reason) ->
          value.Array([value.Text("rejected"), value.Text(reason)])
      }
      Ok(raw)
    },
    fn(raw) {
      case raw {
        value.Array([value.Text("unknown"), value.Text(reference)]) ->
          Ok(PaymentOutcomeUnknown(PaymentReference(reference)))
        value.Array([value.Text("reconcile"), value.Text(reference)]) ->
          Ok(ReconciliationRequired(PaymentReference(reference)))
        value.Array([value.Text("rejected"), value.Text(reason)]) ->
          Ok(PaymentRejected(reason))
        _ -> Error(blueprint.CannotDecode("invalid payment error"))
      }
    },
  )
}

fn payment_cleanup_codec() -> blueprint.Codec(PaymentCleanupError) {
  blueprint.new(
    fn(error) {
      let raw = case error {
        ReservationCleanupUncertain(PaymentReference(reference)) ->
          value.Array([value.Text("uncertain"), value.Text(reference)])
        ReservationUndoAttempted(PaymentReference(reference)) ->
          value.Array([value.Text("undo-attempted"), value.Text(reference)])
        PaymentRepairFailed(reason) ->
          value.Array([value.Text("repair-failed"), value.Text(reason)])
      }
      Ok(raw)
    },
    fn(raw) {
      case raw {
        value.Array([value.Text("uncertain"), value.Text(reference)]) ->
          Ok(ReservationCleanupUncertain(PaymentReference(reference)))
        value.Array([value.Text("undo-attempted"), value.Text(reference)]) ->
          Ok(ReservationUndoAttempted(PaymentReference(reference)))
        value.Array([value.Text("repair-failed"), value.Text(reason)]) ->
          Ok(PaymentRepairFailed(reason))
        _ -> Error(blueprint.CannotDecode("invalid payment cleanup error"))
      }
    },
  )
}

fn finish(
  builder: saga.Builder(String, String, String),
  output: saga.Port(String),
  name: String,
) -> saga.Definition(String, String, String, String) {
  let assert Ok(definition) =
    saga.finish(
      builder,
      output,
      definition_id(name),
      required_version(1),
      "recovery:" <> name,
    )
  definition
}

fn complete_paused(
  execution: saga.LocalExecution(o, e, u),
) -> #(saga.LocalExecution(o, e, u), saga.LocalWorkDescriptor) {
  let #(transition, descriptor) = complete_next(execution)
  let assert saga.LocalExecutionPaused(next) = transition
  #(next, descriptor)
}

fn complete_next(
  execution: saga.LocalExecution(o, e, u),
) -> #(saga.LocalTransition(o, e, u), saga.LocalWorkDescriptor) {
  case saga.advance_local(execution, saga.ContinueLocal) {
    saga.LocalWorkIssued(waiting, work) -> {
      let descriptor = saga.local_work_descriptor(work)
      let completion = saga.perform_local(work)
      #(saga.advance_local(waiting, saga.CompleteLocal(completion)), descriptor)
    }
    _ -> panic as "this probe step must issue one local work item"
  }
}

fn drive_to_report(
  execution: saga.LocalExecution(o, e, u),
) -> saga.LocalReport(o, e, u) {
  case saga.advance_local(execution, saga.ContinueLocal) {
    saga.LocalWorkIssued(waiting, work) -> {
      let completion = saga.perform_local(work)
      case saga.advance_local(waiting, saga.CompleteLocal(completion)) {
        saga.LocalExecutionPaused(next) -> drive_to_report(next)
        saga.LocalExecutionFinished(_, report) -> report
        _ -> panic as "known local work must finish, pause, or fail"
      }
    }
    saga.LocalExecutionPaused(next) -> drive_to_report(next)
    saga.LocalExecutionFinished(_, report) -> report
    _ -> panic as "this workflow must reach a terminal local report"
  }
}

fn versioned_text() -> saga.VersionedCodec(String) {
  saga.VersionedCodec(required_version(1), blueprint.text())
}

fn required_limit(value: Int) -> saga.AttemptLimit {
  let assert Ok(limit) = saga.attempt_limit(value)
  limit
}

fn bump_counter(key: Int) -> Int {
  let next = get_counter(key, 0) + 1
  set_counter(key, next)
  next
}

fn required_delay(value: Int) -> saga.RetryDelay {
  let assert Ok(delay) = saga.retry_delay(value)
  delay
}

fn required_version(value: Int) -> saga.Version {
  let assert Ok(version) = saga.version(value)
  version
}

fn step(name: String) -> saga.StepId {
  let assert Ok(id) = saga.step_id(name)
  id
}

fn node(name: String) -> saga.NodeId {
  let assert Ok(id) = saga.node_id(name)
  id
}

fn address(name: String) -> saga.NodeAddress {
  saga.NamedAddress(node(name))
}

fn definition_id(name: String) -> saga.DefinitionId {
  let assert Ok(id) = saga.definition_id(name)
  id
}

type RecoverySpec {
  NoRecovery
  WithRecovery(
    fn(String, String, saga.RetryBudget) ->
      saga.RecoveryDecision(String, String, String),
  )
}

type PaymentRecoverySpec {
  NoPaymentRecovery
  WithPaymentRecovery(
    fn(String, PaymentError, saga.RetryBudget) ->
      saga.RecoveryDecision(String, PaymentError, PaymentCleanupError),
  )
}
