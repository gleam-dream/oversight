//// Wiring: two database pools (the app's pog pool and grind's own), two
//// egress clients, the telemetry collector, and the grind worker.

import gleam/dict.{type Dict}
import gleam/erlang/atom
import gleam/erlang/process
import gleam/option.{Some}
import gleam/otp/static_supervisor
import gleam/result
import gleam/string
import grind/postgres
import grind/queue
import grind/registry
import grind/worker.{type Worker}
import pog
import sinal
import sinal/forwarder
import webhooks/attempt.{type Delivery, type DeliveryError, type Receipt}
import webhooks/delivery.{type Deps, type Plan}
import webhooks/egress.{type Egress}
import webhooks/store
import webhooks/subscription.{type Tier, InternalTier, PublicTier}
import webhooks/telemetry.{type Collector}
import webhooks/web

pub type Options {
  Options(
    database_url: String,
    /// Grind's schema; app tables stay in `public`.
    grind_schema: String,
    queue: String,
    tenants: Dict(String, Tier),
    egress: egress.Settings,
    plan: Plan,
    clock: fn() -> Int,
  )
}

pub fn default_tenants() -> Dict(String, Tier) {
  dict.from_list([
    #("acme", PublicTier),
    #("globex", PublicTier),
    #("ops", InternalTier),
  ])
}

pub fn options(database_url: String) -> Options {
  Options(
    database_url:,
    grind_schema: "grind",
    queue: "webhooks",
    tenants: default_tenants(),
    egress: egress.default_settings(),
    plan: delivery.default_plan(),
    clock: delivery.unix_seconds,
  )
}

pub type Service {
  Service(
    db: pog.Connection,
    db_pid: process.Pid,
    jobs: postgres.Database,
    egress: Egress,
    collector: Collector,
    attachments: List(sinal.Attachment),
    deps: Deps,
    worker: Worker(Delivery, Receipt, DeliveryError),
    context: web.Context,
    queue: String,
  )
}

pub fn start(options: Options) -> Result(Service, String) {
  let collector = telemetry.start()
  let attachments = telemetry.attach(collector)

  // http_gun only emits through a forwarder the application owns.
  let assert Ok(http_observations) =
    forwarder.new(process.new_name("webhooks_http_observations"), 1024)
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(forwarder.supervised(http_observations))
    |> static_supervisor.start

  // Grind: its own pool, started from a URL, in its own schema.
  use grind_settings <- result.try(
    postgres.settings(options.database_url)
    |> postgres.with_schema(options.grind_schema)
    |> postgres.with_pool_size(4)
    |> postgres.validate
    |> result.map_error(fn(e) { "grind settings: " <> string.inspect(e) }),
  )
  use jobs <- result.try(
    postgres.start(grind_settings)
    |> result.map_error(fn(e) { "grind start: " <> string.inspect(e) }),
  )
  use Nil <- result.try(
    postgres.migrate(jobs)
    |> result.map_error(fn(e) { "grind migrate: " <> string.inspect(e) }),
  )

  // The app's pool for its own tables.
  use pool_config <- result.try(
    pog.url_config(process.new_name("webhooks_app_db"), options.database_url)
    |> result.replace_error("invalid DATABASE_URL"),
  )
  use started <- result.try(
    pog.start(pog.pool_size(pool_config, 4))
    |> result.map_error(fn(e) { "app pool: " <> string.inspect(e) }),
  )
  let db = started.data
  use Nil <- result.try(
    migrate_with_retry(db, 50)
    |> result.map_error(fn(e) { "app migrate: " <> string.inspect(e) }),
  )

  use egress <- result.try(
    egress.start(
      egress.Settings(..options.egress, observations: Some(http_observations)),
    )
    |> result.map_error(fn(e) { "egress: " <> string.inspect(e) }),
  )

  let deps =
    delivery.Deps(
      db:,
      egress:,
      tenants: options.tenants,
      clock: options.clock,
      snooze: attempt.default_snooze(),
      max_response_bytes: 4096,
      correlate: fn(id, delivery_id) {
        telemetry.note_http(collector, id, delivery_id)
      },
    )
  let worker = delivery.worker(deps, options.plan)
  let context =
    web.Context(
      db:,
      jobs:,
      queue: options.queue,
      worker:,
      tenants: options.tenants,
      internal_hosts: options.egress.internal_hosts,
      on_submitted: fn(job_id, delivery_id) {
        telemetry.note_job(collector, job_id, delivery_id)
      },
    )
  Ok(Service(
    db:,
    db_pid: started.pid,
    jobs:,
    egress:,
    collector:,
    attachments:,
    deps:,
    worker:,
    context:,
    queue: options.queue,
  ))
}

/// The pog pool connects asynchronously; the first queries can fail.
fn migrate_with_retry(
  db: pog.Connection,
  remaining: Int,
) -> Result(Nil, store.StoreError) {
  case store.migrate(db), remaining {
    Ok(Nil), _ -> Ok(Nil)
    Error(e), 0 -> Error(e)
    Error(_), _ -> {
      process.sleep(20)
      migrate_with_retry(db, remaining - 1)
    }
  }
}

/// A consumer for this service's queue; it is linked to, and must be stopped
/// by, the calling process.
pub fn start_consumer(
  service: Service,
  policy: queue.QueuePolicy,
) -> queue.Consumer {
  start_consumer_with(service, service.worker, policy)
}

/// A consumer running a different definition of the same worker, e.g. one
/// whose deps hold cassette playback clients.
pub fn start_consumer_with(
  service: Service,
  definition: Worker(Delivery, Receipt, DeliveryError),
  policy: queue.QueuePolicy,
) -> queue.Consumer {
  let assert Ok(workers) = registry.new(service.queue)
  let assert Ok(workers) = registry.register(workers, definition)
  let assert Ok(policy) = queue.validate_policy(policy)
  let assert Ok(consumer) = queue.start(service.jobs, workers, policy)
  consumer
}

pub fn manual_policy() -> queue.QueuePolicy {
  queue.default_policy() |> queue.with_manual_polling
}

pub fn stop(service: Service) -> Nil {
  egress.stop(service.egress)
  let _ = postgres.close(service.jobs)
  telemetry.detach(service.attachments)
  // pog has no stop; a supervisor exits quietly on `shutdown`.
  process.unlink(service.db_pid)
  process.send_abnormal_exit(service.db_pid, atom.create("shutdown"))
  Nil
}
