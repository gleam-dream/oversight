//// End-to-end tests. They need PostgreSQL: run them with
//// `../scripts/with-postgres.sh gleam test`.

import checkout
import checkout/app.{type App}
import checkout/codecs
import checkout/customers
import checkout/db
import checkout/domain.{ProviderUnreachable}
import checkout/gateway
import checkout/jobs
import checkout/orders
import checkout/providers
import checkout/telemetry
import checkout/web
import envoy
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
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

/// The demo identities: each bearer token resolves to one customer.
const alice_token = "alice-test-token-6b1f0e2c"

const bob_token = "bob-test-token-93d4a7e1"

fn with_app(config: fn(app.Config) -> app.Config, run: fn(App) -> a) -> a {
  let assert Ok(url) = envoy.get("DATABASE_URL")
    as "set DATABASE_URL: ../scripts/with-postgres.sh gleam test"
  let base =
    app.Config(
      ..app.default_config(url),
      customers: customers.from_list([
        #(alice_token, "alice"),
        #(bob_token, "bob"),
      ]),
    )
  let assert Ok(application) = app.start(config(base))
  let result = run(application)
  app.stop(application)
  result
}

/// A priced order for one unit at 2500 cents, paid with the provider's
/// token for `card`, for tests that drive the saga or `orders` directly.
fn order(
  application: App,
  id: String,
  sku: String,
  card: String,
  address: String,
) -> domain.Order {
  let token = providers.tokenise(application.providers, card)
  domain.Order(id, "alice", sku, 1, 2500, token, address, id <> "@example.test")
}

