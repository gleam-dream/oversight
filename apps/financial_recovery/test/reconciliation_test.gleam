import financial_recovery/coordinator
import financial_recovery/domain.{type Payment, OperationId, Payment}
import financial_recovery/payments
import financial_recovery/provider
import financial_recovery/reconciliation
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/option
import gleam/time/duration
import grind
import grind/admin
import grind/job
import pog
import saga/durable
import saga/execution
import scripted_provider
import sinal
import support

fn decision(id: String) -> reconciliation.Decision {
  reconciliation.Decision(
    id,
    "operator-alice",
    "Confirm and post from provider evidence",
  )
}

fn held(f: support.Fixture, id: String) -> job.JobHandle(Payment, String, Nil) {
  let assert Ok(Nil) = payments.account(f.deps.connection, "alice", 1000)
  let assert Ok(Nil) = payments.account(f.deps.connection, "bob", 0)
  let payment = Payment(OperationId(id), "alice", "bob", 250)
  let assert Ok(coordinator.Queued(handle)) =
    coordinator.admit(f.jobs, coordinator.definition(f.deps), payment)
  let assert Ok(grind.Uncertain(_)) =
    grind.await(f.jobs, handle, within: duration.seconds(5))
  handle
}

pub fn committed_settlement_survives_reconciler_death_before_queue_resolution_test() {
  interrupted_reconciliation(
    "finance_reconcile_commit",
    reconciliation.settlement_committed(),
  )
}

