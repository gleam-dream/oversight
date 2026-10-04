//// End-to-end tests. They need PostgreSQL: run them with
//// `../scripts/with-postgres.sh gleam test`.

import checkout
import checkout/app.{type App}
import checkout/codecs
import checkout/db
import checkout/domain.{OrderRequest, ProviderUnreachable}
import checkout/gateway
import checkout/jobs
import checkout/orders
import checkout/providers
import checkout/telemetry
import checkout/web
import envoy
import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import gleeunit
import grind
import http_gun
import http_gun/destination
import http_gun/error
import pog
import saga
import saga/execution
import saga/storage/conformance
import saga/telemetry as saga_telemetry
import saga_postgres
import sinal

pub fn main() -> Nil {
  gleeunit.main()
}

fn with_app(config: fn(app.Config) -> app.Config, run: fn(App) -> a) -> a {
  let assert Ok(url) = envoy.get("DATABASE_URL")
    as "set DATABASE_URL: ../scripts/with-postgres.sh gleam test"
  let assert Ok(application) = app.start(config(app.default_config(url)))
  let result = run(application)
  app.stop(application)
  result
}

fn order(id: String, sku: String, card: String, address: String) {
  OrderRequest(id, sku, 1, card, 2500, address, id <> "@example.test")
}

fn eventually(check: fn() -> Bool, tries: Int) -> Bool {
  case check() {
    True -> True
    False if tries > 0 -> {
      process.sleep(50)
      eventually(check, tries - 1)
    }
    False -> False
  }
}

fn stock(application: App, sku: String) -> Int {
  let assert Ok(level) = db.stock_level(application.services.pool, sku)
  level
}

fn timed_out_after_send() -> error.Failure {
  error.new(error.DeadlineExceeded, error.MaybeSent)
}

// --- common path ------------------------------------------------------------

