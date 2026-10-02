//// End-to-end tests. They need PostgreSQL: run them with
//// `../scripts/with-postgres.sh gleam test`.

import checkout
import checkout/app.{type App}
import checkout/db
import checkout/domain.{OrderRequest, ProviderUnreachable}
import checkout/gateway
import checkout/jobs
import checkout/orders
import checkout/providers
import checkout/saga_store
import checkout/telemetry
import checkout/web
import envoy
import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import grind/job
import grind/postgres
import http_gun
import http_gun/error
import pog
import saga
import saga/execution
import saga/storage/conformance

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

// --- common path ------------------------------------------------------------

pub fn order_api_confirms_and_sends_receipt_test() {
  use application <- with_app(fn(c) { c })
  let pool = application.services.pool
  let assert Ok(Nil) = db.set_stock(pool, "happy-sku", 3)
  let assert Ok(#(_, port)) = web.start(application)
  let assert Ok(customer) = http_gun.start(gateway.client_config(None))

  let placed = order("happy-1", "happy-sku", providers.card_ok, "10 Main St")
  let assert Ok(req) =
    request.to("http://127.0.0.1:" <> int.to_string(port) <> "/orders")
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(bit_array.from_string(checkout.orders_body(placed)))
  let assert Ok(reply) = http_gun.send(customer, req)
  let _ = http_gun.stop(customer)

  assert reply.response.status == 201
  assert stock(application, "happy-sku") == 2
  let assert Some(charge) =
    providers.charge_for(application.providers, "pay-happy-1")
  assert charge.status == providers.Captured
  let assert Some(_) =
    providers.shipment_for(application.providers, "ship-happy-1")
  let assert Some(#(domain.Confirmed, _)) = db.order_status(pool, "happy-1")
  // The receipt job was enqueued from the outbox and ran.
  assert eventually(fn() { db.receipt_sent(pool, "happy-1") }, 100)

  // One order can be followed across saga, http_gun and grind.
  let trace =
    telemetry.trace(application.services.collector, telemetry.order("happy-1"))
  let sources = list.map(trace, fn(e) { e.source }) |> list.unique
  assert list.contains(sources, telemetry.Saga)
  assert list.contains(sources, telemetry.Http)
  assert list.contains(sources, telemetry.Grind)
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
  // The step error carries http_gun's typed failure class and evidence.
  assert report.error
    == Ok(ProviderUnreachable(
      domain.Shipping,
      error.Failure(error.DeadlineExceeded, error.MayHaveBeenSent),
    ))
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
  // Saga itself reports no unknown effect: the timeout was http_gun's, and
  // the step returned a typed error.
  assert report.unknown_effects == 0
}

pub fn unknown_payment_outcome_is_invisible_to_saga_test() {
  use application <- with_app(fn(c) { c })
  let services = application.services
  let assert Ok(Nil) = db.set_stock(services.pool, "unknown-sku", 5)

  // First answer lost (MayHaveBeenSent), retried under the same provider
  // idempotency key: one charge, two requests, and saga calls it a plain
  // `Completed` although attempt 1's effect was unknown when it ended.
  let lost =
    order("lost-1", "unknown-sku", providers.card_first_answer_lost, "1 St")
  let assert Ok(execution.Completed(booked)) =
    execution.run(services.workflow, lost, services.saga_config)
  assert booked.charged.charge_id != ""
  let snapshot = providers.snapshot(application.providers)
  assert snapshot.charge_requests == 2
  assert list.count(snapshot.charges, fn(c) { c.key == "pay-lost-1" }) == 1

  // Every answer lost: the decider holds. The outcome is Unresolved with the
  // typed http_gun evidence, stock stays reserved, nothing is voided, and
  // `unknown_effects` is still empty.
  let hole = order("hole-1", "unknown-sku", providers.card_black_hole, "1 St")
  let assert Ok(execution.Unresolved(step, evidence, settlement)) =
    execution.run(services.workflow, hole, services.saga_config)
  assert saga.address_to_string(step) == "charge_card"
  assert evidence
    == ProviderUnreachable(
      domain.Payments,
      error.Failure(error.DeadlineExceeded, error.MayHaveBeenSent),
    )
  assert settlement.unknown_effects == []
  assert stock(application, "unknown-sku") == 3
  let assert Some(charge) =
    providers.charge_for(application.providers, "pay-hole-1")
  assert charge.status == providers.Captured
}

/// The only way to make saga report the unknown payment in
/// `unknown_effects` is to crash the step, which turns http_gun's typed
/// failure into a crash reason string.
pub fn crashing_on_unknown_payment_stringifies_the_failure_test() {
  use application <- with_app(fn(c) { c })
  let services = application.services
  let assert Ok(workflow) =
    saga.define("charge-only", fn(input) {
      input
      |> saga.perform(
        saga.step("charge_card", fn(order: domain.OrderRequest) {
          case
            gateway.charge(
              services.gateway,
              services.gateway.client,
              order,
              "pay-" <> order.order_id,
            )
          {
            Error(ProviderUnreachable(failure:, ..))
              if failure.evidence == error.MayHaveBeenSent
            -> panic as error.describe(failure)
            other -> other
          }
        }),
      )
    })
  let hole = order("crash-pay-1", "none", providers.card_black_hole, "1 St")
  let assert Ok(execution.Failed(execution.StepCrashed(_, crash), settlement)) =
    execution.run(workflow, hole, services.saga_config)
  let assert [execution.UnknownEffect(_, execution.StepAttempt(1), _)] =
    settlement.unknown_effects
  // `Crash.reason` is the rendered Erlang exception term.
  assert string.contains(crash.reason, "request may have been sent")
  assert string.starts_with(crash.reason, "{error,#{function =>")
}

// --- advanced: durable saga driven by grind ----------------------------------

pub fn durable_checkout_survives_a_killed_runner_test() {
  // A long shipping budget keeps the shipment call in flight while we kill
  // the saga runner.
  use application <- with_app(fn(c) {
    app.Config(..c, shipping_deadline_ms: 5000)
  })
  let services = application.services
  let assert Ok(Nil) = db.set_stock(services.pool, "durable-sku", 2)
  let arrivals = process.new_subject()
  providers.watch_shipments(application.providers, arrivals)

  let placed =
    order("durable-1", "durable-sku", providers.card_ok, providers.address_hold)
  let assert Ok(job_id) =
    orders.place_durable(services, application.checkout_worker, placed)

  // The shipment request reached the provider (which books it, then holds
  // the answer). Kill the runner that owns the saga execution right now.
  let assert Ok("ship-durable-1") = process.receive(arrivals, 10_000)
  let assert Some(runner) =
    saga_store.owner(services.store, jobs.execution_id(placed))
  process.kill(runner)

  // The grind attempt sees `RunnerLost`, snoozes, and the redelivered job
  // resumes from the checkpoint: reserve and charge are reused, and the
  // interrupted shipment is reconciled by lookup, not booked again.
  assert eventually(
    fn() {
      db.order_status(services.pool, "durable-1")
      |> option.map(fn(s) { s.0 == domain.Confirmed })
      |> option.unwrap(False)
    },
    200,
  )
  let snapshot = providers.snapshot(application.providers)
  assert snapshot.charge_requests == 1
  assert snapshot.shipment_requests == 1
  assert stock(application, "durable-sku") == 1
  assert eventually(fn() { db.receipt_sent(services.pool, "durable-1") }, 100)

  let assert Ok(handle) =
    postgres.bind_handle(services.grind, application.checkout_worker, job_id)
  let assert Ok(job.SucceededWith(summary)) =
    postgres.outcome(services.grind, handle)
  assert summary != ""

  // Two saga runs (before and after the kill), both attributed to the order.
  let runs =
    telemetry.trace(services.collector, telemetry.order("durable-1"))
    |> list.count(fn(e) {
      e.source == telemetry.Saga && e.line == "run start checkout"
    })
  assert runs == 2
}

/// A whole-worker crash: the grind attempt dies (lease expiry, then
/// `Uncertain`) and so does the saga runner. Grind will not redeliver an
/// uncertain job on its own; an operator authorises the replay, and the saga
/// resumes from its checkpoint.
pub fn durable_checkout_after_job_crash_needs_authorised_replay_test() {
  use application <- with_app(fn(c) {
    app.Config(..c, shipping_deadline_ms: 5000)
  })
  let services = application.services
  let assert Ok(Nil) = db.set_stock(services.pool, "crash-sku", 2)
  let arrivals = process.new_subject()
  providers.watch_shipments(application.providers, arrivals)
  let placed =
    order("crash-1", "crash-sku", providers.card_ok, providers.address_hold)
  let assert Ok(job_id) =
    orders.place_durable(services, application.checkout_worker, placed)
  let assert Ok("ship-crash-1") = process.receive(arrivals, 10_000)
  let assert Some(runner) =
    saga_store.owner(services.store, jobs.execution_id(placed))
  let assert Ok(attempt) = parent(runner)

  // Killing the grind attempt does not stop the saga: `durable.drive`
  // detaches, and the runner keeps its claim and its in-flight HTTP call.
  process.kill(attempt)
  process.sleep(100)
  assert process.is_alive(runner)
  process.kill(runner)

  let assert Ok(handle) =
    postgres.bind_handle(services.grind, application.checkout_worker, job_id)
  assert eventually(
    fn() { postgres.state(services.grind, handle) == Ok(job.Uncertain) },
    300,
  )
  let assert Ok(postgres.ResolutionApplied(job.Queued)) =
    postgres.resolve_uncertain(
      services.grind,
      handle,
      postgres.ResolutionRequest(
        "crash-1-replay",
        "operator@example.test",
        "saga checkpoint is authoritative; replay resumes it",
        postgres.AuthorizeReplay,
      ),
    )
  assert eventually(
    fn() { postgres.state(services.grind, handle) == Ok(job.Succeeded) },
    200,
  )
  let assert Some(#(domain.Confirmed, _)) =
    db.order_status(services.pool, "crash-1")
  let snapshot = providers.snapshot(application.providers)
  assert snapshot.charge_requests == 1
  assert snapshot.shipment_requests == 1
}

@external(erlang, "checkout_test_ffi", "parent")
fn parent(pid: process.Pid) -> Result(process.Pid, Nil)

pub fn pog_saga_storage_passes_conformance_test() {
  use application <- with_app(fn(c) { c })
  let store = application.services.store
  let fresh = fn() {
    let id = "conformance-" <> int.to_string(int.random(1_000_000_000))
    Ok(
      conformance.Fixture(saga_store.storage(store, id), fn() {
        saga_store.delete(store, id)
      }),
    )
  }
  assert conformance.run(fresh, 10_000) == Ok(Nil)
}

/// Grind cannot enqueue inside the app's transaction, so the confirmation
/// writes an outbox row instead. A crash between commit and submit leaves
/// the row pending; the next start flushes it, and resubmission converges
/// on the same job because the submission id is derived from the order.
pub fn receipt_outbox_survives_a_crash_between_commit_and_submit_test() {
  let placed = order("outbox-1", "outbox-sku", providers.card_ok, "1 St")
  use first <- with_app(fn(c) { c })
  let pool = first.services.pool
  let assert Ok(Nil) = db.insert_order(pool, "outbox-1")
  // The transaction commits; the process "dies" before flushing.
  let assert Ok(Nil) = db.confirm_with_receipt(pool, placed, "simulated")
  let assert Ok([_, ..]) = db.pending_receipts(pool)
  assert !db.receipt_sent(pool, "outbox-1")

  // A second application instance (as after a restart) flushes on start.
  use second <- with_app(fn(c) { c })
  assert eventually(
    fn() { db.receipt_sent(second.services.pool, "outbox-1") },
    100,
  )

  // Forcing a resubmission of the same receipt converges on the job that
  // the restart already submitted (and which already ran).
  let resubmit = fn() {
    let assert Ok(_) =
      pog.query(
        "UPDATE receipt_outbox SET submitted = false WHERE order_id = $1",
      )
      |> pog.parameter(pog.text("outbox-1"))
      |> pog.execute(second.services.pool)
    let assert Ok([job_id]) = orders.flush_outbox(second.services)
    job_id
  }
  let first_id = resubmit()
  assert resubmit() == first_id
  let assert Ok(handle) =
    postgres.bind_handle(
      second.services.grind,
      second.services.receipt_worker,
      first_id,
    )
  assert postgres.state(second.services.grind, handle) == Ok(job.Succeeded)
}
