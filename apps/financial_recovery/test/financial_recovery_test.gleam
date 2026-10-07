import envoy
import financial_recovery/coordinator
import financial_recovery/domain.{type Payment, OperationId, Payment}
import financial_recovery/payments
import financial_recovery/provider
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/option
import gleam/time/duration
import gleeunit
import grind
import grind/admin
import grind/job
import http_gun/error as http_error
import pog
import saga/durable
import saga/execution
import saga/telemetry
import scripted_provider
import sinal
import support

pub fn main() {
  gleeunit.main()
}

fn with_database(schema: String, body: fn(pog.Connection) -> a) -> a {
  let assert Ok(url) = envoy.get("DATABASE_URL")
  let name = process.new_name("financial_database")
  let assert Ok(config) = pog.url_config(name, url)
  let config =
    config |> pog.connection_parameter("search_path", schema <> ",public")
  let assert Ok(started) = pog.start(config)
  let conn = pog.named_connection(name)
  let assert Ok(_) = pog.query("CREATE SCHEMA " <> schema) |> pog.execute(conn)
  let assert Ok(Nil) = payments.migrate(conn)
  let answer = body(conn)
  shutdown(started.pid)
  answer
}

pub fn reservation_is_idempotent_and_refuses_changed_intent_test() {
  use conn <- with_database("finance_reservation")
  let assert Ok(Nil) = payments.account(conn, "alice", 1000)
  let assert Ok(Nil) = payments.account(conn, "bob", 0)
  let payment = Payment(OperationId("business-1"), "alice", "bob", 250)
  let assert Ok(Nil) = pog.transaction(conn, payments.reserve_in(_, payment))
  let assert Ok(Nil) = pog.transaction(conn, payments.reserve_in(_, payment))
  assert payments.balance(conn, "alice") == Ok(#(1000, 250))
  assert payments.read(conn, payment.id)
    == Ok(domain.Operation(payment, domain.Reserved))
  assert pog.transaction(conn, payments.reserve_in(
      _,
      Payment(..payment, cents: 300),
    ))
    == Error(pog.TransactionRolledBack(domain.IdentityConflict))
  assert payments.balance(conn, "alice") == Ok(#(1000, 250))
}

@external(erlang, "financial_fixture", "shutdown")
fn shutdown(pid: process.Pid) -> Nil

pub fn authoritative_evidence_posts_once_and_conflicts_fail_closed_test() {
  use conn <- with_database("finance_evidence")
  let assert Ok(Nil) = payments.account(conn, "alice", 1000)
  let assert Ok(Nil) = payments.account(conn, "bob", 0)
  let payment = Payment(OperationId("business-evidence"), "alice", "bob", 250)
  let assert Ok(Nil) = pog.transaction(conn, payments.reserve_in(_, payment))
  assert payments.post(conn, payment.id) == Error(domain.EvidenceRequired)
  let assert Ok(Nil) = payments.evidence(conn, payment.id, "provider-1")
  let assert Ok(Nil) = payments.evidence(conn, payment.id, "provider-1")
  assert payments.evidence(conn, payment.id, "provider-conflict")
    == Error(domain.EvidenceConflict)
  assert payments.post(conn, payment.id) == Ok("provider-1")
  assert payments.post(conn, payment.id) == Ok("provider-1")
  assert payments.posting(conn, payment.id) == Ok("provider-1")
  assert payments.balance(conn, "alice") == Ok(#(750, 0))
  assert payments.balance(conn, "bob") == Ok(#(250, 0))
  assert payments.read(conn, payment.id)
    == Ok(domain.Operation(payment, domain.Posted("provider-1")))
}

pub fn ordinary_coordinator_posts_a_payment_test() {
  use f <- support.with_runtime("finance_ordinary", scripted_provider.Reply)
  let assert Ok(Nil) = payments.account(f.deps.connection, "alice", 1000)
  let assert Ok(Nil) = payments.account(f.deps.connection, "bob", 0)
  let payment = Payment(OperationId("ordinary"), "alice", "bob", 250)
  let assert Ok(coordinator.Queued(handle)) =
    coordinator.admit(f.jobs, coordinator.definition(f.deps), payment)
  assert grind.await(f.jobs, handle, within: duration.seconds(10))
    == Ok(grind.Succeeded("provider-ordinary"))
  assert payments.balance(f.deps.connection, "alice") == Ok(#(750, 0))
  assert scripted_provider.counts(f.peer.pid) == #(1, 0)
}

fn seed(f: support.Fixture, key: String) -> Payment {
  let assert Ok(Nil) = payments.account(f.deps.connection, "alice", 1000)
  let assert Ok(Nil) = payments.account(f.deps.connection, "bob", 0)
  Payment(OperationId(key), "alice", "bob", 250)
}

fn watch_runner(
  payment: Payment,
  step: String,
) -> #(process.Subject(process.Pid), sinal.Attachment) {
  let runners = process.new_subject()
  let attachment =
    sinal.observe(telemetry.step_started(), fn(_, data) {
      case
        data.execution == option.Some(coordinator.run_id(payment))
        && data.step == step
      {
        True -> process.send(runners, process.self())
        False -> Nil
      }
    })
  #(runners, attachment)
}

pub fn interrupted_transfer_holds_then_authorized_coordinator_resolves_test() {
  use f <- support.with_runtime("finance_recovery", scripted_provider.Hold)
  let payment = seed(f, "recovery")
  scripted_provider.visible(f.peer.pid, False)
  let #(runners, attachment) = watch_runner(payment, "transfer")
  let assert Ok(coordinator.Queued(handle)) =
    coordinator.admit(f.jobs, coordinator.definition(f.deps), payment)
  let assert Ok(runner) = process.receive(runners, 3000)
  let assert Ok("recovery") = process.receive(f.notices, 3000)
  let assert Ok(Nil) = sinal.detach(attachment)
  process.kill(runner)
  let assert Ok(grind.Uncertain(_)) =
    grind.await(f.jobs, handle, within: duration.seconds(5))
  assert payments.balance(f.deps.connection, "alice") == Ok(#(1000, 250))
  assert scripted_provider.counts(f.peer.pid) == #(1, 1)
  let assert Ok(run) = coordinator.start(f.deps, payment)
  let assert Ok(durable.Suspended(durable.RecoveryRequired(_))) =
    durable.read(run)
  let assert Ok([held]) =
    admin.list(f.jobs, admin.query(limit: 10) |> admin.in_state(job.Uncertain))
  assert held.id == job.id(handle)
  scripted_provider.visible(f.peer.pid, True)
  let decision =
    admin.resolution(
      admin.AuthorizeReplay,
      id: "reconcile-1",
      by: "operator-alice",
      details: "Resume coordinator to look up operation recovery; no payment replay authorized",
    )
  let assert Ok(admin.Applied(_)) =
    admin.resolve_uncertain(f.jobs, handle, decision)
  let assert Ok(admin.AlreadyApplied(_)) =
    admin.resolve_uncertain(f.jobs, handle, decision)
  assert grind.await(f.jobs, handle, within: duration.seconds(5))
    == Ok(grind.Succeeded("provider-recovery"))
  assert scripted_provider.counts(f.peer.pid) == #(1, 2)
  assert payments.balance(f.deps.connection, "alice") == Ok(#(750, 0))
  assert payments.evidence(f.deps.connection, payment.id, "provider-recovery")
    == Ok(Nil)
  assert coordinator.admit(f.jobs, coordinator.definition(f.deps), payment)
    == Ok(coordinator.Completed("provider-recovery"))
  assert durable.drive(run, timeout: duration.seconds(2))
    == Ok(execution.Completed("provider-recovery"))
  assert scripted_provider.counts(f.peer.pid) == #(1, 2)
}

pub fn local_post_commits_then_process_dies_before_checkpoint_test() {
  use f <- support.with_runtime("finance_post_gap", scripted_provider.Reply)
  let payment = seed(f, "post-gap")
  let committed = process.new_subject()
  let #(runners, watch) = watch_runner(payment, "post")
  let barrier =
    sinal.observe(coordinator.posting_committed(), fn(_, id) {
      case id == domain.id(payment.id) {
        True -> {
          process.send(committed, Nil)
          let gate = process.new_subject()
          let assert Ok(Nil) = process.receive(gate, 30_000)
          Nil
        }
        False -> Nil
      }
    })
  let assert Ok(coordinator.Queued(handle)) =
    coordinator.admit(f.jobs, coordinator.definition(f.deps), payment)
  let assert Ok(runner) = process.receive(runners, 3000)
  let assert Ok(Nil) = process.receive(committed, 3000)
  // This read is of the application's public financial record, after the
  // commit barrier but while the effect callback is still running.
  assert payments.posting(f.deps.connection, payment.id)
    == Ok("provider-post-gap")
  assert payments.balance(f.deps.connection, "alice") == Ok(#(750, 0))
  process.kill(runner)
  assert grind.await(f.jobs, handle, within: duration.seconds(5))
    == Ok(grind.Succeeded("provider-post-gap"))
  assert process.receive(committed, 0) == Error(Nil)
  assert scripted_provider.counts(f.peer.pid) == #(1, 0)
  let assert Ok(Nil) = sinal.detach(barrier)
  let assert Ok(Nil) = sinal.detach(watch)
}

pub fn transaction_rollback_and_isolation_refusal_leave_no_reservation_test() {
  use f <- support.with_runtime("finance_transaction", scripted_provider.Reply)
  let payment = seed(f, "rolled-back")
  let definition = coordinator.definition(f.deps)
  let assert Error(pog.TransactionRolledBack(handle)) =
    pog.transaction(f.deps.connection, fn(tx) {
      let assert Ok(coordinator.Queued(handle)) =
        coordinator.admit_in(f.jobs, definition, tx, payment)
      Error(handle)
    })
  assert grind.state(f.jobs, handle) == Error(grind.JobNotFound)
  assert payments.read(f.deps.connection, payment.id)
    == Error(domain.OperationMissing)
  assert payments.balance(f.deps.connection, "alice") == Ok(#(1000, 0))
  let assert Error(pog.TransactionRolledBack(coordinator.QueueRejected(grind.TransactionIsolationUnsupported(
    "serializable",
  )))) =
    pog.transaction(f.deps.connection, fn(tx) {
      let assert Ok(_) =
        pog.query("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")
        |> pog.execute(tx)
      let result = coordinator.admit_in(f.jobs, definition, tx, payment)
      let assert Ok(pog.Returned(_, ["serializable"])) =
        pog.query("SHOW transaction_isolation")
        |> pog.returning(decode.at([0], decode.string))
        |> pog.execute(tx)
      result
    })
  assert payments.read(f.deps.connection, payment.id)
    == Error(domain.OperationMissing)
  assert payments.balance(f.deps.connection, "alice") == Ok(#(1000, 0))
  assert scripted_provider.counts(f.peer.pid) == #(0, 0)
}

pub fn completed_business_identity_survives_job_pruning_test() {
  use f <- support.with_runtime("finance_retention", scripted_provider.Reply)
  let payment = seed(f, "retained")
  let definition = coordinator.definition(f.deps)
  let assert Ok(coordinator.Queued(handle)) =
    coordinator.admit(f.jobs, definition, payment)
  let assert Ok(grind.Succeeded("provider-retained")) =
    grind.await(f.jobs, handle, within: duration.seconds(5))
  // This wait advances the deliberately tiny retention age, not a race barrier.
  process.sleep(5)
  assert admin.prune_finished(
      f.jobs,
      older_than: duration.milliseconds(1),
      limit: 10,
    )
    == Ok(1)
  assert grind.state(f.jobs, handle) == Error(grind.JobNotFound)
  assert coordinator.admit(f.jobs, definition, payment)
    == Ok(coordinator.Completed("provider-retained"))
  assert coordinator.admit(f.jobs, definition, Payment(..payment, cents: 251))
    == Error(coordinator.PaymentRejected(domain.IdentityConflict))
  assert payments.balance(f.deps.connection, "alice") == Ok(#(750, 0))
  assert payments.balance(f.deps.connection, "bob") == Ok(#(250, 0))
  assert scripted_provider.counts(f.peer.pid) == #(1, 0)
}

pub fn lost_reply_is_maybe_sent_and_finished_unknown_is_not_suspended_test() {
  use f <- support.with_runtime(
    "finance_lost_reply",
    scripted_provider.LoseReply,
  )
  let payment = seed(f, "lost-reply")
  let assert Error(provider.Transport(failure)) =
    provider.submit(f.deps.provider, payment)
  assert http_error.evidence(failure) == http_error.MaybeSent
  // Independent identity for the coordinator: the first direct exchange
  // established transport evidence, not a Saga execution.
  let payment = Payment(..payment, id: OperationId("finished-unknown"))
  let assert Ok(coordinator.Queued(handle)) =
    coordinator.admit(f.jobs, coordinator.definition(f.deps), payment)
  let assert Ok(grind.Uncertain(_)) =
    grind.await(f.jobs, handle, within: duration.seconds(5))
  let assert Ok(run) = coordinator.start(f.deps, payment)
  let assert Ok(durable.Finished(execution.Unresolved(_, _, _))) =
    durable.read(run)
  let assert Ok(_) =
    admin.resolve_uncertain(
      f.jobs,
      handle,
      admin.resolution(
        admin.AuthorizeReplay,
        id: "inspect-completed",
        by: "operator-alice",
        details: "Demonstrate that delivery authorization cannot turn a finished unresolved Saga into resumable recovery",
      ),
    )
  let assert Ok(grind.Uncertain(_)) =
    grind.await(f.jobs, handle, within: duration.seconds(5))
  assert scripted_provider.counts(f.peer.pid) == #(2, 0)
  assert payments.balance(f.deps.connection, "alice") == Ok(#(1000, 250))
  assert payments.posting(f.deps.connection, payment.id)
    == Error(domain.EvidenceRequired)
}

pub fn cancellation_before_uncertain_ack_retains_financial_hold_test() {
  cancellation_hold("finance_cancel_before", True)
}

pub fn cancellation_after_uncertain_ack_retains_financial_hold_test() {
  cancellation_hold("finance_cancel_after", False)
}

fn cancellation_hold(schema: String, before: Bool) {
  use f <- support.with_runtime(schema, scripted_provider.Hold)
  let payment = seed(f, schema)
  scripted_provider.visible(f.peer.pid, False)
  let gates = process.new_subject()
  let barrier =
    sinal.observe(coordinator.recovery_held(), fn(_, id) {
      case before && id == domain.id(payment.id) {
        True -> {
          let gate = process.new_subject()
          process.send(gates, gate)
          let assert Ok(Nil) = process.receive(gate, 3000)
          Nil
        }
        False -> Nil
      }
    })
  let #(runners, watch) = watch_runner(payment, "transfer")
  let assert Ok(coordinator.Queued(handle)) =
    coordinator.admit(f.jobs, coordinator.definition(f.deps), payment)
  let assert Ok(runner) = process.receive(runners, 3000)
  let assert Ok(_) = process.receive(f.notices, 3000)
  process.kill(runner)
  case before {
    True -> {
      let assert Ok(gate) = process.receive(gates, 2000)
      let assert Ok(_) = grind.cancel(f.jobs, handle)
      process.send(gate, Nil)
    }
    False -> {
      let assert Ok(grind.Uncertain(_)) =
        grind.await(f.jobs, handle, within: duration.seconds(3))
      let assert Ok(_) = grind.cancel(f.jobs, handle)
      Nil
    }
  }
  let assert Ok(grind.Uncertain(evidence)) =
    grind.await(f.jobs, handle, within: duration.seconds(3))
  let assert Ok([held]) =
    admin.list(f.jobs, admin.query(limit: 10) |> admin.in_state(job.Uncertain))
  assert held.id == job.id(handle)
  assert held.description == option.Some(evidence)
  assert admin.resolve_uncertain(
      f.jobs,
      handle,
      admin.resolution(
        admin.AuthorizeReplay,
        id: "blocked-replay",
        by: "operator-alice",
        details: "Cancellation does not authorize another delivery",
      ),
    )
    == Error(admin.CancellationPending)
  assert admin.prune_finished(
      f.jobs,
      older_than: duration.milliseconds(1),
      limit: 10,
    )
    == Ok(0)
  assert payments.balance(f.deps.connection, "alice") == Ok(#(1000, 250))
  assert payments.posting(f.deps.connection, payment.id)
    == Error(domain.EvidenceRequired)
  assert scripted_provider.counts(f.peer.pid) == #(1, 1)
  let assert Ok(Nil) = sinal.detach(barrier)
  let assert Ok(Nil) = sinal.detach(watch)
  Nil
}

pub fn direct_saga_entry_refuses_missing_or_changed_financial_intent_test() {
  use f <- support.with_runtime("finance_entry_guard", scripted_provider.Reply)
  let payment = seed(f, "not-admitted")
  let assert Ok(run) = coordinator.start(f.deps, payment)
  let assert Ok(execution.Failed(
    execution.StepFailed(_, coordinator.RefusedEffect(_)),
    _,
  )) = durable.drive(run, timeout: duration.seconds(2))
  assert scripted_provider.counts(f.peer.pid) == #(0, 0)
  let payment = Payment(..payment, id: OperationId("changed-intent"))
  let assert Ok(Nil) =
    pog.transaction(f.deps.connection, payments.reserve_in(_, payment))
  let assert Ok(run) = coordinator.start(f.deps, Payment(..payment, cents: 251))
  let assert Ok(execution.Failed(
    execution.StepFailed(_, coordinator.RefusedEffect(_)),
    _,
  )) = durable.drive(run, timeout: duration.seconds(2))
  assert scripted_provider.counts(f.peer.pid) == #(0, 0)
  assert payments.balance(f.deps.connection, "alice") == Ok(#(1000, 250))
  let raw = Payment(..payment, id: OperationId("raw-job-without-intent"))
  let assert Ok(admitted) =
    grind.submit(
      f.jobs,
      coordinator.delivery(coordinator.definition(f.deps), raw),
    )
  let assert Ok(grind.Uncertain(_)) =
    grind.await(f.jobs, grind.handle(admitted), within: duration.seconds(2))
  let assert Ok(run) = coordinator.start(f.deps, raw)
  let assert Ok(durable.Finished(execution.Failed(
    execution.StepFailed(_, coordinator.RefusedEffect(_)),
    _,
  ))) = durable.read(run)
  assert scripted_provider.counts(f.peer.pid) == #(0, 0)
}

pub fn direct_saga_entry_reuses_confirmed_and_posted_application_evidence_test() {
  use f <- support.with_runtime("finance_known_entry", scripted_provider.Reply)
  let confirmed = seed(f, "known-confirmed")
  let assert Ok(Nil) =
    pog.transaction(f.deps.connection, payments.reserve_in(_, confirmed))
  let assert Ok(Nil) =
    payments.evidence(f.deps.connection, confirmed.id, "confirmed-by-operator")
  let assert Ok(run) = coordinator.start(f.deps, confirmed)
  assert durable.drive(run, timeout: duration.seconds(2))
    == Ok(execution.Completed("confirmed-by-operator"))
  let posted = Payment(..confirmed, id: OperationId("known-posted"))
  let assert Ok(Nil) =
    pog.transaction(f.deps.connection, payments.reserve_in(_, posted))
  let assert Ok(Nil) =
    payments.evidence(f.deps.connection, posted.id, "posted-by-operator")
  let assert Ok("posted-by-operator") =
    payments.post(f.deps.connection, posted.id)
  let assert Ok(run) = coordinator.start(f.deps, posted)
  assert durable.drive(run, timeout: duration.seconds(2))
    == Ok(execution.Completed("posted-by-operator"))
  assert scripted_provider.counts(f.peer.pid) == #(0, 0)
  assert payments.balance(f.deps.connection, "alice") == Ok(#(500, 0))
  assert payments.balance(f.deps.connection, "bob") == Ok(#(500, 0))
}

pub fn contending_admissions_cannot_over_reserve_the_same_account_test() {
  use f <- support.with_runtime("finance_contention", scripted_provider.Hold)
  let assert Ok(Nil) = payments.account(f.deps.connection, "payer", 500)
  let assert Ok(Nil) = payments.account(f.deps.connection, "payee", 0)
  let winner = Payment(OperationId("first-admission"), "payer", "payee", 400)
  let loser = Payment(..winner, id: OperationId("second-admission"))
  let definition = coordinator.definition(f.deps)
  let ready = process.new_subject()
  let first_result = process.new_subject()
  let _first =
    process.spawn(fn() {
      let outcome =
        pog.transaction(f.deps.connection, fn(tx) {
          let admission = coordinator.admit_in(f.jobs, definition, tx, winner)
          let gate = process.new_subject()
          process.send(ready, gate)
          let assert Ok(Nil) = process.receive(gate, 3000)
          admission
        })
      process.send(first_result, outcome)
    })
  let assert Ok(release) = process.receive(ready, 2000)
  let second_result = process.new_subject()
  let second_entered = process.new_subject()
  let _second =
    process.spawn(fn() {
      let outcome =
        pog.transaction(f.deps.connection, fn(tx) {
          let assert Ok(_) =
            pog.query("SET LOCAL application_name = 'financial_contender'")
            |> pog.execute(tx)
          process.send(second_entered, Nil)
          coordinator.admit_in(f.jobs, definition, tx, loser)
        })
      process.send(second_result, outcome)
    })
  let assert Ok(Nil) = process.receive(second_entered, 2000)
  // Database-reported lock waiting establishes contention before release.
  assert wait_for_contender_lock(f.deps.connection, 100)
  assert process.receive(second_result, 0) == Error(Nil)
  process.send(release, Nil)
  let assert Ok(Ok(coordinator.Queued(handle))) =
    process.receive(first_result, 2000)
  assert process.receive(second_result, 2000)
    == Ok(
      Error(
        pog.TransactionRolledBack(coordinator.PaymentRejected(
          domain.InsufficientFunds,
        )),
      ),
    )
  let assert Ok("first-admission") = process.receive(f.notices, 2000)
  assert payments.balance(f.deps.connection, "payer") == Ok(#(500, 400))
  assert payments.read(f.deps.connection, loser.id)
    == Error(domain.OperationMissing)
  let assert Ok([only_job]) = admin.list(f.jobs, admin.query(limit: 10))
  assert only_job.id == job.id(handle)
  assert scripted_provider.counts(f.peer.pid) == #(1, 0)
}

fn wait_for_contender_lock(connection: pog.Connection, remaining: Int) -> Bool {
  let assert Ok(pog.Returned(_, [waiting])) =
    pog.query(
      "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name = 'financial_contender' AND wait_event_type = 'Lock')",
    )
    |> pog.returning(decode.at([0], decode.bool))
    |> pog.execute(connection)
  case waiting, remaining > 0 {
    True, _ -> True
    False, False -> False
    False, True -> {
      process.sleep(5)
      wait_for_contender_lock(connection, remaining - 1)
    }
  }
}

pub fn business_identity_is_encoded_as_one_provider_lookup_segment_test() {
  use f <- support.with_runtime(
    "finance_identity_path",
    scripted_provider.Reply,
  )
  let payment =
    Payment(OperationId("invoice/204?percent%"), "payer", "payee", 250)
  assert provider.submit(f.deps.provider, payment)
    == Ok("provider-invoice/204?percent%")
  assert provider.lookup(f.deps.provider, payment.id)
    == Ok("provider-invoice/204?percent%")
  assert scripted_provider.counts(f.peer.pid) == #(1, 1)
}