/// Lists `sku` at 2500 cents with `available` units.
fn set_stock(
  pool: pog.Connection,
  sku: String,
  available: Int,
) -> Result(Nil, pog.QueryError) {
  db.set_product(pool, sku, unit_price_cents: 2500, available:)
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
  let assert Ok(Nil) = set_stock(pool, "happy-sku", 3)
  let assert Ok(#(_, port)) = web.start(application)
  let assert Ok(customer) = http_gun.start(gateway.customer_config())

  let placed =
    order(application, "happy-1", "happy-sku", providers.card_ok, "10 Main St")
  let request =
    domain.CheckoutRequest(
      placed.order_id,
      placed.sku,
      placed.quantity,
      placed.payment_token,
      placed.address,
      placed.email,
    )
  let assert Ok(req) =
    request.to("http://127.0.0.1:" <> int.to_string(port) <> "/orders")
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("authorization", "Bearer " <> alice_token)
    |> request.set_body(bit_array.from_string(checkout.orders_body(request)))
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
  let assert Ok(Nil) = set_stock(application.services.pool, "decline-sku", 3)
  let assert Ok(orders.Started(report)) =
    orders.place_local(
      application.services,
      order(
        application,
        "decline-1",
        "decline-sku",
        providers.card_declined,
        "10 Main St",
      ),
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
  let assert Ok(Nil) = set_stock(application.services.pool, "slow-sku", 3)
  let assert Ok(orders.Started(report)) =
    orders.place_local(
      application.services,
      order(
        application,
        "slow-1",
        "slow-sku",
        providers.card_ok,
        providers.address_slow,
      ),
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
  let assert Ok(Nil) = set_stock(services.pool, "unknown-sku", 5)

  // First answer lost (MaybeSent), retried under the same provider
  // idempotency key: one charge, two requests, and saga reports that
  // attempt 1's effect was unknown when it ended.
  let lost =
    order(
      application,
      "lost-1",
      "unknown-sku",
      providers.card_first_answer_lost,
      "1 St",
    )
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
  let hole =
    order(
      application,
      "hole-1",
      "unknown-sku",
      providers.card_black_hole,
      "1 St",
    )
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
        saga.step("charge_card", fn(order: domain.Order) {
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
  let hole =
    order(application, "typed-pay-1", "none", providers.card_black_hole, "1 St")
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
  let assert Ok(Nil) = set_stock(services.pool, "durable-sku", 2)
  let placed =
    order(
      application,
      "durable-1",
      "durable-sku",
      providers.card_ok,
      providers.address_hold,
    )
  let #(runners, attachment) =
    watch_runner(jobs.execution_id(placed), "book_shipment")
  let arrivals = process.new_subject()
  providers.watch_shipments(application.providers, arrivals)
  let assert Ok(orders.Started(job_id)) =
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
  let assert Ok(Nil) = set_stock(services.pool, "crash-sku", 2)
  let placed =
    order(
      application,
      "crash-1",
      "crash-sku",
      providers.card_ok,
      providers.address_hold,
    )
  let #(runners, attachment) =
    watch_runner(jobs.execution_id(placed), "book_shipment")
  let arrivals = process.new_subject()
  providers.watch_shipments(application.providers, arrivals)
  let assert Ok(orders.Started(job_id)) =
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
  let assert Ok(Nil) = set_stock(services.pool, "cancel-sku", 2)
  let arrivals = process.new_subject()
  providers.watch_shipments(application.providers, arrivals)
  let placed =
    order(
      application,
      "cancel-1",
      "cancel-sku",
      providers.card_ok,
      providers.address_hold,
    )
  let assert Ok(orders.Started(job_id)) =
    orders.place_durable(services, application.checkout_worker, placed)
  let assert Ok("ship-cancel-1") = process.receive(arrivals, 10_000)
  let jobs = services.jobs
  let assert Ok(handle) = grind.bind(jobs, application.checkout_worker, job_id)
  let assert Ok(grind.CancellationRequested) = grind.cancel(jobs, handle)

  let assert grind.Cancelled(_) = await_job(application, job_id)
  let assert Some(#(domain.Rejected, "cancelled: requested")) =
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
  let placed =
    order(application, "receipt-1", "receipt-sku", providers.card_ok, "1 St")
  let assert Ok(db.Inserted) = db.insert_order(pool, placed)

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

// --- scripted provider request bodies ------------------------------------------

@external(erlang, "checkout_test_ffi", "raw_http")
fn raw_http(port: Int, request: BitArray, timeout_ms: Int) -> Result(Int, Nil)

fn provider_port(url: String) -> Int {
  let assert [_, port] = string.split(gateway.authority(url), ":")
  let assert Ok(port) = int.parse(port)
  port
}

/// The scripted payments server reads at most 64 KiB of a request body. A
/// chunked body is refused before any of it is read (mist would otherwise
/// buffer it whole), as is a missing or over-limit `content-length`.
pub fn provider_refuses_unbounded_request_bodies_test() {
  use application <- with_app(fn(c) { c })
  let port = provider_port(providers.payments_url(application.providers))
  let head = "POST /charges HTTP/1.1\r\nhost: 127.0.0.1\r\n"
  let big = string.repeat("x", 70_000)
  let chunked =
    head
    <> "content-type: application/json\r\ntransfer-encoding: chunked\r\n\r\n"
    <> int.to_base16(string.length(big))
    <> "\r\n"
    <> big
    <> "\r\n0\r\n\r\n"
  assert raw_http(port, bit_array.from_string(chunked), 5000) == Ok(411)
  let unframed = head <> "content-type: application/json\r\n\r\n"
  assert raw_http(port, bit_array.from_string(unframed), 5000) == Ok(411)
  let oversized =
    head
    <> "content-type: application/json\r\ncontent-length: 70000\r\n\r\n"
    <> big
  assert raw_http(port, bit_array.from_string(oversized), 5000) == Ok(413)
  // Nothing reached the provider's state.
  assert providers.snapshot(application.providers).charge_requests == 0
}

// --- error bodies ----------------------------------------------------------------

fn post_order(port: Int, body: String, query: String) -> #(Int, String) {
  call_api(port, http.Post, "/orders" <> query, Some(alice_token), body)
}

/// One API call as the customer `token` authenticates, or anonymously.
fn call_api(
  port: Int,
  method: http.Method,
  path: String,
  token: option.Option(String),
  body: String,
) -> #(Int, String) {
  let assert Ok(customer) = http_gun.start(gateway.customer_config())
  let assert Ok(req) =
    request.to("http://127.0.0.1:" <> int.to_string(port) <> path)
  let req =
    req
    |> request.set_method(method)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(bit_array.from_string(body))
  let req = case token {
    Some(token) -> request.set_header(req, "authorization", "Bearer " <> token)
    None -> req
  }
  let assert Ok(reply) = http_gun.send(customer, req)
  http_gun.stop(customer)
  let assert Ok(text) = bit_array.to_string(reply.response.body)
  #(reply.response.status, text)
}

/// An internal failure answers with a stable error code and message; the
/// driver's error term goes to the log, not to the client.
pub fn internal_errors_stay_out_of_response_bodies_test() {
  use application <- with_app(fn(c) { c })
  let pool = application.services.pool
  let assert Ok(Nil) = set_stock(pool, "broken-sku", 3)
  let assert Ok(#(_, port)) = web.start(application)
  let rename = fn(from, to) {
    let assert Ok(_) =
      pog.query("ALTER TABLE " <> from <> " RENAME TO " <> to)
      |> pog.execute(pool)
    Nil
  }
  rename("reservations", "reservations_hidden")
  let token = providers.tokenise(application.providers, providers.card_ok)
  let #(status, body) =
    post_order(port, body(order_fields("broken-1", "broken-sku", 1, token)), "")
  rename("reservations_hidden", "reservations")

  assert status == 503
  list.each(["Postgresql", "QueryError", "reservations", "42P01"], fn(term) {
    assert !string.contains(body, term)
  })
  let assert Ok("store_unavailable") =
    json.parse(body, decode.at(["error"], decode.string))
  // The stored order detail is the same stable text.
  let assert Some(#(domain.Rejected, detail)) =
    db.order_status(pool, "broken-1")
  assert !string.contains(detail, "Postgresql")
}

// --- wisp secret key base ----------------------------------------------------------

/// The signing secret comes from `CHECKOUT_SECRET_KEY_BASE`; one shorter
/// than wisp's 64-character minimum stops startup, and an unset variable
/// falls back to a random per-boot secret.
pub fn secret_key_base_comes_from_the_environment_test() {
  use application <- with_app(fn(c) { c })
  let variable = "CHECKOUT_SECRET_KEY_BASE"
  envoy.set(variable, "too-short")
  let short = web.start(application)
  envoy.set(variable, string.repeat("k", 64))
  let configured = web.start(application)
  envoy.unset(variable)
  let generated = web.start(application)
  assert result.is_error(short)
  assert result.is_ok(configured)
  assert result.is_ok(generated)
}

// --- pricing and payment tokens ------------------------------------------------------

/// A customer tokenises the card with the payment provider directly, as a
/// browser would; the order API only ever sees the token.
fn tokenise(application: App, card: String) -> Result(String, Nil) {
  let assert Ok(customer) = http_gun.start(gateway.customer_config())
  let tokenised =
    checkout.tokenise(
      customer,
      providers.payments_url(application.providers),
      card,
    )
  http_gun.stop(customer)
  tokenised
}

fn body(fields: List(#(String, json.Json))) -> String {
  json.to_string(json.object(fields))
}

fn order_fields(
  id: String,
  sku: String,
  quantity: Int,
  token: String,
) -> List(#(String, json.Json)) {
  [
    #("order_id", json.string(id)),
    #("sku", json.string(sku)),
    #("quantity", json.int(quantity)),
    #("payment_token", json.string(token)),
    #("address", json.string("10 Main St")),
    #("email", json.string(id <> "@example.test")),
  ]
}

fn error_code(text: String) -> Result(String, json.DecodeError) {
  json.parse(text, decode.at(["error"], decode.string))
}

/// The server prices the order from its catalog: the charge is the SKU's
/// unit price times the quantity.
pub fn server_prices_the_order_from_the_catalog_test() {
  use application <- with_app(fn(c) { c })
  let pool = application.services.pool
  let assert Ok(Nil) =
    db.set_product(pool, "priced-sku", unit_price_cents: 1250, available: 5)
  let assert Ok(#(_, port)) = web.start(application)
  let assert Ok(token) = tokenise(application, providers.card_ok)

  let #(status, _) =
    post_order(port, body(order_fields("priced-1", "priced-sku", 3, token)), "")
  assert status == 201
  let assert Some(charge) =
    providers.charge_for(application.providers, "pay-priced-1")
  assert charge.amount_cents == 3750
  assert stock(application, "priced-sku") == 2

  // An unknown SKU has no price, so nothing is reserved or charged.
  let #(status, text) =
    post_order(
      port,
      body(order_fields("priced-2", "no-such-sku", 1, token)),
      "",
    )
  assert status == 422
  assert error_code(text) == Ok("unknown_sku")
  assert providers.charge_for(application.providers, "pay-priced-2") == None
}

/// A request carrying an amount, a card number, or any other field outside
/// the request shape is refused before anything is reserved or charged, as
/// is a quantity below one.
pub fn client_amount_and_card_fields_are_refused_test() {
  use application <- with_app(fn(c) { c })
  let pool = application.services.pool
  let assert Ok(Nil) =
    db.set_product(pool, "strict-sku", unit_price_cents: 4999, available: 10)
  let assert Ok(#(_, port)) = web.start(application)
  // The request shape the API used to accept: a client-chosen amount and a
  // raw card number.
  let legacy =
    body([
      #("order_id", json.string("strict-1")),
      #("sku", json.string("strict-sku")),
      #("quantity", json.int(5)),
      #("card", json.string(providers.card_ok)),
      #("amount_cents", json.int(1)),
      #("address", json.string("10 Main St")),
      #("email", json.string("strict-1@example.test")),
    ])
  let #(status, _) = post_order(port, legacy, "")
  assert status == 422
  let #(status, _) =
    post_order(
      port,
      body([
        #("amount_cents", json.int(1)),
        ..order_fields("strict-2", "strict-sku", 1, "tok_any")
      ]),
      "",
    )
  assert status == 422
  let #(status, _) =
    post_order(port, body(order_fields("strict-3", "strict-sku", 0, "t")), "")
  assert status == 422
  let #(status, _) =
    post_order(port, body(order_fields("strict-4", "strict-sku", -2, "t")), "")
  assert status == 422
  assert providers.snapshot(application.providers).charge_requests == 0
  assert stock(application, "strict-sku") == 10
}

/// Every text column of every table in the database, including grind's
/// job rows and saga_postgres's checkpoints.
fn database_contains(pool: pog.Connection, needle: String) -> Bool {
  let assert Ok(tables) =
    pog.query(
      "SELECT quote_ident(table_schema) || '.' || quote_ident(table_name)
       FROM information_schema.tables
       WHERE table_type = 'BASE TABLE'
         AND table_schema NOT IN ('pg_catalog', 'information_schema')",
    )
    |> pog.returning(decode.at([0], decode.string))
    |> pog.execute(pool)
  list.any(tables.rows, fn(table) {
    let assert Ok(found) =
      pog.query("SELECT count(*) FROM " <> table <> " t WHERE t::text LIKE $1")
      |> pog.parameter(pog.text("%" <> needle <> "%"))
      |> pog.returning(decode.at([0], decode.int))
      |> pog.execute(pool)
    found.rows != [0]
  })
}

/// The card number goes to the payment provider only. Local and durable
/// orders run on the provider's token, and no row the app, grind or
/// saga_postgres writes contains the card digits.
pub fn card_digits_never_reach_stored_rows_test() {
  use application <- with_app(fn(c) { c })
  let pool = application.services.pool
  let assert Ok(Nil) =
    db.set_product(pool, "token-sku", unit_price_cents: 900, available: 5)
  let assert Ok(#(_, port)) = web.start(application)
  let assert Ok(token) = tokenise(application, providers.card_ok)
  assert !string.contains(token, providers.card_ok)

  let #(status, _) =
    post_order(port, body(order_fields("token-1", "token-sku", 1, token)), "")
  assert status == 201
  let #(status, placed) =
    post_order(
      port,
      body(order_fields("token-2", "token-sku", 2, token)),
      "?mode=durable",
    )
  assert status == 202
  let assert Ok(job_id) = json.parse(placed, decode.at(["job_id"], decode.int))
  let assert grind.Succeeded(_) = await_job(application, job_id)
  assert eventually(fn() { db.receipt_sent(pool, "token-2") }, 100)
  let assert Some(charge) =
    providers.charge_for(application.providers, "pay-token-2")
  assert charge.amount_cents == 1800

  assert database_contains(pool, "token-2")
  assert !database_contains(pool, providers.card_ok)
}

// --- caller identity and order ownership -----------------------------------------------

/// Every route needs a bearer token that resolves to a configured customer.
pub fn requests_without_a_customer_identity_are_refused_test() {
  use application <- with_app(fn(c) { c })
  let pool = application.services.pool
  let assert Ok(Nil) = set_stock(pool, "anon-sku", 3)
  let assert Ok(#(_, port)) = web.start(application)
  let token = providers.tokenise(application.providers, providers.card_ok)
  let placement = body(order_fields("anon-1", "anon-sku", 1, token))

  let #(status, _) = call_api(port, http.Post, "/orders", None, placement)
  assert status == 401
  let #(status, _) =
    call_api(port, http.Post, "/orders", Some("not-a-customer"), placement)
  assert status == 401
  let #(status, _) = call_api(port, http.Get, "/orders/anon-1", None, "")
  assert status == 401
  assert providers.snapshot(application.providers).charge_requests == 0
  assert stock(application, "anon-sku") == 3
}

/// An order belongs to the customer who placed it: another customer reads
/// it as absent.
pub fn another_customers_order_reads_as_not_found_test() {
  use application <- with_app(fn(c) { c })
  let pool = application.services.pool
  let assert Ok(Nil) = set_stock(pool, "owned-sku", 3)
  let assert Ok(#(_, port)) = web.start(application)
  let token = providers.tokenise(application.providers, providers.card_ok)
  let placement = body(order_fields("owned-1", "owned-sku", 1, token))
  let #(status, _) =
    call_api(port, http.Post, "/orders", Some(alice_token), placement)
  assert status == 201

  let #(status, text) =
    call_api(port, http.Get, "/orders/owned-1", Some(alice_token), "")
  assert status == 200
  let assert Ok("confirmed") =
    json.parse(text, decode.at(["status"], decode.string))
  let #(status, text) =
    call_api(port, http.Get, "/orders/owned-1", Some(bob_token), "")
  assert status == 404
  assert !string.contains(text, "charge")
}

/// The client's `order_id` is an idempotency key owned by the customer who
/// first used it. The same customer repeating the placement gets the
/// existing order back; a changed placement or another customer gets 409.
/// None of them runs the saga again or changes the order.
pub fn repeated_order_id_never_reruns_the_saga_test() {
  use application <- with_app(fn(c) { c })
  let pool = application.services.pool
  let assert Ok(Nil) = set_stock(pool, "repeat-sku", 5)
  let assert Ok(#(_, port)) = web.start(application)
  let alice_card = providers.tokenise(application.providers, providers.card_ok)
  let bob_card = providers.tokenise(application.providers, providers.card_ok)
  let placement = body(order_fields("repeat-1", "repeat-sku", 1, alice_card))
  let #(status, _) =
    call_api(port, http.Post, "/orders", Some(alice_token), placement)
  assert status == 201
  let before = providers.snapshot(application.providers)
  let assert Some(#(domain.Confirmed, detail)) =
    db.order_status(pool, "repeat-1")

  // The same customer, the same placement: the existing order.
  let #(status, text) =
    call_api(port, http.Post, "/orders", Some(alice_token), placement)
  assert status == 200
  let assert Ok("confirmed") =
    json.parse(text, decode.at(["status"], decode.string))
  let #(status, _) =
    call_api(
      port,
      http.Post,
      "/orders?mode=durable",
      Some(alice_token),
      placement,
    )
  assert status == 200

  // The same customer with a different placement, and another customer.
  let changed = body(order_fields("repeat-1", "repeat-sku", 2, alice_card))
  let #(status, text) =
    call_api(port, http.Post, "/orders", Some(alice_token), changed)
  assert status == 409
  assert error_code(text) == Ok("order_id_conflict")
  let hijack = body(order_fields("repeat-1", "repeat-sku", 1, bob_card))
  let #(status, _) =
    call_api(port, http.Post, "/orders", Some(bob_token), hijack)
  assert status == 409
  let #(status, _) =
    call_api(port, http.Post, "/orders?mode=durable", Some(bob_token), hijack)
  assert status == 409

  let after = providers.snapshot(application.providers)
  assert after.charge_requests == before.charge_requests
  assert after.shipment_requests == before.shipment_requests
  assert stock(application, "repeat-sku") == 4
  assert db.order_status(pool, "repeat-1") == Some(#(domain.Confirmed, detail))
}
