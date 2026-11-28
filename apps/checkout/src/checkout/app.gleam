//// Wires the packages together: one pog pool, which grind builds from the
//// app's `pog.Config` and which also serves the order tables and
//// saga_postgres; grind's runtime with both workers; one http_gun client
//// with a Sinal forwarder; the scripted providers; and the wisp/mist order
//// API.
////
//// Every process the application owns runs under one supervisor:
////
//// ```text
//// root (OneForOne)
//// ├─ observability (OneForOne)
//// │  ├─ forwarder        http_gun's lifecycle events
//// │  └─ collector        the telemetry the app keeps
//// └─ service (RestForOne)
////    ├─ http client      provider calls
////    ├─ grind            the pool, both queues, the workers
////    ├─ endpoint         the port the listener is bound to
////    ├─ listener         the order API
////    └─ sweeper          resolves pending orders nothing will finish
//// ```
////
//// Observation is optional to the work: http_gun drops an event while the
//// forwarder is away, and the telemetry handlers exist only while the
//// collector that attached them runs, so neither restarts anything else. In `service` each child uses the
//// ones before it: a job calls the providers through the client, and a
//// request reads and writes through grind's pool. `RestForOne` restarts a
//// failed child and everything started after it, so the API is never up
//// without its pool, and a job never runs without its client.
////
//// The rest of the application holds names, not pids: the pool, the grind
//// runtime, the client, the collector and the endpoint are each reached by
//// the name made once in `start`, so a handle taken before a restart is
//// good after it. A restart restores processes, not state: jobs and sagas
//// resume from PostgreSQL, and the collector starts empty.
////
//// The scripted providers stand in for other companies' services. They
//// start first and stay outside the tree.

import checkout/customers.{type Customers}
import checkout/db
import checkout/domain.{type Order}
import checkout/gateway
import checkout/jobs
import checkout/orders.{type Services, Services}
import checkout/providers.{type Providers}
import checkout/sweeper
import checkout/telemetry
import checkout/web
import checkout/workflow
import envoy
import gleam/erlang/process.{type Name, type Pid}
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
    /// Who may call the order API: bearer token to customer id.
    customers: Customers,
    /// The order API's port on loopback; 0 binds any free port.
    port: Int,
    /// How many telemetry entries the collector keeps; the oldest are
    /// discarded beyond it.
    telemetry_capacity: Int,
    /// How often the sweeper looks for pending orders nothing will finish,
    /// and how long an order must have been pending to be looked at.
    sweep_every: Duration,
    stale_after: Duration,
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
    customers: customers.from_list([]),
    port: 0,
    telemetry_capacity: 10_000,
    sweep_every: duration.minutes(1),
    stale_after: duration.minutes(5),
  )
}

pub type App {
  App(
    services: Services,
    providers: Providers,
    checkout_worker: Worker(Order, String, Nil),
    /// The provider client, by name.
    http: http_gun.Client,
    customers: Customers,
    /// The application's root supervisor.
    root: Pid,
    endpoint: Name(web.EndpointMessage),
  )
}

pub fn start(config: Config) -> Result(App, String) {
  // Every name is made once, here: names are atoms, which are never
  // collected, and a restarted child registers under the same name.
  let pool_name = process.new_name("checkout_pool")
  let jobs_name = process.new_name("checkout_jobs")
  let http_name = process.new_name("checkout_http")
  let endpoint = process.new_name("checkout_endpoint")
  let http_observations =
    forwarder.new(process.new_name("checkout_http_observations"))
  let collector_name = process.new_name("checkout_collector")

  // Configuration is checked before anything starts.
  use pool_config <- result.try(
    pog.url_config(pool_name, config.database_url)
    |> result.replace_error("invalid DATABASE_URL"),
  )
  use secret <- result.try(
    web.secret_key_base(envoy.get(web.secret_key_base_variable)),
  )

  // The scripted providers are not the application's processes.
  use providers <- result.try(
    providers.start(config.provider_slow_ms) |> result.map_error(string.inspect),
  )
  let payments_url = providers.payments_url(providers)
  let shipping_url = providers.shipping_url(providers)

  // One pool for everything. Grind builds and owns it; the app reaches it
  // by name, so these handles exist before any process does.
  let pool = pog.named_connection(pool_name)
  let jobs = grind.named(jobs_name)
  // Each provider call is bounded by its own deadline; this view bounds any
  // other call through the client.
  let http =
    http_gun.named(http_name) |> http_gun.with_timeout(duration.seconds(5))
  let storage =
    saga_postgres.config(pool)
    |> saga_postgres.with_lease(config.saga_lease)
  let collector =
    telemetry.new(collector_name, capacity: config.telemetry_capacity)
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

  let observability =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(forwarder.supervised(http_observations))
    |> static_supervisor.add(telemetry.supervised(collector))
  let service =
    static_supervisor.new(static_supervisor.RestForOne)
    |> static_supervisor.add(http_gun.supervised(
      gateway.client_config(http_observations, [
        gateway.authority(payments_url),
        gateway.authority(shipping_url),
      ]),
      http_name,
    ))
    |> static_supervisor.add(grind.supervised(grind_config, jobs_name))
    |> static_supervisor.add(web.endpoint(endpoint))
    |> static_supervisor.add(web.listener(
      web.Context(services:, checkout_worker:, customers: config.customers),
      secret_key_base: secret,
      port: config.port,
      endpoint:,
    ))
    |> static_supervisor.add(sweeper.supervised(
      services,
      checkout_worker,
      every: config.sweep_every,
      stale_after: config.stale_after,
    ))
  let started =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(static_supervisor.supervised(observability))
    |> static_supervisor.add(static_supervisor.supervised(service))
    |> static_supervisor.start
  case started {
    // A child that cannot start stops the children before it, and the
    // supervisor reports the failure. Only what is outside the tree is
    // left to undo.
    Error(error) -> {
      providers.stop(providers)
      Error(string.inspect(error))
    }
    Ok(root) -> {
      let app =
        App(
          services:,
          providers:,
          checkout_worker:,
          http:,
          customers: config.customers,
          root: root.pid,
          endpoint:,
        )
      let migrated = {
        use _ <- result.try(
          db.migrate(pool) |> result.map_error(db.describe_migrate_error),
        )
        saga_postgres.migrate(storage)
        |> result.map_error(saga_postgres.describe_migrate_error)
      }
      case migrated {
        Ok(_) -> Ok(app)
        // A refused schema stops what already started, so a failed boot
        // leaves no workers polling the database.
        Error(error) -> {
          stop(app)
          Error(error)
        }
      }
    }
  }
}

/// The port the order API listens on now. With `Config.port` 0 it changes
/// when the listener restarts.
pub fn port(app: App) -> Result(Int, Nil) {
  web.port(app.endpoint)
}

/// Stops the application and returns when every process of the tree has
/// exited. The supervisors stop their children in reverse start order: the
/// listener first, then grind, which lets running jobs finish within each
/// queue's grace and closes the pool, then the client and the observers.
///
/// Call it from the process that called `start`: that process is linked to
/// the root and to the scripted providers.
pub fn stop(app: App) -> Nil {
  process.unlink(app.root)
  stop_supervisor(app.root)
  providers.stop(app.providers)
}

@external(erlang, "checkout_ffi", "stop_supervisor")
fn stop_supervisor(root: Pid) -> Nil