pub fn failed_local_acknowledgment_rolls_back_queue_resolution_test() {
  use f <- support.with_runtime(
    "finance_reconcile_ack_failure",
    scripted_provider.LoseReply,
  )
  let handle = held(f, "ack-failure")
  let assert Ok(_) =
    pog.query(
      "ALTER TABLE reconciliations ADD CONSTRAINT refuse_ack CHECK (NOT queue_confirmed)",
    )
    |> pog.execute(f.deps.connection)
  let assert Error(reconciliation.Database(_)) =
    reconciliation.reconcile(
      f.deps,
      f.jobs,
      job.id(handle),
      decision("ack-failure"),
    )
  assert grind.state(f.jobs, handle) == Ok(job.Uncertain)
  let assert Ok(record) = reconciliation.read(f.deps.connection, "ack-failure")
  assert !record.queue_confirmed
  assert payments.balance(f.deps.connection, "alice") == Ok(#(750, 0))
  let assert Ok(_) =
    pog.query("ALTER TABLE reconciliations DROP CONSTRAINT refuse_ack")
    |> pog.execute(f.deps.connection)
  scripted_provider.visible(f.peer.pid, False)
  let assert Ok(recovered) =
    reconciliation.resume(f.deps, f.jobs, "ack-failure")
  assert recovered.queue_confirmed
  assert scripted_provider.counts(f.peer.pid) == #(1, 1)
}

fn interrupted_reconciliation(schema: String, event: sinal.Event(Nil, String)) {
  use f <- support.with_runtime(schema, scripted_provider.LoseReply)
  let handle = held(f, schema)
  let committed = process.new_subject()
  let observer =
    sinal.observe(event, fn(_, id) {
      process.send(committed, #(process.self(), id))
      let gate = process.new_subject()
      let assert Ok(Nil) = process.receive(gate, 30_000)
      Nil
    })
  let _ =
    process.spawn_unlinked(fn() {
      let assert Ok(_) =
        reconciliation.reconcile(
          f.deps,
          f.jobs,
          job.id(handle),
          decision(schema),
        )
    })
  let assert Ok(#(runner, id)) = process.receive(committed, 3000)
  process.kill(runner)
  let assert Ok(Nil) = sinal.detach(observer)
  assert payments.balance(f.deps.connection, "alice") == Ok(#(750, 0))
  let assert Ok([retained]) =
    reconciliation.pending(f.deps.connection, 10, after: option.None)
  assert retained.decision.id == id
  assert !retained.queue_confirmed
  // Recovery needs only the persisted decision ID; no live job handle or lookup.
  scripted_provider.visible(f.peer.pid, False)
  let assert Ok(recovered) = reconciliation.resume(f.deps, f.jobs, id)
  assert recovered.queue_confirmed
  assert reconciliation.pending(f.deps.connection, 10, after: option.None)
    == Ok([])
  assert grind.outcome(f.jobs, handle)
    == Ok(grind.Succeeded("provider-" <> schema))
  assert payments.balance(f.deps.connection, "bob") == Ok(#(250, 0))
  assert scripted_provider.counts(f.peer.pid) == #(1, 1)
}

pub fn finished_unknown_reconciles_once_without_rewriting_saga_test() {
  use f <- support.with_runtime(
    "finance_reconcile_finished",
    scripted_provider.LoseReply,
  )
  let assert Ok(Nil) = payments.account(f.deps.connection, "alice", 1000)
  let assert Ok(Nil) = payments.account(f.deps.connection, "bob", 0)
  let payment = Payment(OperationId("settle-finished"), "alice", "bob", 250)
  let assert Ok(coordinator.Queued(handle)) =
    coordinator.admit(f.jobs, coordinator.definition(f.deps), payment)
  let assert Ok(grind.Uncertain(_)) =
    grind.await(f.jobs, handle, within: duration.seconds(5))
  let assert Ok(run) = coordinator.start(f.deps, payment)
  let assert Ok(original) = durable.read(run)
  let assert durable.Finished(execution.Unresolved(_, _, _)) = original
  let request = decision("finished-resolution")
  let assert Ok(record) =
    reconciliation.reconcile(f.deps, f.jobs, job.id(handle), request)
  assert record.reference == "provider-settle-finished"
  assert record.queue_confirmed
  assert record.operation == payment.id
  assert record.decision == request
  assert payments.balance(f.deps.connection, "alice") == Ok(#(750, 0))
  assert payments.balance(f.deps.connection, "bob") == Ok(#(250, 0))
  assert grind.outcome(f.jobs, handle) == Ok(grind.Succeeded(record.reference))
  assert durable.read(run) == Ok(original)
  assert reconciliation.reconcile(f.deps, f.jobs, job.id(handle), request)
    == Ok(record)
  assert scripted_provider.counts(f.peer.pid) == #(1, 1)
  assert coordinator.admit(f.jobs, coordinator.definition(f.deps), payment)
    == Ok(coordinator.Completed(record.reference))
  process.sleep(5)
  assert admin.prune_finished(
      f.jobs,
      older_than: duration.milliseconds(1),
      limit: 10,
    )
    == Ok(1)
  assert reconciliation.resume(f.deps, f.jobs, request.id) == Ok(record)
  assert scripted_provider.counts(f.peer.pid) == #(1, 1)
}

pub fn unavailable_missing_and_empty_evidence_keep_the_reservation_test() {
  use f <- support.with_runtime(
    "finance_reconcile_missing",
    scripted_provider.LoseReply,
  )
  let handle = held(f, "missing-evidence")
  let request = decision("missing-evidence-decision")
  scripted_provider.visible(f.peer.pid, False)
  assert reconciliation.reconcile(f.deps, f.jobs, job.id(handle), request)
    == Error(reconciliation.Lookup(provider.Status(503)))
  scripted_provider.visible(f.peer.pid, True)
  scripted_provider.forget(f.peer.pid, "missing-evidence")
  assert reconciliation.reconcile(f.deps, f.jobs, job.id(handle), request)
    == Error(reconciliation.Lookup(provider.Status(404)))
  scripted_provider.reference(f.peer.pid, "missing-evidence", "")
  assert reconciliation.reconcile(f.deps, f.jobs, job.id(handle), request)
    == Error(reconciliation.Lookup(provider.InvalidResponse))
  assert payments.balance(f.deps.connection, "alice") == Ok(#(1000, 250))
  assert reconciliation.read(f.deps.connection, request.id)
    == Error(reconciliation.MissingDecision)
  assert grind.state(f.jobs, handle) == Ok(job.Uncertain)
  assert scripted_provider.counts(f.peer.pid) == #(1, 3)
}

pub fn conflicting_evidence_rolls_back_the_decision_and_posting_test() {
  use f <- support.with_runtime(
    "finance_reconcile_conflict",
    scripted_provider.LoseReply,
  )
  let handle = held(f, "conflicting-evidence")
  let assert Ok(Nil) =
    payments.evidence(
      f.deps.connection,
      OperationId("conflicting-evidence"),
      "previous-confirmation",
    )
  let request = decision("conflicting-decision")
  assert reconciliation.reconcile(f.deps, f.jobs, job.id(handle), request)
    == Error(reconciliation.Payment(domain.EvidenceConflict))
  assert reconciliation.read(f.deps.connection, request.id)
    == Error(reconciliation.MissingDecision)
  assert payments.balance(f.deps.connection, "alice") == Ok(#(1000, 250))
  assert payments.posting(
      f.deps.connection,
      OperationId("conflicting-evidence"),
    )
    == Error(domain.EvidenceRequired)
  assert grind.state(f.jobs, handle) == Ok(job.Uncertain)
}

pub fn cancellation_does_not_prevent_recording_a_confirmed_payment_test() {
  use f <- support.with_runtime(
    "finance_reconcile_cancel",
    scripted_provider.LoseReply,
  )
  let handle = held(f, "cancelled-confirmed")
  let assert Ok(_) = grind.cancel(f.jobs, handle)
  assert admin.resolve_uncertain(
      f.jobs,
      handle,
      admin.resolution(
        admin.AuthorizeReplay,
        id: "no-replay",
        by: "operator",
        details: "Cancellation forbids delivery",
      ),
    )
    == Error(admin.CancellationPending)
  let assert Ok(record) =
    reconciliation.reconcile(
      f.deps,
      f.jobs,
      job.id(handle),
      decision("cancelled-settlement"),
    )
  assert record.queue_confirmed
  assert payments.balance(f.deps.connection, "alice") == Ok(#(750, 0))
  assert scripted_provider.counts(f.peer.pid) == #(1, 1)
}

pub fn decision_identity_rejects_changed_actor_reason_or_job_test() {
  use f <- support.with_runtime(
    "finance_reconcile_identity",
    scripted_provider.LoseReply,
  )
  let handle = held(f, "decision-identity")
  let original = decision("bound-decision")
  assert reconciliation.reconcile(
      f.deps,
      f.jobs,
      job.id(handle),
      reconciliation.Decision(..original, by: " "),
    )
    == Error(reconciliation.InvalidDecisionField("by"))
  let assert Ok(record) =
    reconciliation.reconcile(f.deps, f.jobs, job.id(handle), original)
  assert reconciliation.reconcile(
      f.deps,
      f.jobs,
      job.id(handle),
      reconciliation.Decision(..original, by: "operator-bob"),
    )
    == Error(reconciliation.DecisionConflict)
  assert reconciliation.reconcile(
      f.deps,
      f.jobs,
      job.id(handle),
      reconciliation.Decision(..original, details: "changed"),
    )
    == Error(reconciliation.DecisionConflict)
  assert reconciliation.reconcile(f.deps, f.jobs, job.id(handle) + 1, original)
    == Error(reconciliation.DecisionConflict)
  assert reconciliation.read(f.deps.connection, original.id) == Ok(record)
  assert reconciliation.pending(f.deps.connection, 0, after: option.None)
    == Error(reconciliation.InvalidLimit)
  assert reconciliation.pending(f.deps.connection, 101, after: option.None)
    == Error(reconciliation.InvalidLimit)
  assert scripted_provider.counts(f.peer.pid) == #(1, 1)
}

pub fn concurrent_identical_decisions_converge_on_one_posting_test() {
  use f <- support.with_runtime(
    "finance_reconcile_concurrent",
    scripted_provider.LoseReply,
  )
  let handle = held(f, "concurrent-settlement")
  let ready = process.new_subject()
  let done = process.new_subject()
  let blocker =
    process.spawn(fn() {
      let assert Ok(Nil) =
        pog.transaction(f.deps.connection, fn(tx) {
          let assert Ok(_) =
            pog.query("LOCK TABLE reconciliations IN EXCLUSIVE MODE")
            |> pog.execute(tx)
          let gate = process.new_subject()
          process.send(ready, gate)
          let assert Ok(Nil) = process.receive(gate, 3000)
          Ok(Nil)
        })
    })
  let assert Ok(release) = process.receive(ready, 1000)
  let request = decision("concurrent-decision")
  let _ =
    process.spawn(fn() {
      process.send(
        done,
        reconciliation.reconcile(f.deps, f.jobs, job.id(handle), request),
      )
    })
  let _ =
    process.spawn(fn() {
      process.send(
        done,
        reconciliation.reconcile(f.deps, f.jobs, job.id(handle), request),
      )
    })
  // Both transactions have reached the real INSERT, rather than just starting
  // two processes which could run sequentially.
  assert wait_for_inserts(f.deps.connection, 100)
  process.send(release, Nil)
  let assert Ok(Ok(first)) = process.receive(done, 3000)
  let assert Ok(Ok(second)) = process.receive(done, 3000)
  assert first == second
  assert first.queue_confirmed
  assert payments.balance(f.deps.connection, "alice") == Ok(#(750, 0))
  assert payments.balance(f.deps.connection, "bob") == Ok(#(250, 0))
  assert scripted_provider.counts(f.peer.pid) == #(1, 2)
  // The blocker has completed normally; no links or locks survive the fixture.
  process.unlink(blocker)
}

fn wait_for_inserts(connection: pog.Connection, remaining: Int) -> Bool {
  let assert Ok(pog.Returned(_, [count])) =
    pog.query(
      "SELECT count(*)::int FROM pg_stat_activity WHERE wait_event_type='Lock' AND query LIKE 'INSERT INTO reconciliations%'",
    )
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(connection)
  case count == 2, remaining > 0 {
    True, _ -> True
    False, False -> False
    False, True -> {
      process.sleep(5)
      wait_for_inserts(connection, remaining - 1)
    }
  }
}

pub fn pruning_after_queue_confirmation_never_repeats_the_payment_test() {
  use f <- support.with_runtime(
    "finance_reconcile_pruned",
    scripted_provider.LoseReply,
  )
  let handle = held(f, "reconcile-pruned")
  let committed = process.new_subject()
  let observer =
    sinal.observe(reconciliation.queue_confirmed(), fn(_, id) {
      process.send(committed, #(process.self(), id))
      let gate = process.new_subject()
      let assert Ok(Nil) = process.receive(gate, 30_000)
      Nil
    })
  let _ =
    process.spawn_unlinked(fn() {
      let assert Ok(_) =
        reconciliation.reconcile(
          f.deps,
          f.jobs,
          job.id(handle),
          decision("pruned-resolution"),
        )
    })
  let assert Ok(#(runner, id)) = process.receive(committed, 3000)
  process.kill(runner)
  let assert Ok(Nil) = sinal.detach(observer)
  process.sleep(5)
  assert admin.prune_finished(
      f.jobs,
      older_than: duration.milliseconds(1),
      limit: 10,
    )
    == Ok(1)
  // The local acknowledgment must commit with queue resolution and survive pruning.
  let assert Ok(recovered) = reconciliation.resume(f.deps, f.jobs, id)
  assert recovered.queue_confirmed
  let assert Ok([]) =
    reconciliation.pending(f.deps.connection, 10, after: option.None)
  assert payments.balance(f.deps.connection, "alice") == Ok(#(750, 0))
  let payment = Payment(OperationId("reconcile-pruned"), "alice", "bob", 250)
  assert coordinator.admit(f.jobs, coordinator.definition(f.deps), payment)
    == Ok(coordinator.Completed("provider-reconcile-pruned"))
  assert scripted_provider.counts(f.peer.pid) == #(1, 1)
}

pub fn posting_failure_rolls_back_evidence_and_audit_before_queue_confirmation_test() {
  use f <- support.with_runtime(
    "finance_reconcile_rollback",
    scripted_provider.LoseReply,
  )
  let handle = held(f, "failed-posting")
  let request = decision("failed-posting-decision")
  // A real application constraint fails after the account UPDATE statements.
  let assert Ok(_) =
    pog.query(
      "ALTER TABLE operations ADD CONSTRAINT refuse_posting CHECK (NOT posted)",
    )
    |> pog.execute(f.deps.connection)
  let assert Error(reconciliation.Payment(domain.Database(_))) =
    reconciliation.reconcile(f.deps, f.jobs, job.id(handle), request)
  assert payments.read(f.deps.connection, OperationId("failed-posting"))
    == Ok(domain.Operation(
      Payment(OperationId("failed-posting"), "alice", "bob", 250),
      domain.Reserved,
    ))
  assert payments.balance(f.deps.connection, "alice") == Ok(#(1000, 250))
  assert payments.balance(f.deps.connection, "bob") == Ok(#(0, 0))
  assert reconciliation.read(f.deps.connection, request.id)
    == Error(reconciliation.MissingDecision)
  assert grind.state(f.jobs, handle) == Ok(job.Uncertain)
  let assert Ok(_) =
    pog.query("ALTER TABLE operations DROP CONSTRAINT refuse_posting")
    |> pog.execute(f.deps.connection)
  let assert Ok(record) =
    reconciliation.reconcile(f.deps, f.jobs, job.id(handle), request)
  assert record.queue_confirmed
  assert payments.balance(f.deps.connection, "alice") == Ok(#(750, 0))
  assert scripted_provider.counts(f.peer.pid) == #(1, 2)
}

pub fn exact_repeat_reuses_a_decision_committed_during_its_lookup_test() {
  use f <- support.with_runtime(
    "finance_reconcile_preflight",
    scripted_provider.LoseReply,
  )
  let handle = held(f, "preflight-race")
  let request = decision("preflight-decision")
  let waiting = process.new_subject()
  let done = process.new_subject()
  scripted_provider.block_next_lookup(f.peer.pid, waiting)
  let _ =
    process.spawn(fn() {
      process.send(
        done,
        reconciliation.reconcile(f.deps, f.jobs, job.id(handle), request),
      )
    })
  let assert Ok(handler) = process.receive(waiting, 1000)
  let assert Ok(record) =
    reconciliation.reconcile(f.deps, f.jobs, job.id(handle), request)
  scripted_provider.release_lookup(handler, 503)
  assert process.receive(done, 3000) == Ok(Ok(record))
  assert payments.balance(f.deps.connection, "alice") == Ok(#(750, 0))
  assert scripted_provider.counts(f.peer.pid) == #(1, 2)
}

pub fn pending_cursor_reaches_work_after_a_missing_queue_history_test() {
  use f <- support.with_runtime(
    "finance_reconcile_paging",
    scripted_provider.LoseReply,
  )
  let first = held(f, "paging-first")
  stop_at(f, first, "a-missing-history", reconciliation.settlement_committed())
  // Existing data may already lack the atomic acknowledgment, or another
  // operator may settle this job under a different attributed decision.
  let assert Ok(_) =
    admin.resolve_uncertain(
      f.jobs,
      first,
      admin.resolution(
        admin.ConfirmSuccess("provider-paging-first"),
        id: "separate-paging-resolution",
        by: "operator-bob",
        details: "Independent settlement",
      ),
    )
  process.sleep(5)
  assert admin.prune_finished(
      f.jobs,
      older_than: duration.milliseconds(1),
      limit: 10,
    )
    == Ok(1)
  let second_payment =
    Payment(OperationId("paging-second"), "alice", "bob", 250)
  let assert Ok(coordinator.Queued(second)) =
    coordinator.admit(f.jobs, coordinator.definition(f.deps), second_payment)
  let assert Ok(grind.Uncertain(_)) =
    grind.await(f.jobs, second, within: duration.seconds(5))
  stop_at(f, second, "b-recoverable", reconciliation.settlement_committed())
  let assert Ok([blocked]) =
    reconciliation.pending(f.deps.connection, 1, after: option.None)
  assert blocked.decision.id == "a-missing-history"
  assert reconciliation.resume(f.deps, f.jobs, blocked.decision.id)
    == Error(reconciliation.JobRead(grind.JobNotFound))
  let assert Ok([recoverable]) =
    reconciliation.pending(
      f.deps.connection,
      1,
      after: option.Some(blocked.decision.id),
    )
  assert recoverable.decision.id == "b-recoverable"
  let assert Ok(record) =
    reconciliation.resume(f.deps, f.jobs, recoverable.decision.id)
  assert record.queue_confirmed
  assert reconciliation.pending(
      f.deps.connection,
      1,
      after: option.Some(record.decision.id),
    )
    == Ok([])
  assert payments.balance(f.deps.connection, "alice") == Ok(#(500, 0))
  assert scripted_provider.counts(f.peer.pid) == #(2, 2)
}

fn stop_at(
  f: support.Fixture,
  handle: job.JobHandle(Payment, String, Nil),
  id: String,
  event: sinal.Event(Nil, String),
) {
  let committed = process.new_subject()
  let observer =
    sinal.observe(event, fn(_, _) {
      process.send(committed, process.self())
      let gate = process.new_subject()
      let assert Ok(Nil) = process.receive(gate, 30_000)
      Nil
    })
  let _ =
    process.spawn_unlinked(fn() {
      let assert Ok(_) =
        reconciliation.reconcile(f.deps, f.jobs, job.id(handle), decision(id))
    })
  let assert Ok(runner) = process.receive(committed, 3000)
  process.kill(runner)
  let assert Ok(Nil) = sinal.detach(observer)
  Nil
}

pub fn a_separate_queue_resolution_does_not_erase_the_pending_application_decision_test() {
  use f <- support.with_runtime(
    "finance_reconcile_other_operator",
    scripted_provider.LoseReply,
  )
  let handle = held(f, "other-operator")
  stop_at(
    f,
    handle,
    "application-decision",
    reconciliation.settlement_committed(),
  )
  let assert Ok(_) =
    admin.resolve_uncertain(
      f.jobs,
      handle,
      admin.resolution(
        admin.ConfirmSuccess("separate-operator-result"),
        id: "separate-decision",
        by: "operator-bob",
        details: "A separate operator resolved delivery before the application acknowledged it",
      ),
    )
  assert reconciliation.resume(f.deps, f.jobs, "application-decision")
    == Error(reconciliation.QueuePending(admin.NotUncertain))
  let assert Ok([record]) =
    reconciliation.pending(f.deps.connection, 10, after: option.None)
  assert record.reference == "provider-other-operator"
  assert !record.queue_confirmed
  assert payments.balance(f.deps.connection, "alice") == Ok(#(750, 0))
  assert grind.outcome(f.jobs, handle)
    == Ok(grind.Succeeded("separate-operator-result"))
  assert scripted_provider.counts(f.peer.pid) == #(1, 1)
}

pub fn stale_reconciler_reads_acknowledgment_after_concurrent_commit_and_pruning_test() {
  use f <- support.with_runtime(
    "finance_reconcile_stale",
    scripted_provider.LoseReply,
  )
  let handle = held(f, "stale-reconciler")
  let request = decision("stale-decision")
  let paused = process.new_subject()
  let done = process.new_subject()
  let observer =
    sinal.observe(reconciliation.settlement_committed(), fn(_, _) {
      let release = process.new_subject()
      process.send(paused, release)
      let assert Ok(Nil) = process.receive(release, 5000)
      Nil
    })
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        done,
        reconciliation.reconcile(f.deps, f.jobs, job.id(handle), request),
      )
    })
  let assert Ok(release) = process.receive(paused, 3000)
  // The paused caller retains queue_confirmed=false in memory. This caller
  // reads its committed decision and completes the combined confirmation.
  let assert Ok(confirmed) =
    reconciliation.reconcile(f.deps, f.jobs, job.id(handle), request)
  assert confirmed.queue_confirmed
  process.sleep(5)
  assert admin.prune_finished(
      f.jobs,
      older_than: duration.milliseconds(1),
      limit: 10,
    )
    == Ok(1)
  assert grind.state(f.jobs, handle) == Error(grind.JobNotFound)
  process.send(release, Nil)
  assert process.receive(done, 3000) == Ok(Ok(confirmed))
  let assert Ok(Nil) = sinal.detach(observer)
  assert reconciliation.pending(f.deps.connection, 10, after: option.None)
    == Ok([])
  assert scripted_provider.counts(f.peer.pid) == #(1, 1)
}
