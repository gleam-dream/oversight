//// Wiring: one pog pool shared by grind and the app, one egress client, the
//// telemetry collector, and the grind runtime with the delivery worker.

import gleam/erlang/process
import gleam/result
import gleam/string
import gleam/time/duration
import grind
import grind/queue
import grind/worker.{type Worker}
import pog
import sinal
import webhooks/attempt.{type Delivery, type DeliveryError, type Receipt}
import webhooks/delivery.{type Deps, type Plan}
import webhooks/egress.{type Egress}
import webhooks/store
import webhooks/subscription.{type Tier, InternalTier, PublicTier}
import webhooks/telemetry.{type Collector}
import webhooks/tenant.{type Tenant}
import webhooks/web

pub type Options {
  Options(
    database_url: String,
    /// Grind's schema; app tables stay in `public`.
    grind_schema: String,
    queue: String,
    /// Each tenant's tier and API key.
    tenants: List(Tenant),
    egress: egress.Settings,
    plan: Plan,
    /// `False` for tests, which run due jobs with `grind/testing.drain`.
    consumers: Bool,
  )
}

/// The demo's tenants and tiers. Their keys come from the environment; see
/// `tenant.from_environment`.
pub fn default_tenants() -> List(#(String, Tier)) {
  [#("acme", PublicTier), #("globex", PublicTier), #("ops", InternalTier)]
}

pub fn options(database_url: String, tenants: List(Tenant)) -> Options {
  Options(
    database_url:,
    grind_schema: "grind",
    queue: "webhooks",
    tenants:,
    egress: egress.default_settings(),
    plan: delivery.default_plan(),
    consumers: True,
  )
}

pub type Service {
  Service(
    db: pog.Connection,
    jobs: grind.Grind,
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
  use egress <- result.try(
    egress.start(options.egress)
    |> result.map_error(fn(e) { "egress: " <> string.inspect(e) }),
  )

  // One pool for grind and the app's tables; the worker reaches it through
  // `worker.connection(context)`.
  let pool_name = process.new_name("webhooks_db")
  use pool <- result.try(
    pog.url_config(pool_name, options.database_url)
    |> result.replace_error("invalid DATABASE_URL"),
  )
  let deps =
    delivery.Deps(
      egress:,
      tenants: tenant.tiers(options.tenants),
      max_response_bytes: 4096,
    )
  let worker = delivery.worker(deps, options.plan, options.queue)
  let config =
    grind.new(pool)
    |> grind.with_schema(options.grind_schema)
    |> grind.with_worker(worker)
    |> grind.with_startup_migration
    |> grind.with_queue(
      queue.new(options.queue)
      |> queue.with_poll_interval(duration.milliseconds(50))
      |> queue.with_concurrency(4),
    )
  let config = case options.consumers {
    True -> config
    False -> grind.without_consumers(config)
  }
  use jobs <- result.try(
    grind.start(config, process.new_name("webhooks_jobs"))
    |> result.map_error(grind.describe_start_error),
  )
  let db = grind.connection(jobs)
  use Nil <- result.try(
    store.migrate(db)
    |> result.map_error(fn(e) { "app migrate: " <> string.inspect(e) }),
  )
  let context =
    web.Context(
      db:,
      jobs:,
      worker:,
      tenants: options.tenants,
      internal_hosts: options.egress.internal_hosts,
    )
  Ok(Service(
    db:,
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

pub fn stop(service: Service) -> Nil {
  let _ = grind.stop(service.jobs)
  egress.stop(service.egress)
  telemetry.detach(service.attachments)
}