pub fn order_api_confirms_and_sends_receipt_test() {
  use application <- with_app(fn(c) { c })
  let pool = application.services.pool
  let assert Ok(Nil) = db.set_stock(pool, "happy-sku", 3)
  let assert Ok(#(_, port)) = web.start(application)
  let assert Ok(customer) = http_gun.start(gateway.customer_config())

  let placed = order("happy-1", "happy-sku", providers.card_ok, "10 Main St")
  let assert Ok(req) =
    request.to("http://127.0.0.1:" <> int.to_string(port) <> "/orders")
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(bit_array.from_string(checkout.orders_body(placed)))
  let assert Ok(reply) = http_gun.send(customer, req)
  http_gun.stop(customer)

  assert reply.response.status == 201
  assert stock(application, "happy-sku") == 2
  let assert Some(charge) =
    providers.charge_for(application.providers, "pay-happy-1")
  assert charge.status == providers.Captured
  let assert Some(_) =
    providers.shipment_for(application.providers, "ship-happy-1")
  let assert Some(#(domain.Confirmed, _)) = db.order_status(pool, "happy-1")
  // The receipt job committed with the confirmation and ran.
  assert eventually(fn() { db.receipt_sent(pool, "happy-1") }, 100)

  // One order can be followed across saga, http_gun and grind, each by the
  // correlation it carries in its own metadata.
  let trace =
    telemetry.trace(application.services.collector, telemetry.order("happy-1"))
  let sources = list.map(trace, fn(e) { e.source }) |> list.unique
  assert list.contains(sources, telemetry.Saga)
  assert list.contains(sources, telemetry.Http)
  assert list.contains(sources, telemetry.Grind)
  assert telemetry.unattributed(application.services.collector) == []
}

// --- failure paths ------------------------------------------------------------

pub fn payment_declined_releases_stock_test() {
  use application <- with_app(fn(c) { c })
  let assert Ok(Nil) = db.set_stock(application.services.pool, "decline-sku", 3)
  let report =
    orders.place_local(
      application.services,
      order("decline-1", "decline-sku", providers.card_declined, "10 Main St"),
    )
  assert report.status == domain.Rejected
  assert report.error == Ok(domain.Declined("insufficient_funds"))
  assert web.status_code(report) == 402
  assert report.undone == ["reserve_stock"]
  assert stock(application, "decline-sku") == 3
  assert providers.shipment_for(application.providers, "ship-decline-1") == None
}

pub fn shipment_timeout_after_charge_voids_the_charge_test() {
  use application <- with_app(fn(c) { c })
  let assert Ok(Nil) = db.set_stock(application.services.pool, "slow-sku", 3)
  let report =
    orders.place_local(
      application.services,
      order("slow-1", "slow-sku", providers.card_ok, providers.address_slow),
    )
  // The step error carries http_gun's typed failure and evidence.
  assert report.error
    == Ok(ProviderUnreachable(domain.Shipping, timed_out_after_send()))
  assert web.status_code(report) == 504
  assert report.undone == ["charge_card", "reserve_stock"]
  let assert Some(charge) =
    providers.charge_for(application.providers, "pay-slow-1")
  assert charge.status == providers.Voided
  // The shipment may have been booked; the step's own cleanup cancelled it.
  let assert Some(shipment) =
    providers.shipment_for(application.providers, "ship-slow-1")
  assert shipment.status == providers.Cancelled
  assert stock(application, "slow-sku") == 3
  // Saga names the shipment attempt whose effect was unknown when it ended.
  assert report.unknown_effects == 1
}

pub fn unknown_payment_outcome_is_reported_by_saga_test() {
  use application <- with_app(fn(c) { c })
  let services = application.services
  let assert Ok(Nil) = db.set_stock(services.pool, "unknown-sku", 5)

  // First answer lost (MaybeSent), retried under the same provider
  // idempotency key: one charge, two requests, and saga reports that
  // attempt 1's effect was unknown when it ended.
  let lost =
    order("lost-1", "unknown-sku", providers.card_first_answer_lost, "1 St")
  let assert Ok(execution.CompletedWithUnknownEffects(booked, [unknown])) =
    execution.run(services.workflow, lost, services.saga_config)
  assert booked.charged.charge_id != ""
  assert saga.address_to_string(unknown.step) == "charge_card"
  assert unknown.action == execution.StepAttempt(1)
  assert unknown.ending == execution.ActionReturnedUnknown
  let snapshot = providers.snapshot(application.providers)
  assert snapshot.charge_requests == 2
  assert list.count(snapshot.charges, fn(c) { c.key == "pay-lost-1" }) == 1

  // Every answer lost: the decider holds. The outcome is Unresolved with the
  // typed http_gun evidence, stock stays reserved, nothing is voided, and
  // both attempts are named as unknown effects.
  let hole = order("hole-1", "unknown-sku", providers.card_black_hole, "1 St")
  let assert Ok(execution.Unresolved(step, evidence, settlement)) =
    execution.run(services.workflow, hole, services.saga_config)
  assert saga.address_to_string(step) == "charge_card"
  assert evidence
    == ProviderUnreachable(domain.Payments, timed_out_after_send())
  assert list.map(settlement.unknown_effects, fn(u) { #(u.action, u.ending) })
    == [
      #(execution.StepAttempt(1), execution.ActionReturnedUnknown),
      #(execution.StepAttempt(2), execution.ActionReturnedUnknown),
    ]
  assert stock(application, "unknown-sku") == 3
  let assert Some(charge) =
    providers.charge_for(application.providers, "pay-hole-1")
  assert charge.status == providers.Captured
}

/// `unknown_when` reports the unknown payment without a crash, so the
/// failure stays typed. With no decider the run holds: it ends `Unresolved`
/// and undoes nothing. `on_unknown(RollBack)` opts into the earlier ending,
/// `Failed` with the completed steps undone.
pub fn unknown_payment_keeps_the_typed_failure_test() {
  use application <- with_app(fn(c) { c })
  let services = application.services
  let charge_only = fn(name, unknown_policy) {
    saga.define(name, fn(input) {
      input
      |> saga.perform(
        saga.step("charge_card", fn(order: domain.OrderRequest) {
          gateway.charge(
            services.gateway,
            services.gateway.client,
            order,
            "pay-" <> order.order_id,
          )
        })
        |> saga.unknown_when(domain.effect_uncertain)
        |> unknown_policy,
      )
    })
  }
  let hole = order("typed-pay-1", "none", providers.card_black_hole, "1 St")
  let unknown_attempt = [
    #(execution.StepAttempt(1), execution.ActionReturnedUnknown),
  ]

  let held = charge_only("charge-only-hold", fn(step) { step })
  let assert Ok(execution.Unresolved(_, evidence, settlement)) =
    execution.run(held, hole, services.saga_config)
  assert evidence
    == ProviderUnreachable(domain.Payments, timed_out_after_send())
  assert list.map(settlement.unknown_effects, fn(u) { #(u.action, u.ending) })
    == unknown_attempt

  let rolled_back =
    charge_only("charge-only-roll-back", saga.on_unknown(_, saga.RollBack))
  let assert Ok(execution.Failed(execution.StepFailed(_, cause), settlement)) =
    execution.run(rolled_back, hole, services.saga_config)
  assert cause == ProviderUnreachable(domain.Payments, timed_out_after_send())
  assert list.map(settlement.unknown_effects, fn(u) { #(u.action, u.ending) })
    == unknown_attempt
}

/// A durable step error carries http_gun's `Failure`; it round-trips
/// through `error.to_json` and `error.decoder` inside the app's codec.
pub fn checkout_error_codec_round_trips_http_failures_test() {
  let c = codecs.checkout_error()
  let failures = [
    timed_out_after_send(),
    error.new(error.ConnectionFailed(error.ConnectionRefused), error.NotSent),
    error.new(
      error.LimitExceeded(error.ResponseBodyBytes, 10, 11),
      error.MaybeSent,
    )
      |> error.with_status(200),
    error.new(
      error.DestinationRejected(destination.HostNotAllowed),
      error.NotSent,
    ),
  ]
  list.each(failures, fn(failure) {
    let value = ProviderUnreachable(domain.Shipping, failure)
    let text = json.to_string(c.encode(value))
    assert json.parse(text, c.decoder) == Ok(value)
  })
}

/// The payment client is loopback only and pinned to the providers'
/// `host:port`: a public host and another local port are refused before
/// anything is sent.
pub fn payment_client_refuses_public_and_unpinned_hosts_test() {
  use application <- with_app(fn(c) { c })
  let refused = fn(url) {
    let assert Ok(req) = request.to(url)
    let assert Error(failure) =
      http_gun.send(application.http, request.set_body(req, <<>>))
    #(error.kind(failure), error.evidence(failure))
  }
  assert refused("http://93.184.215.14/") == #(error.Refused, error.NotSent)
  assert refused("http://example.com/") == #(error.Refused, error.NotSent)
  assert refused("http://127.0.0.1:1/") == #(error.Refused, error.NotSent)
}

// --- advanced: durable saga driven by grind ----------------------------------

/// The pid of the saga runner that starts `step` of `execution`: saga
/// emits its events synchronously from the runner.
fn watch_runner(
  execution: String,
  step: String,
) -> #(process.Subject(process.Pid), sinal.Attachment) {
  let runners = process.new_subject()
  let attachment =
    sinal.observe(saga_telemetry.step_started(), fn(_m, d) {
      case d.execution == Some(execution) && d.step == step {
        True -> process.send(runners, process.self())
        False -> Nil
      }
    })
  #(runners, attachment)
}

fn await_job(application: App, job_id: Int) -> grind.Outcome(String, Nil) {
  let jobs = application.services.jobs
  let assert Ok(handle) = grind.bind(jobs, application.checkout_worker, job_id)
  let assert Ok(outcome) =
    grind.await(jobs, handle, within: duration.seconds(30))
  outcome
}

pub fn durable_checkout_survives_a_killed_runner_test() {
  // A long shipping budget keeps the shipment call in flight while we kill
  // the saga runner. The saga lease keeps its 30 s default: the killed
  // runner releases its claim, so the redelivery does not wait for it.
  use application <- with_app(fn(c) {
    app.Config(..c, shipping_deadline: duration.seconds(5))
  })
  let services = application.services
  let assert Ok(Nil) = db.set_stock(services.pool, "durable-sku", 2)
  let placed =
    order("durable-1", "durable-sku", providers.card_ok, providers.address_hold)
  let #(runners, attachment) =
    watch_runner(jobs.execution_id(placed), "book_shipment")
  let arrivals = process.new_subject()
  providers.watch_shipments(application.providers, arrivals)
  let assert Ok(job_id) =
    orders.place_durable(services, application.checkout_worker, placed)

  // The shipment request reached the provider (which books it, then holds
  // the answer). Kill the runner that owns the saga execution right now.
  let assert Ok(runner) = process.receive(runners, 10_000)
  let assert Ok("ship-durable-1") = process.receive(arrivals, 10_000)
  let _ = sinal.detach(attachment)
  process.kill(runner)

  // The grind attempt sees `RunnerLost` and snoozes for the redelivery
  // delay; the redelivered job claims the released execution at once and
  // resumes from the checkpoint: reserve and charge are reused, and the
  // interrupted shipment is reconciled by lookup, not booked again. It does
  // not wait out the 30 s lease.
  let started = timestamp.system_time()
  let assert grind.Succeeded(summary) = await_job(application, job_id)
  assert summary != ""
  assert duration.to_milliseconds(timestamp.difference(
      started,
      timestamp.system_time(),
    ))
    < 10_000
  let assert Some(#(domain.Confirmed, _)) =
    db.order_status(services.pool, "durable-1")
  let snapshot = providers.snapshot(application.providers)
  assert snapshot.charge_requests == 1
  assert snapshot.shipment_requests == 1
  assert stock(application, "durable-sku") == 1
  assert eventually(fn() { db.receipt_sent(services.pool, "durable-1") }, 100)

  // Two saga runs (before and after the kill), both carrying the order's
  // correlation, and so do the provider calls the steps made in each: the
  // saved correlation is read back by the redelivered drive, and no event of
  // either drive is unattributed.
  let trace = telemetry.trace(services.collector, telemetry.order("durable-1"))
  let runs =
    list.count(trace, fn(e) {
      e.source == telemetry.Saga && e.line == "run start checkout"
    })
  assert runs == 2
  assert list.any(trace, fn(e) { e.source == telemetry.Http })
  assert telemetry.unattributed(services.collector) == []
}

/// A whole-worker crash: the grind handler process dies. Its saga runner
/// stops with it, and the abandoned attempt is replayed after its lease
/// expires (`ReplayAfterLeaseExpiry`), so the saga resumes from its
/// checkpoint without an operator.
pub fn durable_checkout_after_job_crash_replays_without_an_operator_test() {
  use application <- with_app(fn(c) {
    app.Config(..c, shipping_deadline: duration.seconds(5))
  })
  let services = application.services
  let assert Ok(Nil) = db.set_stock(services.pool, "crash-sku", 2)
  let placed =
    order("crash-1", "crash-sku", providers.card_ok, providers.address_hold)
  let #(runners, attachment) =
    watch_runner(jobs.execution_id(placed), "book_shipment")
  let arrivals = process.new_subject()
  providers.watch_shipments(application.providers, arrivals)
  let assert Ok(job_id) =
    orders.place_durable(services, application.checkout_worker, placed)
  let assert Ok(runner) = process.receive(runners, 10_000)
  let assert Ok("ship-crash-1") = process.receive(arrivals, 10_000)
  let _ = sinal.detach(attachment)
  // The runner's caller is the handler's drive process, linked to the
  // handler.
  let assert Ok(driver) = parent(runner)
  let assert Ok(handler) = parent(driver)

  // Killing the handler stops the saga runner too: `drive` no longer
  // leaves a detached runner advancing the saga.
  process.kill(handler)
  assert eventually(fn() { !process.is_alive(runner) }, 20)

  let assert grind.Succeeded(_) = await_job(application, job_id)
  let assert Some(#(domain.Confirmed, _)) =
    db.order_status(services.pool, "crash-1")
  let snapshot = providers.snapshot(application.providers)
  assert snapshot.charge_requests == 1
  assert snapshot.shipment_requests == 1
  // Grind quarantined the abandoned attempt as a replay and claimed the job
  // again under the order's correlation. A replay does not use up a business
  // attempt, so both claims are attempt 1, and no operator resolution was
  // needed.
  let grind_lines =
    telemetry.trace(services.collector, telemetry.order("crash-1"))
    |> list.filter(fn(e) { e.source == telemetry.Grind })
    |> list.map(fn(e) { e.line })
  let job = " checkout.run#" <> int.to_string(job_id) <> " queue=checkouts"
  assert list.count(grind_lines, fn(line) {
      line == "job claimed attempt=1" <> job
    })
    == 2
  assert list.contains(grind_lines, "job quarantined replayed=True" <> job)
  assert !list.any(grind_lines, string.starts_with(_, "job claimed attempt=2"))
  assert !list.any(grind_lines, string.starts_with(_, "job resolved"))
  // The replayed drive's saga and provider events stay under the same order.
  let trace = telemetry.trace(services.collector, telemetry.order("crash-1"))
  assert list.count(trace, fn(e) {
      e.source == telemetry.Saga && e.line == "run start checkout"
    })
    == 2
  assert list.any(trace, fn(e) { e.source == telemetry.Http })
  assert telemetry.unattributed(services.collector) == []
}

/// `grind.cancel` of a running durable checkout reaches the handler through
/// `worker.cancellation`; the handler records it with `durable.cancel`, and
/// the saga rolls back from its next checkpoint.
pub fn durable_checkout_cancelled_through_grind_rolls_back_test() {
  use application <- with_app(fn(c) {
    app.Config(..c, shipping_deadline: duration.seconds(5))
  })
  let services = application.services
  let assert Ok(Nil) = db.set_stock(services.pool, "cancel-sku", 2)
  let arrivals = process.new_subject()
  providers.watch_shipments(application.providers, arrivals)
  let placed =
    order("cancel-1", "cancel-sku", providers.card_ok, providers.address_hold)
  let assert Ok(job_id) =
    orders.place_durable(services, application.checkout_worker, placed)
  let assert Ok("ship-cancel-1") = process.receive(arrivals, 10_000)
  let jobs = services.jobs
  let assert Ok(handle) = grind.bind(jobs, application.checkout_worker, job_id)
  let assert Ok(grind.CancellationRequested) = grind.cancel(jobs, handle)

  let assert grind.Cancelled(_) = await_job(application, job_id)
  let assert Some(#(domain.Rejected, "cancelled: CancelRequested")) =
    db.order_status(services.pool, "cancel-1")
  // Every effect is reversed, including the shipment the provider booked
  // while the cancellation was pending.
  let assert Some(charge) =
    providers.charge_for(application.providers, "pay-cancel-1")
  assert charge.status == providers.Voided
  let assert Some(shipment) =
    providers.shipment_for(application.providers, "ship-cancel-1")
  assert shipment.status == providers.Cancelled
  assert stock(application, "cancel-sku") == 2
}

@external(erlang, "checkout_test_ffi", "parent")
fn parent(pid: process.Pid) -> Result(process.Pid, Nil)

/// saga_postgres passes saga's conformance suite on the app's own pool,
/// which grind built and also uses.
pub fn saga_postgres_on_the_shared_pool_passes_conformance_test() {
  use application <- with_app(fn(c) { c })
  let lease = duration.milliseconds(300)
  let storage =
    saga_postgres.config(application.services.pool)
    |> saga_postgres.with_lease(lease)
    |> saga_postgres.storage
  let fresh = fn() { Ok(conformance.fixture(storage, cleanup: fn() { Nil })) }
  assert conformance.run(
      fresh,
      timeout: duration.seconds(10),
      owner_loss_within: duration.add(lease, duration.milliseconds(500)),
    )
    == Ok(Nil)
}

/// The receipt job is admitted inside the order's confirmation
/// transaction: a rolled-back confirmation leaves no job, and a committed
/// one leaves exactly one, whatever the number of resubmissions.
pub fn receipt_job_commits_with_the_order_test() {
  use application <- with_app(fn(c) { c })
  let services = application.services
  let pool = services.pool
  let placed = order("receipt-1", "receipt-sku", providers.card_ok, "1 St")
  let assert Ok(Nil) = db.insert_order(pool, "receipt-1")

  // Rolled back: neither the status nor the job exists afterwards.
  let assert Error(pog.TransactionRolledBack(handle)) =
    pog.transaction(pool, fn(tx) {
      let assert Ok(Nil) =
        db.set_status(tx, "receipt-1", domain.Confirmed, "rolled back")
      let assert Ok(grind.Inserted(handle)) =
        grind.submit_in(services.jobs, tx, orders.receipt_job(services, placed))
      Error(handle)
    })
  assert grind.state(services.jobs, handle) == Error(grind.JobNotFound)
  let assert Some(#(domain.Pending, _)) = db.order_status(pool, "receipt-1")

  // Committed: the job runs; a resubmission under the same id converges.
  let assert Ok(first) =
    orders.confirm_with_receipt(services, placed, "committed")
  let assert Ok(again) =
    orders.confirm_with_receipt(services, placed, "committed")
  assert again == first
  let assert Ok(handle) =
    grind.bind(services.jobs, services.receipt_worker, first)
  let assert Ok(grind.Succeeded(message_id)) =
    grind.await(services.jobs, handle, within: duration.seconds(10))
  assert message_id == "msg-receipt-1-2500"
  assert db.receipt_sent(pool, "receipt-1")
}
