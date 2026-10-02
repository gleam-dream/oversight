//// Wires the packages together: the app's pog pool (shared by the order
//// tables and the saga storage), grind's own database handle and two queue
//// consumers, one http_gun client with a Sinal forwarder, the scripted
//// providers, and the wisp/mist order API.

import checkout/db
import checkout/domain.{type OrderRequest}
import checkout/gateway
import checkout/jobs
import checkout/orders.{type Services, Services}
import checkout/providers.{type Providers}
import checkout/saga_store
import checkout/telemetry
import checkout/workflow
import gleam/erlang/process.{type Pid}
import gleam/option.{Some}
import gleam/otp/static_supervisor
import gleam/result
import gleam/string
import grind/postgres
import grind/queue
import grind/registry
import grind/worker.{type Worker}
import http_gun
import saga/execution
import sinal/forwarder

pub type Config {
  Config(
    database_url: String,
    /// Per-request budgets for the two provider APIs.
    payment_deadline_ms: Int,
    shipping_deadline_ms: Int,
    /// How long a "slow" scripted provider holds its answer.
    provider_slow_ms: Int,
    charge_attempts: Int,
    saga_lease_ms: Int,
    grind_schema: String,
    grind_statement_deadline_ms: Int,
    poll_interval_ms: Int,
    redelivery_ms: Int,
  )
}

pub fn default_config(database_url: String) -> Config {
  Config(
    database_url:,
    payment_deadline_ms: 300,
    shipping_deadline_ms: 300,
    provider_slow_ms: 800,
    charge_attempts: 2,
    saga_lease_ms: 30_000,
    grind_schema: "checkout_jobs",
    grind_statement_deadline_ms: 1500,
    poll_interval_ms: 50,
    redelivery_ms: 100,
  )
}

pub type App {
  App(
    services: Services,
    providers: Providers,
    checkout_worker: Worker(OrderRequest, String, Nil),
    receipt_consumer: queue.Consumer,
    checkout_consumer: queue.Consumer,
    pool_pid: Pid,
    observability_pid: Pid,
    http: http_gun.Client,
  )
}

pub fn start(config: Config) -> Result(App, String) {
  // Application pool: order tables and saga checkpoints.
  use #(pool_pid, pool) <- result.try(db.start_pool(config.database_url, 10))
  use _ <- result.try(db.migrate(pool) |> result.map_error(string.inspect))

  // Grind: its own pool on the same database (it cannot take ours).
  use grind_settings <- result.try(
    postgres.settings(config.database_url)
    |> postgres.with_schema(config.grind_schema)
    |> postgres.with_pool_size(5)
    |> postgres.with_statement_deadline(config.grind_statement_deadline_ms)
    // The lock wait plus a private 1000 ms margin must stay below the
    // statement deadline; the 2000 ms default fails `validate`.
    |> postgres.with_unique_lock_wait(250)
    |> postgres.validate
    |> result.map_error(string.inspect),
  )
  use grind <- result.try(
    postgres.start(grind_settings) |> result.map_error(string.inspect),
  )
  use _ <- result.try(
    postgres.migrate(grind) |> result.map_error(string.inspect),
  )

  // Observability: a supervised forwarder for http_gun lifecycle events.
  let http_observations =
    forwarder.new(process.new_name("checkout_http_observations"))
  use observability <- result.try(
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(forwarder.supervised(http_observations))
    |> static_supervisor.start
    |> result.map_error(string.inspect),
  )
  let collector = telemetry.start()

  use providers <- result.try(
    providers.start(config.provider_slow_ms) |> result.map_error(string.inspect),
  )
  use http <- result.try(
    http_gun.start(gateway.client_config(Some(http_observations)))
    |> result.map_error(string.inspect),
  )
  let gateway =
    gateway.Gateway(
      client: http,
      payments_url: providers.payments_url(providers),
      shipping_url: providers.shipping_url(providers),
      payment_deadline_ms: config.payment_deadline_ms,
      shipping_deadline_ms: config.shipping_deadline_ms,
    )
  let client_for = fn(order_id) {
    http_gun.with_correlation(http, telemetry.order(order_id))
  }
  let store =
    saga_store.start(pool, config.saga_lease_ms, fn(id, pid) {
      // Execution ids are "checkout:<order id>".
      case telemetry.from_tagged_id(id) {
        Ok(order) -> telemetry.link(collector, telemetry.Emitter(pid), order)
        Error(Nil) -> Nil
      }
    })
  let checkout =
    workflow.define(workflow.Deps(
      pool:,
      gateway:,
      client_for:,
      charge_attempts: config.charge_attempts,
    ))
  let services =
    Services(
      pool:,
      grind:,
      gateway:,
      collector:,
      store:,
      workflow: checkout,
      persistence: workflow.persistence(checkout),
      saga_config: execution.Config(
        ..execution.config(),
        step_timeout: Some(10_000),
      ),
      receipt_worker: orders.receipt_worker(pool),
    )
  let checkout_worker = jobs.checkout_worker(services, config.redelivery_ms)

  use policy <- result.try(
    queue.default_policy()
    |> queue.with_poll_interval(config.poll_interval_ms)
    |> queue.with_maximum_concurrency(4)
    |> queue.with_lease_duration(config.grind_statement_deadline_ms * 5)
    |> queue.validate_policy
    |> result.map_error(string.inspect),
  )
  let assert Ok(receipts) = registry.new(orders.receipts_queue)
  let assert Ok(receipts) = registry.register(receipts, services.receipt_worker)
  let assert Ok(checkouts) = registry.new(orders.checkouts_queue)
  let assert Ok(checkouts) = registry.register(checkouts, checkout_worker)
  use receipt_consumer <- result.try(
    queue.start(grind, receipts, policy) |> result.map_error(string.inspect),
  )
  use checkout_consumer <- result.try(
    queue.start(grind, checkouts, policy) |> result.map_error(string.inspect),
  )
  // Receipts left in the outbox by a previous run.
  let _ = orders.flush_outbox(services)

  Ok(App(
    services:,
    providers:,
    checkout_worker:,
    receipt_consumer:,
    checkout_consumer:,
    pool_pid:,
    observability_pid: observability.pid,
    http:,
  ))
}

/// Stops everything `start` started. Must run in the process that called
/// `start`: grind consumers may only be stopped by their starter.
pub fn stop(app: App) -> Nil {
  let _ = queue.stop(app.checkout_consumer)
  let _ = queue.stop(app.receipt_consumer)
  let _ = postgres.close(app.services.grind)
  let _ = http_gun.stop(app.http)
  providers.stop(app.providers)
  telemetry.stop(app.services.collector)
  // Both are supervisors linked to this process: a `normal` exit from their
  // parent shuts them down quietly.
  process.send_exit(app.observability_pid)
  process.send_exit(app.pool_pid)
}
