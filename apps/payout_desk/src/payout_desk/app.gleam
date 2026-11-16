//// The composition root: one PostgreSQL pool shared by Grind, Fabric, Saga,
//// the decision record and the application's tables; the workers; the
//// desk's MCP endpoint behind Hellhound bearer verification. It owns every
//// resource it starts and closes each in `stop`.
////
//// Start-up order, and why:
////
//// 1. Name the pool and the Grind runtime: the decision store, the desks,
////    their wakers and the Fabric store are built over those names before
////    anything runs.
//// 2. Migrate every package's tables on a pool of its own, gone before
////    Grind starts: a consumer must not poll while a table its handler
////    needs is missing. Publish the policies.
//// 3. Start Grind (which owns the shared pool) and the leased Fabric store.
//// 4. Sweep: admit a job for every pending wake-up and undelivered
////    settlement notice that has none.
//// 5. Start the identity provider and the MCP listener.
////
//// Fabric's store is `fabric_postgres`, as `research_agent` uses it, and
//// not the in-memory store `support_desk` uses: a run here stays parked
//// while people decide, for an hour or more, across restarts, and the job
//// that resumes it may run on any node. Only a leased database store keeps
//// the parked run and lets any node answer it.

import decisions
import decisions/store as decisions_store
import decisions/vocabulary
import decisions_postgres
import envoy
import fabric/run
import fabric/store as fabric_store
import fabric_postgres
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/otp/static_supervisor
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import grind
import grind/queue
import hellhound
import hellhound/config as hellhound_config
import hellhound/resource
import hellhound/testing as identity
import mist
import payout_desk/agent as payout_agent
import payout_desk/auth
import payout_desk/db
import payout_desk/desk_tools
import payout_desk/desks.{type Desks, Desks}
import payout_desk/domain
import payout_desk/jobs
import payout_desk/provider.{type Provider}
import pog
import relay/authorization
import relay/http as mcp_http
import relay/server
import saga_postgres

pub type Settings {
  Settings(
    database_url: String,
    /// Holds every table of this node's application (a test uses one per
    /// scenario).
    schema: String,
    /// Unique among live VMs that share the database, stable across
    /// restarts.
    node: String,
    /// The payment provider. It is outside the application and outlives it.
    provider: Provider,
    /// The undo window of the payouts the policy accepts on its own, as
    /// policy version 1 publishes it: finance may withdraw them during it.
    /// A version already published keeps its own.
    hold: Duration,
    /// How long a payout may wait for its verdicts.
    validity: Duration,
    /// How far the decision record's clock runs from the database's
    /// (`decisions_postgres.with_clock_offset`). Zero in production; a test
    /// stands an hour later to see an escalation, and delivers its due
    /// wake-up with `deliver_due`.
    record_skew: Duration,
    /// `False`: nothing delivers jobs (a test that restarts the runtime).
    consumers: Bool,
    script: payout_agent.Script,
    /// When the agent's approval request expires: never, in production.
    approval_expiry: run.Timeout,
    provider_timeout_ms: Int,
    /// A fault point after the provider answered a payment, given the pay
    /// job's handler process.
    after_paid: fn(Pid) -> Nil,
    /// A fault point: `True` makes the payout's guard lose its database
    /// connection.
    guard_fault: fn() -> Bool,
    /// A fault point: `True` makes the model's provider refuse a call.
    model_fault: fn() -> Bool,
    /// A fault point after the agent's run parked on its proposal and
    /// before the proposal is admitted.
    before_admit: fn() -> Nil,
  )
}

pub fn settings(
  database_url: String,
  schema schema: String,
  provider provider: Provider,
) -> Settings {
  Settings(
    database_url:,
    schema:,
    node: "payout-1",
    provider:,
    hold: duration.minutes(5),
    validity: duration.hours(48),
    record_skew: duration.seconds(0),
    consumers: True,
    script: payout_agent.Careful,
    approval_expiry: run.Infinity,
    provider_timeout_ms: 1000,
    after_paid: fn(_) { Nil },
    guard_fault: fn() { False },
    model_fault: fn() { False },
    before_admit: fn() { Nil },
  )
}

/// The database address the PostgreSQL helper sets.
pub fn database_url() -> Result(String, Nil) {
  envoy.get("DATABASE_URL")
}

