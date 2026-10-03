//// One node of the research service: the wiring of every package, and the
//// application API (`start_research`, `cancel_research`, `outcome`).

import fabric
import fabric/run
import fabric/store.{type Store}
import fabric_postgres
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/otp/static_supervisor
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/uri
import grind
import grind/job
import grind/queue
import grind/worker.{type Worker}
import http_gun
import http_gun/config as http_config
import http_gun/destination
import pog
import research_agent/db
import research_agent/domain.{type Published, type Research, Research}
import research_agent/events
import research_agent/jobs.{type ResearchError}
import research_agent/researcher
import research_agent/telemetry.{type Telemetry}
import saga_postgres
import sinal/correlation
import sinal/forwarder

pub type Settings {
  Settings(
    database_url: String,
    /// Unique among live VMs that share the database, stable across restarts.
    node: String,
    /// Isolates every table of the node (tests use one per scenario).
    schema: String,
    /// Base URL of the scripted services (search, pages, publisher, LLM).
    services: String,
    fabric_lease_ms: Int,
    telemetry: Option(Telemetry),
  )
}

pub type App {
  App(
    settings: Settings,
    jobs: grind.Grind,
    db: pog.Connection,
    runs: Store,
    worker: Worker(Research, Published, ResearchError),
    deps: jobs.Deps,
    http: http_gun.Client,
    supervisors: List(Pid),
  )
}

pub fn endpoints(services: String) -> researcher.Endpoints {
  researcher.Endpoints(
    search: services <> "/search",
    pages: services <> "/pages/",
    llm: services <> "/openai/v1",
  )
}

/// One client for the tools, the publisher and the provider, confined to
/// the scripted services. llm_wire sends each model call through a view
/// with its own budget, so the 5 s request timeout does not cut a stream.
fn http_settings(services: String) -> Result(http_config.Config, String) {
  use parsed <- result.try(
    uri.parse(services) |> result.replace_error("invalid services URL"),
  )
  let authority = case parsed.host, parsed.port {
    option.Some(host), option.Some(port) -> host <> ":" <> int.to_string(port)
    option.Some(host), option.None -> host
    option.None, _ -> services
  }
  http_config.default()
  |> http_config.with_destination(
    destination.loopback_only() |> destination.only_hosts([authority]),
  )
  |> http_config.with_request_timeout(http_config.Milliseconds(5000))
  |> Ok
}

/// The app's pool configuration: its own tables, and the unqualified ones in
/// particular, live in the node's schema. Grind sets its own schema for its
/// statements only and restores this value afterwards.
fn pool_config(
  settings: Settings,
  name: process.Name(pog.Message),
) -> Result(pog.Config, String) {
  use config <- result.map(
    pog.url_config(name, settings.database_url)
    |> result.replace_error("invalid DATABASE_URL"),
  )
  pog.connection_parameter(
    config,
    "search_path",
    "\"" <> settings.schema <> "\",public",
  )
}

fn fabric_settings(
  settings: Settings,
  database: pog.Connection,
) -> Result(fabric_postgres.Settings, String) {
  fabric_postgres.settings(database, node: settings.node)
  |> fabric_postgres.with_lease(settings.fabric_lease_ms)
  |> fabric_postgres.with_schema(settings.schema)
  |> result.map_error(string.inspect)
}

fn saga_settings(
  settings: Settings,
  database: pog.Connection,
) -> Result(saga_postgres.Config, String) {
  saga_postgres.config(database)
  |> saga_postgres.with_lease(10_000)
  |> saga_postgres.with_schema(settings.schema)
  |> result.map_error(string.inspect)
}

/// Migrates the app's tables, Fabric's and Saga's on a pool of their own,
/// which is gone before Grind starts: Grind's consumers must not poll while
/// a table a handler needs is missing, and Grind's runtime cannot start
/// them later. Grind's own schema is migrated by its startup migration.
fn migrate_app(settings: Settings) -> Result(Nil, String) {
  let name = process.new_name("research_migrations")
  use config <- result.try(pool_config(settings, name))
  use started <- result.try(
    pog.start(pog.pool_size(config, 1)) |> result.map_error(string.inspect),
  )
  let database = pog.named_connection(name)
  let migrated = {
    use Nil <- result.try(db.migrate(database, settings.schema))
    use fabric_settings <- result.try(fabric_settings(settings, database))
    use Nil <- result.try(
      fabric_postgres.migrate(fabric_settings)
      |> result.map_error(string.inspect),
    )
    use saga_settings <- result.try(saga_settings(settings, database))
    saga_postgres.migrate(saga_settings)
    |> result.map_error(saga_postgres.describe_migrate_error)
  }
  shutdown(started.pid)
  migrated
}

