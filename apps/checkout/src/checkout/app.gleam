//// Wires the packages together: one pog pool, which grind builds from the
//// app's `pog.Config` and which also serves the order tables and
//// saga_postgres; grind's runtime with both workers; one http_gun client
//// with a Sinal forwarder; the scripted providers; and the wisp/mist order
//// API.

import checkout/db
import checkout/domain.{type OrderRequest}
import checkout/gateway
import checkout/jobs
import checkout/orders.{type Services, Services}
import checkout/providers.{type Providers}
import checkout/telemetry
import checkout/workflow
import gleam/erlang/process.{type Pid}
import gleam/otp/static_supervisor
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import grind
import grind/queue
import grind/worker.{type Worker}
import http_gun
import pog
import saga/execution
import saga_postgres
import sinal/forwarder

pub type Config {
  Config(
    database_url: String,
    pool_size: Int,
    /// Per-request budgets for the two provider APIs.
    payment_deadline: Duration,
    shipping_deadline: Duration,
    /// How long a "slow" scripted provider holds its answer.
    provider_slow_ms: Int,
    charge_attempts: Int,
    /// saga_postgres's claim lease: how long the claim of a lost node blocks
    /// the next `drive`. (A killed runner releases its claim at once.)
    saga_lease: Duration,
    grind_statement_deadline_ms: Int,
    /// Grind's attempt lease; at least 4 × the statement deadline.
    grind_lease: Duration,
    poll_interval_ms: Int,
    redelivery_ms: Int,
  )
}

pub fn default_config(database_url: String) -> Config {
  Config(
    database_url:,
    pool_size: 10,
    payment_deadline: duration.milliseconds(300),
    shipping_deadline: duration.milliseconds(300),
    provider_slow_ms: 800,
    charge_attempts: 2,
    saga_lease: duration.seconds(30),
    grind_statement_deadline_ms: 1500,
    grind_lease: duration.seconds(6),
    poll_interval_ms: 50,
    redelivery_ms: 100,
  )
}

pub type App {
  App(
    services: Services,
    providers: Providers,
    checkout_worker: Worker(OrderRequest, String, Nil),
    observability_pid: Pid,
    http: http_gun.Client,
  )
}

pub fn start(config: Config) -> Result(App, String) {
  // One pool for everything. Grind builds and owns it; the app knows its
  // name, so the handles exist before the runtime starts.
  let pool_name = process.new_name("checkout_pool")
  use pool_config <- result.try(
    pog.url_config(pool_name, config.database_url)
    |> result.replace_error("invalid DATABASE_URL"),
  )
  let pool = pog.named_connection(pool_name)
  let jobs_name = process.new_name("checkout_jobs")
  let jobs = grind.named(jobs_name)
  let storage =
    saga_postgres.config(pool)
    |> saga_postgres.with_lease(config.saga_lease)

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
  let payments_url = providers.payments_url(providers)
  let shipping_url = providers.shipping_url(providers)
  use http <- result.try(
    http_gun.start(
      gateway.client_config(http_observations, [
        gateway.authority(payments_url),
        gateway.authority(shipping_url),
      ]),
    )
    |> result.map_error(http_gun.describe_start_error),
  )
  let gateway =
    gateway.Gateway(
      client: http,
      payments_url:,
      shipping_url:,
      payment_deadline: config.payment_deadline,
      shipping_deadline: config.shipping_deadline,
    )
  let checkout =
    workflow.define(workflow.Deps(
      pool:,
      gateway:,
      charge_attempts: config.charge_attempts,
    ))
  let saga_config =
    execution.config()
    |> execution.with_step_timeout(execution.After(duration.seconds(10)))
  let services =
    Services(
      pool:,
      jobs:,
      gateway:,
      collector:,
      storage: saga_postgres.storage(storage),
      workflow: checkout,
      persistence: workflow.persistence(checkout, saga_config),
      saga_config:,
      receipt_worker: orders.receipt_worker(),
    )
  let checkout_worker =
    jobs.checkout_worker(
      services,
      redelivery: duration.milliseconds(config.redelivery_ms),
      busy: config.saga_lease,
    )

  let queue = fn(name) {
    queue.new(name)
    |> queue.with_poll_interval(duration.milliseconds(config.poll_interval_ms))
    |> queue.with_concurrency(4)
    |> queue.with_lease(config.grind_lease)
  }
  let grind_config =
    grind.new(pog.pool_size(pool_config, config.pool_size))
    |> grind.with_worker(services.receipt_worker)
    |> grind.with_worker(checkout_worker)
    |> grind.with_queue(queue(orders.receipts_queue))
    |> grind.with_queue(queue(orders.checkouts_queue))
    |> grind.with_statement_deadline(duration.milliseconds(
      config.grind_statement_deadline_ms,
    ))
    // The lock wait plus a 1000 ms margin must stay below the statement
    // deadline; the 2000 ms default fails the check.
    |> grind.with_unique_lock_wait(duration.milliseconds(250))
    // Grind keeps its tables in their own schema, away from the app's; the
    // pool keeps the app's `search_path`, so the app's queries stay
    // unqualified. The runtime migrates its schema before any consumer polls.
    |> grind.with_schema("checkout_jobs")
    |> grind.with_startup_migration
  use _ <- result.try(
    grind.start(grind_config, jobs_name)
    |> result.map_error(grind.describe_start_error),
  )
  use _ <- result.try(db.migrate(pool) |> result.map_error(string.inspect))
  use _ <- result.try(
    saga_postgres.migrate(storage)
    |> result.map_error(saga_postgres.describe_migrate_error),
  )

  Ok(App(
    services:,
    providers:,
    checkout_worker:,
    observability_pid: observability.pid,
    http:,
  ))
}

/// Stops everything `start` started. Grind drains its queues first and
/// then closes the pool.
pub fn stop(app: App) -> Nil {
  let _ = grind.stop(app.services.jobs)
  http_gun.stop(app.http)
  providers.stop(app.providers)
  telemetry.stop(app.services.collector)
  // A supervisor linked to this process: a `normal` exit from its parent
  // shuts it down quietly.
  process.send_exit(app.observability_pid)
}