pub type App {
  App(
    settings: Settings,
    db: pog.Connection,
    jobs: grind.Grind,
    deps: jobs.Deps,
    /// The decision store and the wakers its wake-up worker serves.
    store: decisions_postgres.Store,
    wakers: List(decisions_postgres.Waker),
    /// What the start-up sweep admitted.
    swept: decisions_postgres.Swept,
    desks: Desks,
    tools: desk_tools.Deps,
    identity: identity.Provider,
    resource_server: hellhound.Client,
    mcp: mcp_http.Handler(auth.Principal),
    listener: Pid,
    mcp_url: String,
    supervisors: List(Pid),
  )
}

fn pool_config(
  settings: Settings,
  name: process.Name(pog.Message),
) -> Result(pog.Config, String) {
  use config <- result.map(
    pog.url_config(name, settings.database_url)
    |> result.replace_error("invalid DATABASE_URL"),
  )
  config
  |> pog.connection_parameter(
    "search_path",
    "\"" <> settings.schema <> "\",public",
  )
}

fn fabric_settings(
  settings: Settings,
  database: pog.Connection,
) -> Result(fabric_postgres.Settings, String) {
  fabric_postgres.settings(database, node: settings.node)
  |> fabric_postgres.with_lease(duration.seconds(5))
  |> fabric_postgres.with_schema(settings.schema)
  |> result.map_error(string.inspect)
}

fn saga_settings(
  settings: Settings,
  database: pog.Connection,
) -> Result(saga_postgres.Config, String) {
  saga_postgres.config(database)
  |> saga_postgres.with_lease(duration.seconds(2))
  |> saga_postgres.with_schema(settings.schema)
  |> result.map_error(string.inspect)
}

/// The points as published here. Publishing is a write; a version is
/// published once.
fn publish(
  settings: Settings,
  database: pog.Connection,
) -> Result(Nil, String) {
  use Nil <- result.try(
    db.publish(
      database,
      domain.payout_point(validity: settings.validity),
      domain.payout_policy(version: 1, hold: settings.hold),
    )
    |> result.map_error(db.describe),
  )
  db.publish(database, domain.risk_point(), domain.risk_policy())
  |> result.map_error(db.describe)
}

fn migrate(settings: Settings) -> Result(Nil, String) {
  let name = process.new_name("payout_desk_migrations")
  use config <- result.try(pool_config(settings, name))
  use started <- result.try(
    pog.start(pog.pool_size(config, 1)) |> result.map_error(string.inspect),
  )
  let database = pog.named_connection(name)
  let migrated = {
    use Nil <- result.try(
      db.migrate(database, settings.schema) |> result.map_error(db.describe),
    )
    use Nil <- result.try(
      decisions_postgres.migrate(database)
      |> result.map_error(decisions_postgres.describe_migrate_error),
    )
    use fabric <- result.try(fabric_settings(settings, database))
    use Nil <- result.try(
      fabric_postgres.migrate(fabric) |> result.map_error(string.inspect),
    )
    use sagas <- result.try(saga_settings(settings, database))
    use Nil <- result.try(
      saga_postgres.migrate(sagas)
      |> result.map_error(saga_postgres.describe_migrate_error),
    )
    publish(settings, database)
  }
  shutdown(started.pid)
  migrated
}