pub fn start(settings: Settings) -> Result(App, String) {
  // Names first: Fabric's store and the saga storage are built over the
  // pool before the runtime exists, and Grind's configuration needs the
  // worker, so the pool is named here and Grind keeps that name. A handler
  // reaches the same pool with `worker.connection`.
  let pool_name = process.new_name("research_pool")
  let jobs_name = process.new_name("research_jobs")
  let http_name = process.new_name("research_http")
  let fwd =
    forwarder.new(process.new_name("research_events"))
    |> forwarder.with_capacity(4096)
  use pool <- result.try(pool_config(settings, pool_name))
  let database = pog.named_connection(pool_name)
  use fabric_settings <- result.try(fabric_settings(settings, database))
  use runs <- result.try(
    fabric_postgres.store(process.new_name("research_runs"), fabric_settings)
    |> result.map_error(string.inspect),
  )
  use saga_settings <- result.try(saga_settings(settings, database))
  use http_settings <- result.try(http_settings(settings.services))
  let http = http_gun.named(http_name)
  let endpoints = endpoints(settings.services)
  use agent <- result.try(
    researcher.build(http, endpoints) |> result.map_error(string.inspect),
  )
  let deps =
    jobs.Deps(
      runs:,
      agent:,
      http:,
      sagas: saga_postgres.storage(saga_settings),
      endpoints:,
      publisher: settings.services,
      telemetry: settings.telemetry,
    )
  let research_worker = jobs.worker(deps)
  let jobs_config =
    grind.new(pog.pool_size(pool, 10))
    |> grind.with_schema(settings.schema)
    // Grind's own migrations run before its consumers poll.
    |> grind.with_startup_migration
    // A short statement deadline allows a short lease (L >= 4D), so an
    // abandoned job is replayed within seconds in the crash test.
    |> grind.with_statement_deadline(duration.milliseconds(1500))
    |> grind.with_unique_lock_wait(duration.milliseconds(200))
    |> grind.with_worker(research_worker)
    |> grind.with_queue(
      queue.new(jobs.queue)
      |> queue.with_poll_interval(duration.milliseconds(50))
      |> queue.with_concurrency(4)
      |> queue.with_lease(duration.milliseconds(6000))
      |> queue.with_shutdown_grace(duration.seconds(2)),
    )

  // The app's own tables exist before the first consumer polls: a job left
  // by the previous version can be due the moment Grind starts.
  use Nil <- result.try(migrate_app(settings))

  // Infrastructure: a Sinal forwarder (http_gun's and Fabric's events),
  // the HTTP client, and Grind with the one pool everything shares.
  use infra <- result.try(
    static_supervisor.new(static_supervisor.RestForOne)
    |> static_supervisor.add(forwarder.supervised(fwd))
    |> static_supervisor.add(http_gun.supervised(http_settings, http_name))
    |> static_supervisor.add(grind.supervised(jobs_config, jobs_name))
    |> static_supervisor.start
    |> result.map_error(string.inspect),
  )
  forwarder.route(telemetry.fabric_prefix(), fwd)
  forwarder.route(telemetry.http_prefix(), fwd)
  let jobs = grind.named(jobs_name)

  // Fabric: the leased run store, supervised.
  use fabric_tree <- result.try(
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(store.supervised(runs))
    |> static_supervisor.start
    |> result.map_error(string.inspect),
  )
  Ok(
    App(
      settings:,
      jobs:,
      db: grind.connection(jobs),
      runs:,
      worker: research_worker,
      deps:,
      http:,
      supervisors: [fabric_tree.pid, infra.pid],
    ),
  )
}

/// Stops the node in dependency order. Grind drains its queue when its
/// supervisor stops it.
pub fn stop(app: App) -> Nil {
  forwarder.unroute(telemetry.fabric_prefix())
  forwarder.unroute(telemetry.http_prefix())
  // static_supervisor has no stop: shut each tree down as its parent would.
  list.each(app.supervisors, shutdown)
}

@external(erlang, "research_agent_ffi", "shutdown")
fn shutdown(supervisor: Pid) -> Nil

// The application API -----------------------------------------------------

/// Records the request and enqueues its job in one transaction. Returns the
/// research id, which is also the job's correlation.
pub fn start_research(app: App, topic: String) -> Result(String, String) {
  let research = correlation.unique()
  let id = correlation.to_string(research)
  let submit = fn(tx) {
    let research_job =
      job.new(app.worker, Research(id, topic))
      |> job.with_correlation(research)
    case grind.submit_in(app.jobs, tx, research_job) {
      Ok(grind.Inserted(handle)) -> db.insert(tx, id, topic, job.id(handle))
      Ok(other) -> Error("unexpected admission: " <> string.inspect(other))
      Error(error) -> Error(grind.describe_submit_error(error))
    }
  }
  use Nil <- result.map(
    pog.transaction(app.db, submit) |> result.map_error(string.inspect),
  )
  events.announce(id, events.Queued)
  id
}

/// Cancels the research's job. The handler sees the cancellation through
/// its job context and cancels the Fabric run, which closes the LLM stream.
pub fn cancel_research(
  app: App,
  id: String,
) -> Result(grind.CancelResult, String) {
  use handle <- result.try(handle(app, id))
  grind.cancel(app.jobs, handle)
  |> result.map_error(grind.describe_cancel_error)
}

pub fn handle(
  app: App,
  id: String,
) -> Result(job.JobHandle(Research, Published, ResearchError), String) {
  use row <- result.try(db.get(app.db, id))
  grind.bind(app.jobs, app.worker, row.job_id)
  |> result.map_error(grind.describe_read_error)
}

/// Waits up to `within` milliseconds for the job's outcome.
pub fn await_outcome(
  app: App,
  id: String,
  within: Int,
) -> Result(grind.Outcome(Published, ResearchError), String) {
  use handle <- result.try(handle(app, id))
  grind.await(app.jobs, handle, within: duration.milliseconds(within))
  |> result.map_error(grind.describe_read_error)
}

pub fn row(app: App, id: String) -> Result(db.Row, String) {
  db.get(app.db, id)
}

/// The run's stored snapshot: its transcript is the checkpointed
/// conversation.
pub fn snapshot(app: App, id: String) -> Result(run.Snapshot, String) {
  use row <- result.try(db.get(app.db, id))
  use run_id <- result.try(option.to_result(row.run_id, "no run yet"))
  let assert Ok(run_id) = run.parse_id(run_id)
  let context = researcher.context(app.http, id)
  use handle <- result.try(
    fabric.open(app.runs, app.deps.agent, context, run_id)
    |> result.map_error(string.inspect),
  )
  fabric.snapshot(handle) |> result.map_error(string.inspect)
}
