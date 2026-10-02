//// One node of the research service: the wiring of every package, and the
//// application API (`start_research`, `cancel_research`, `status`).

import fabric
import fabric/run
import fabric/store.{type Store}
import fabric_postgres
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor
import gleam/result
import gleam/string
import grind/job
import grind/postgres
import grind/queue
import grind/registry
import grind/worker.{type Worker}
import http_gun
import http_gun/config as http_config
import http_gun/destination
import pog
import research_agent/db
import research_agent/domain.{type Published, type Research, Research}
import research_agent/jobs.{type ResearchError}
import research_agent/researcher
import research_agent/saga_store
import research_agent/telemetry.{type Telemetry}
import sinal/correlation
import sinal/forwarder

pub type Settings {
  Settings(
    database_url: String,
    /// Unique among live VMs that share the database, stable across restarts.
    node: String,
    /// Isolates Grind's and Fabric's tables (tests use one per scenario).
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
    grind: postgres.Database,
    consumer: queue.Consumer,
    db: pog.Connection,
    runs: Store,
    worker: Worker(Research, Published, ResearchError),
    deps: jobs.Deps,
    http: http_gun.Client,
    llm: http_gun.Client,
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

/// The loopback policy every client here needs: http_gun admits public
/// destinations only by default. `allow_loopback` admits loopback; the
/// allowlist that confines the clients to the scripted services has no
/// helper, so it stays a nested record update.
fn loopback(
  deadline_ms: Int,
  observations: Option(forwarder.Forwarder),
) -> http_config.Config {
  let config = http_config.default() |> http_config.allow_loopback
  http_config.Config(
    ..config,
    deadline_ms:,
    observations:,
    destination: destination.Policy(
      ..config.destination,
      allowed_hosts: Some(["127.0.0.1"]),
    ),
  )
}

pub fn start(settings: Settings) -> Result(App, String) {
  // Infrastructure: a Sinal forwarder (http_gun observations, Fabric's
  // routed events) and the app's pog pool (Fabric's store, the saga
  // checkpoints, the research index). Grind opens its own pool.
  let pool_name = process.new_name("research_pool")
  let fwd =
    forwarder.new(process.new_name("research_events"))
    |> forwarder.with_capacity(4096)
  use pool_config <- result.try(
    pog.url_config(pool_name, settings.database_url)
    |> result.replace_error("invalid DATABASE_URL"),
  )
  use infra <- result.try(
    static_supervisor.new(static_supervisor.RestForOne)
    |> static_supervisor.add(forwarder.supervised(fwd))
    |> static_supervisor.add(pog.supervised(pog.pool_size(pool_config, 5)))
    |> static_supervisor.start
    |> result.map_error(string.inspect),
  )
  forwarder.route(telemetry.fabric_prefix(), fwd)
  let database = pog.named_connection(pool_name)
  use Nil <- result.try(db.migrate(database))

  // Fabric: a leased PostgreSQL store, supervised.
  use fabric_settings <- result.try(
    fabric_postgres.settings(database, node: settings.node)
    |> fabric_postgres.with_lease(settings.fabric_lease_ms)
    |> fabric_postgres.with_schema(settings.schema)
    |> result.map_error(string.inspect),
  )
  use Nil <- result.try(
    fabric_postgres.migrate(fabric_settings) |> result.map_error(string.inspect),
  )
  use runs <- result.try(
    fabric_postgres.store(process.new_name("research_runs"), fabric_settings)
    |> result.map_error(string.inspect),
  )
  use fabric_tree <- result.try(
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(store.supervised(runs))
    |> static_supervisor.start
    |> result.map_error(string.inspect),
  )

  // HTTP: one client for tools and the publisher, one for the provider.
  let observations = case settings.telemetry {
    Some(_) -> Some(fwd)
    None -> None
  }
  use http <- result.try(
    http_gun.start(loopback(5000, observations))
    |> result.map_error(string.inspect),
  )
  use llm <- result.try(
    http_gun.start(loopback(120_000, observations))
    |> result.map_error(string.inspect),
  )
  let endpoints = endpoints(settings.services)
  use agent <- result.try(
    researcher.build(llm, endpoints) |> result.map_error(string.inspect),
  )

  // Grind: its own pool (it cannot use ours), the research worker, a consumer.
  use grind_settings <- result.try(
    postgres.settings(settings.database_url)
    |> postgres.with_pool_size(4)
    |> postgres.with_schema(settings.schema)
    // A short statement deadline allows a short lease (L >= 4D), so an
    // abandoned job is quarantined within seconds in the crash test.
    |> postgres.with_statement_deadline(1500)
    |> postgres.with_unique_lock_wait(200)
    |> postgres.validate
    |> result.map_error(string.inspect),
  )
  use grind <- result.try(
    postgres.start(grind_settings) |> result.map_error(string.inspect),
  )
  use Nil <- result.try(
    postgres.migrate(grind) |> result.map_error(string.inspect),
  )
  let deps =
    jobs.Deps(
      db: database,
      runs:,
      agent:,
      http:,
      // One owner token per incarnation: a restarted VM waits for the lease.
      sagas: saga_store.new(
        database,
        settings.node <> "/" <> int.to_string(int.random(1_000_000_000)),
        10_000,
      ),
      endpoints:,
      publisher: settings.services,
      telemetry: settings.telemetry,
    )
  let research_worker = jobs.worker(deps)
  use workers <- result.try(
    registry.new(jobs.queue)
    |> result.try(registry.register(_, research_worker))
    |> result.map_error(string.inspect),
  )
  use policy <- result.try(
    queue.default_policy()
    |> queue.with_poll_interval(50)
    |> queue.with_maximum_concurrency(4)
    |> queue.with_lease_duration(6000)
    |> queue.validate_policy
    |> result.map_error(string.inspect),
  )
  use consumer <- result.try(
    queue.start(grind, workers, policy) |> result.map_error(string.inspect),
  )
  Ok(
    App(
      settings:,
      grind:,
      consumer:,
      db: database,
      runs:,
      worker: research_worker,
      deps:,
      http:,
      llm:,
      supervisors: [fabric_tree.pid, infra.pid],
    ),
  )
}

/// Stops the node in dependency order. The consumer must be stopped by the
/// process that started it.
pub fn stop(app: App) -> Nil {
  let _ = queue.stop(app.consumer)
  let _ = postgres.close(app.grind)
  let _ = http_gun.stop(app.http)
  let _ = http_gun.stop(app.llm)
  forwarder.unroute(telemetry.fabric_prefix())
  // static_supervisor has no stop: shut each tree down as its parent would.
  list.each(app.supervisors, shutdown)
}

@external(erlang, "research_agent_ffi", "shutdown")
fn shutdown(supervisor: Pid) -> Nil

// The application API -----------------------------------------------------

/// Records the request and enqueues its job. Returns the research id.
pub fn start_research(app: App, topic: String) -> Result(String, String) {
  let id = correlation.to_string(correlation.unique())
  use Nil <- result.try(db.insert(app.db, id, topic))
  use handle <- result.try(
    postgres.submit(app.grind, jobs.queue, app.worker, Research(id, topic))
    |> result.map_error(string.inspect),
  )
  let job_id = job.id_value(handle)
  telemetry.bind_job(app.settings.telemetry, job_id, id)
  use Nil <- result.map(db.set_job(app.db, id, job_id))
  id
}

pub type Cancellation {
  Cancellation(job: postgres.CancellationResult, run: Option(run.Status))
}

/// Cancels the job and, because a Grind handler cannot learn of its job's
/// cancellation, the Fabric run too: that kills its model call, which
/// closes the LLM stream.
pub fn cancel_research(app: App, id: String) -> Result(Cancellation, String) {
  use job <- result.try(cancel_job(app, id))
  use row <- result.try(db.get(app.db, id))
  case row.run_id {
    None -> Ok(Cancellation(job, None))
    Some(run_id) -> {
      let assert Ok(run_id) = run.parse_id(run_id)
      fabric.cancel_stored(app.runs, run_id)
      |> result.map(fn(status) { Cancellation(job, Some(status)) })
      |> result.map_error(string.inspect)
    }
  }
}

/// Grind's half of cancellation alone (what an operator tool would call).
pub fn cancel_job(
  app: App,
  id: String,
) -> Result(postgres.CancellationResult, String) {
  use handle <- result.try(handle(app, id))
  postgres.cancel(app.grind, handle) |> result.map_error(string.inspect)
}

pub fn handle(
  app: App,
  id: String,
) -> Result(job.JobHandle(Research, Published, ResearchError), String) {
  use row <- result.try(db.get(app.db, id))
  use job_id <- result.try(option.to_result(row.job_id, "no job yet"))
  postgres.bind_handle(app.grind, app.worker, job_id)
  |> result.map_error(string.inspect)
}

pub fn outcome(
  app: App,
  id: String,
) -> Result(job.Outcome(Published, ResearchError), String) {
  use handle <- result.try(handle(app, id))
  postgres.outcome(app.grind, handle) |> result.map_error(string.inspect)
}

/// Polls the job's outcome until it is no longer pending.
pub fn await_outcome(
  app: App,
  id: String,
  within: Int,
) -> Result(job.Outcome(Published, ResearchError), String) {
  case outcome(app, id) {
    Ok(job.Pending(_)) if within > 0 -> {
      process.sleep(50)
      await_outcome(app, id, within - 50)
    }
    other -> other
  }
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

pub fn recover_abandoned(app: App) -> Result(Int, String) {
  jobs.recover_abandoned(app.grind, app.worker, app.db, app.settings.node)
}