pub fn start(settings: Settings) -> Result(App, String) {
  let pool_name = process.new_name("payout_desk_pool")
  let jobs_name = process.new_name("payout_desk_jobs")
  let runs_name = process.new_name("payout_desk_runs")
  use pool <- result.try(pool_config(settings, pool_name))
  let database = pog.named_connection(pool_name)

  // The decision record: a store over the Grind runtime that is not
  // started yet, desks over its port.
  let store =
    decisions_postgres.new(grind.named(jobs_name))
    |> decisions_postgres.following(domain.payout_point_name)
    |> decisions_postgres.with_clock_offset(settings.record_skew)
  let desks =
    Desks(
      port: decisions_postgres.port(store),
      validity: settings.validity,
      guard_fault: settings.guard_fault,
    )
  let payout_desk = fn() { desks.payout(desks) }
  let wakers = [
    decisions.waker(payout_desk()),
    decisions.waker(desks.risk(desks)),
  ]

  use fabric <- result.try(fabric_settings(settings, database))
  use runs <- result.try(
    fabric_postgres.store(runs_name, fabric) |> result.map_error(string.inspect),
  )
  use sagas <- result.try(saga_settings(settings, database))
  // Built once: the agent and the job that answers its approvals share it.
  let approvers = jobs.approvers(database, payout_desk)
  use agent <- result.try(payout_agent.build(
    approvers,
    settings.script,
    settings.approval_expiry,
    settings.model_fault,
  ))
  let deps =
    jobs.Deps(
      jobs: grind.named(jobs_name),
      runs:,
      agent:,
      approvers:,
      desks:,
      provider: settings.provider,
      sagas: saga_postgres.storage(sagas),
      provider_timeout_ms: settings.provider_timeout_ms,
      after_paid: settings.after_paid,
      before_admit: settings.before_admit,
    )
  let lanes = fn(name) {
    queue.new(name)
    |> queue.with_poll_interval(duration.milliseconds(50))
    |> queue.with_concurrency(4)
    |> queue.with_lease(duration.seconds(6))
    |> queue.with_shutdown_grace(duration.seconds(2))
  }
  let configured =
    grind.new(pog.pool_size(pool, 20))
    |> grind.with_schema(settings.schema)
    |> grind.with_startup_migration
    |> grind.with_statement_deadline(duration.milliseconds(1500))
    |> grind.with_unique_lock_wait(duration.milliseconds(200))
    |> grind.with_worker(jobs.agent_worker(deps))
    |> grind.with_worker(jobs.pay_worker(deps))
    |> grind.with_worker(jobs.reconcile_worker(deps))
    |> grind.with_worker(jobs.tell_worker(deps))
    |> grind.with_worker(decisions_postgres.wake_worker(store, wakers))
    |> grind.with_worker(
      decisions_postgres.settlement_worker(store, [jobs.follower(deps)]),
    )
    |> grind.with_queue(lanes(jobs.queue))
    |> grind.with_queue(lanes(decisions_postgres.default_queue))
    |> grind.without_pruner
  let configured = case settings.consumers {
    True -> configured
    False -> grind.without_consumers(configured)
  }

  use Nil <- result.try(migrate(settings))

  use infrastructure <- result.try(
    static_supervisor.new(static_supervisor.RestForOne)
    |> static_supervisor.add(grind.supervised(configured, jobs_name))
    |> static_supervisor.add(fabric_store.supervised(runs))
    |> static_supervisor.start
    |> result.map_error(string.inspect),
  )
  let jobs_handle = grind.named(jobs_name)
  // Every pending wake-up and undelivered notice gets a job, whatever
  // became of the one it had (a job pruned, lost or ended).
  use swept <- result.try(
    case decisions_postgres.sweep(store, grind.connection(jobs_handle)) {
      Ok(swept) -> Ok(swept)
      Error(error) -> {
        shutdown(infrastructure.pid)
        Error("sweep: " <> decisions_store.describe(error))
      }
    },
  )

  let port = free_port()
  let mcp_url = "http://127.0.0.1:" <> int.to_string(port) <> "/mcp"
  let tools = desk_tools.Deps(db: database, desk: payout_desk)
  let started = {
    use provider <- result.try(
      identity.provider_options()
      |> identity.with_access_token_audiences([mcp_url])
      |> identity.start_provider
      |> result.map_error(fn(e) { "identity: " <> string.inspect(e) }),
    )
    use resource_server <- result.try(
      hellhound.new(
        hellhound_config.resource_server(issuer: identity.issuer(provider))
        |> identity.trusting(provider),
      )
      |> result.map_error(hellhound.describe_start_error),
    )
    use _ <- result.try(
      hellhound.start(resource_server)
      |> result.map_error(hellhound.describe_start_error),
    )
    use protected <- result.try(
      authorization.protected_resource(mcp_url)
      |> result.replace_error("invalid resource " <> mcp_url),
    )
    use scope <- result.try(
      authorization.scope(auth.scope) |> result.replace_error("empty scope"),
    )
    let protection =
      authorization.protection(protected, [scope])
      |> authorization.with_authorization_servers([identity.issuer(provider)])
    use mcp <- result.try(
      server.new(desk_tools.tools(tools))
      |> mcp_http.new_protected(
        auth.jwt_verifier(resource.new(resource_server, audience: mcp_url)),
        protection,
        fn(_request, grant) { Ok(authorization.grant_principal(grant)) },
      )
      |> mcp_http.handler
      |> result.map_error(mcp_http.describe_start_error),
    )
    use listener <- result.try(
      mcp_http.mist_handler(mcp)
      |> mist.new
      |> mist.bind("127.0.0.1")
      |> mist.port(port)
      |> mist.start
      |> result.map_error(fn(e) { "listener: " <> string.inspect(e) }),
    )
    Ok(#(provider, resource_server, mcp, listener.pid))
  }
  case started {
    Error(detail) -> {
      shutdown(infrastructure.pid)
      Error(detail)
    }
    Ok(#(provider, resource_server, mcp, listener)) ->
      Ok(
        App(
          settings:,
          db: database,
          jobs: jobs_handle,
          deps:,
          store:,
          wakers:,
          desks:,
          tools:,
          identity: provider,
          resource_server:,
          mcp:,
          listener:,
          mcp_url:,
          swept:,
          supervisors: [infrastructure.pid],
        ),
      )
  }
}

/// Stop everything this application started, in reverse order. Grind
/// drains its running jobs, and the Fabric store hands its runs off.
pub fn stop(app: App) -> Nil {
  shutdown(app.listener)
  mcp_http.stop(app.mcp)
  hellhound.stop(app.resource_server)
  identity.stop_provider(app.identity)
  list.each(app.supervisors, shutdown)
}

/// An access token for `subject`, for the desk's endpoint, as the identity
/// provider issues it when they sign in.
pub fn token(app: App, subject: String) -> String {
  identity.access_token(subject)
  |> identity.with_audiences([app.mcp_url])
  |> identity.with_scopes([auth.scope])
  |> identity.issue_access_token(app.identity, _)
}

/// The payout desk over this application's store.
pub fn payout_desk(app: App) -> decisions.Desk(domain.Payout, pog.Connection) {
  desks.payout(app.desks)
}

/// Deliver now, through the wake-up worker's own code path, every wake-up
/// due on the decision store's clock: for an operator, or a test whose
/// store clock runs ahead (`record_skew`), since a wake-up's Grind job waits
/// on the database's clock. Safe beside the worker.
pub fn deliver_due(app: App, limit: Int) -> Result(Int, String) {
  decisions_postgres.deliver_due(app.store, app.db, app.wakers, limit:)
  |> result.map_error(decisions_store.describe)
}

/// Suspend a seller's account for review. In the same transaction the
/// suspension supersedes every payout to them that is still pending: one
/// expected and not yet proposed, one waiting for finance, and one on hold.
/// Nothing of theirs is released; each is told as stopped.
pub fn suspend_seller(
  app: App,
  seller: String,
) -> Result(decisions.Supersession(domain.Payout), String) {
  decisions_postgres.transaction_with(app.db, fn(tx) {
    use Nil <- result.try(
      db.set_seller_status(tx, seller, "suspended")
      |> result.map_error(fn(e) { decisions_postgres.Own(db.describe(e)) }),
    )
    decisions.happened(
      payout_desk(app),
      tx,
      domain.seller_suspended,
      about: vocabulary.Subject("seller", seller),
    )
    |> decisions_postgres.desk
  })
  |> result.map_error(fn(failure) {
    case failure {
      decisions_postgres.LibraryFailed(failure) ->
        decisions_postgres.describe(failure)
      decisions_postgres.OwnFailed(detail) -> detail
    }
  })
}

/// Record a seller's request and queue its agent.
pub fn request(
  app: App,
  request: domain.Request,
  requested_by requested_by: String,
) -> Result(Nil, String) {
  jobs.request(app.deps, app.db, request, requested_by:)
}

/// The occurrence a request's gated call was admitted as, waiting up to
/// `within` milliseconds for the agent to propose.
pub fn occurrence_of(
  app: App,
  request: String,
  within: Int,
) -> Result(String, String) {
  case db.occurrence_of(app.db, request) {
    Ok(option.Some(id)) -> Ok(id)
    Ok(None) | Error(_) if within > 0 -> {
      process.sleep(50)
      occurrence_of(app, request, within - 50)
    }
    Ok(None) -> Error("the agent has not proposed yet")
    Error(error) -> Error(db.describe(error))
  }
}

@external(erlang, "payout_desk_ffi", "free_port")
fn free_port() -> Int

@external(erlang, "payout_desk_ffi", "shutdown")
fn shutdown(pid: Pid) -> Nil
