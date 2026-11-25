//// The composition root. It owns one pool (which Grind builds from the
//// application's `pog.Config` and which also serves the clinic's tables
//// and `decisions_postgres`), the Grind runtime with every worker, one
//// HTTP Gun client for the two providers, the telemetry collector, the
//// Hellhound client staff sign in through, and the desk's HTTP server.
//// `stop` closes all of them.
////
//// Start-up order follows `decisions_postgres`: the tables are migrated on
//// a pool of their own before any worker polls (in production a deploy
//// step with a role that may own DDL); the store is built from
//// `grind.named` before the runtime starts and the desk over the store's
//// port; the workers are registered and Grind starts; then `sweep` admits
//// a job for every pending wake-up and undelivered settlement notice that
//// has none, such as one whose job was lost or pruned.

import clinic_registration/access.{type ChannelSecret, type SignIn}
import clinic_registration/desk
import clinic_registration/domain.{type Inbound, type Registration}
import clinic_registration/jobs
import clinic_registration/llm
import clinic_registration/messaging
import clinic_registration/owner.{type Owner}
import clinic_registration/store
import clinic_registration/telemetry
import clinic_registration/web
import decisions.{type Desk}
import decisions/store as port
import decisions_postgres
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/duration.{type Duration}
import grind
import grind/queue
import grind/worker.{type Worker}
import hellhound
import http_gun
import http_gun/config as http_config
import http_gun/destination
import pog
import wisp

pub type Config {
  Config(
    database_url: String,
    pool_size: Int,
    /// The LLM provider's root and the messaging provider's root.
    llm_base: String,
    messaging_base: String,
    /// The loopback ports the provider client may reach.
    provider_ports: List(Int),
    /// How long one model call may take, and one messaging request.
    model_deadline: Duration,
    messaging_deadline: Duration,
    retry_after: Duration,
    max_attempts: Int,
    reconcile_after: Duration,
    configuration: llm.Configuration,
    /// Added to the store's clock (`decisions_postgres.with_clock_offset`).
    /// Production leaves it at zero; a test stands later in time with it.
    clock_offset: Duration,
    after_model: fn(String) -> Nil,
    /// Grind's attempt lease: how long a killed attempt blocks its replay.
    lease: Duration,
    /// The Grind schema; a restart reuses it.
    jobs_schema: String,
    /// The loopback port the desk listens on; 0 picks a free one. With
    /// sign-in configured it is the port of the relying party's redirect
    /// URI, which the provider must know before the listener binds.
    port: Int,
    /// How staff sign in to the desk and who is staff. `None`, the
    /// default, refuses every desk request.
    sign_in: Option(SignIn),
    /// The messaging channel's signing secret. `None`, the default,
    /// refuses every webhook delivery.
    channel: Option(ChannelSecret),
  )
}

pub fn default_config(
  database_url database_url: String,
  llm_base llm_base: String,
  messaging_base messaging_base: String,
  provider_ports provider_ports: List(Int),
) -> Config {
  Config(
    database_url:,
    pool_size: 10,
    llm_base:,
    messaging_base:,
    provider_ports:,
    model_deadline: duration.seconds(2),
    messaging_deadline: duration.milliseconds(400),
    retry_after: duration.milliseconds(200),
    max_attempts: 4,
    reconcile_after: duration.milliseconds(300),
    configuration: llm.first(),
    clock_offset: duration.seconds(0),
    after_model: fn(_) { Nil },
    lease: duration.seconds(6),
    jobs_schema: "clinic_jobs",
    port: 0,
    sign_in: None,
    channel: None,
  )
}

pub type App {
  App(
    db: pog.Connection,
    jobs: grind.Grind,
    desk: Desk(Registration, pog.Connection),
    /// The decision record's store, for its queue and wake-up functions.
    records: decisions_postgres.Store,
    /// What the start-up `sweep` admitted.
    swept: decisions_postgres.Swept,
    env: jobs.Env,
    register: Worker(String, String, String),
    http: http_gun.Client,
    collector: telemetry.Collector,
    server: Owner,
    port: Int,
  )
}

pub fn start(config: Config) -> Result(App, String) {
  let pool_name = process.new_name("clinic_pool")
  use pool_config <- result.try(
    pog.url_config(pool_name, config.database_url)
    |> result.replace_error("the database URL is not valid"),
  )
  use Nil <- result.try(migrate(config.database_url))
  let jobs_name = process.new_name("clinic_jobs")
  let grind_handle = grind.named(jobs_name)
  let store =
    decisions_postgres.new(grind_handle)
    |> decisions_postgres.following(domain.point_name)
    |> decisions_postgres.with_name("clinic_registration")
    |> decisions_postgres.with_clock_offset(config.clock_offset)
  let registration = desk.new(over: decisions_postgres.port(store))
  use http <- result.try(
    http_gun.start(
      http_config.default()
      |> http_config.with_destination(
        destination.loopback_only()
        |> destination.only_hosts(
          list.map(config.provider_ports, fn(port) {
            "127.0.0.1:" <> int.to_string(port)
          }),
        ),
      )
      |> http_config.with_label("providers"),
    )
    |> result.map_error(http_gun.describe_start_error),
  )
  let env =
    jobs.Env(
      jobs: grind_handle,
      desk: registration,
      configuration: config.configuration,
      provider: llm.provider(config.llm_base, config.model_deadline),
      llm_client: http,
      messaging: messaging.Messaging(
        client: http,
        base_url: config.messaging_base,
        deadline: config.messaging_deadline,
      ),
      retry_after: config.retry_after,
      max_attempts: config.max_attempts,
      reconcile_after: config.reconcile_after,
      after_model: config.after_model,
    )
  let register = jobs.register_worker(env)
  let confirm = jobs.confirm_worker(env)
  let queue = fn(name) {
    queue.new(name)
    |> queue.with_concurrency(4)
    |> queue.with_poll_interval(duration.milliseconds(50))
    |> queue.with_lease(config.lease)
    |> queue.with_shutdown_grace(duration.seconds(2))
  }
  let configured =
    grind.new(pog.pool_size(pool_config, config.pool_size))
    |> grind.with_worker(register)
    |> grind.with_worker(confirm)
    |> grind.with_worker(
      decisions_postgres.wake_worker(store, [decisions.waker(registration)]),
    )
    |> grind.with_worker(
      decisions_postgres.settlement_worker(store, [jobs.follower(env, confirm)]),
    )
    |> grind.with_queue(queue(jobs.queue))
    |> grind.with_queue(queue(decisions_postgres.default_queue))
    |> grind.with_statement_deadline(duration.milliseconds(1500))
    |> grind.with_unique_lock_wait(duration.milliseconds(250))
    |> grind.with_schema(config.jobs_schema)
    |> grind.with_startup_migration
  use _ <- result.try(
    grind.start(configured, jobs_name)
    |> result.map_error(grind.describe_start_error),
  )
  let db = grind.connection(grind_handle)
  let prepared = {
    use swept <- result.try(
      decisions_postgres.sweep(store, db)
      |> result.map_error(port.describe),
    )
    use Nil <- result.try(first_policy(db))
    Ok(swept)
  }
  let collector = telemetry.start()
  let admit = fn(message: Inbound) { jobs.admit(env, db, message, register) }
  let served = {
    use swept <- result.try(prepared)
    let secret = wisp.random_string(64)
    // The Hellhound client is started by the owner, so it stops with the
    // listener that uses it.
    owner.start(fn() {
      use sign_in <- result.try(start_sign_in(config.sign_in))
      web.start(
        web.Routes(
          db:,
          desk: registration,
          admit:,
          sign_in:,
          channel: config.channel,
        ),
        config.port,
        secret,
      )
    })
    |> result.map(fn(started) { #(started, swept) })
  }
  case served {
    Ok(#(#(port, server), swept)) ->
      Ok(App(
        db:,
        jobs: grind_handle,
        desk: registration,
        records: store,
        swept:,
        env:,
        register:,
        http:,
        collector:,
        server:,
        port:,
      ))
    // A failed boot stops what already started, so no worker keeps polling.
    Error(reason) -> {
      let _ = grind.stop(grind_handle)
      http_gun.stop(http)
      telemetry.stop(collector)
      Error(reason)
    }
  }
}

/// Build and start the Hellhound client the desk signs staff in through.
fn start_sign_in(
  sign_in: Option(SignIn),
) -> Result(Option(web.SignIn), String) {
  case sign_in {
    None -> Ok(None)
    Some(access.SignIn(relying_party:, staff:)) -> {
      let describe = fn(error) {
        "sign-in: " <> hellhound.describe_start_error(error)
      }
      use client <- result.try(
        hellhound.new(relying_party) |> result.map_error(describe),
      )
      use Nil <- result.try(
        hellhound.start(client) |> result.map_error(describe),
      )
      Ok(Some(web.SignIn(client:, staff:)))
    }
  }
}

/// Bring the record's tables and the clinic's own up to date, on a pool of
/// their own that is closed afterwards, before Grind starts polling.
fn migrate(url: String) -> Result(Nil, String) {
  use config <- result.try(
    pog.url_config(process.new_name("clinic_migrate"), url)
    |> result.replace_error("the database URL is not valid"),
  )
  owner.start(fn() {
    use started <- result.try(
      pog.start(pog.pool_size(config, 1))
      |> result.replace_error("no database to migrate"),
    )
    use Nil <- result.try(
      decisions_postgres.migrate(started.data)
      |> result.map_error(decisions_postgres.describe_migrate_error),
    )
    store.migrate(started.data)
  })
  |> result.map(fn(migrated) { owner.stop(migrated.1) })
}

/// Publish version 1 when no version is stored yet.
fn first_policy(db: pog.Connection) -> Result(Nil, String) {
  case store.policy_versions(db, domain.point_name) {
    Error(error) -> Error(store.describe(error))
    Ok([_, ..]) -> Ok(Nil)
    Ok([]) ->
      desk.publish(db, domain.always_ask())
      |> result.replace_error("policy version 1 could not be published")
  }
}

/// Stop everything `start` started. Grind drains its queues and closes the
/// pool.
pub fn stop(app: App) -> Nil {
  owner.stop(app.server)
  let _ = grind.stop(app.jobs)
  http_gun.stop(app.http)
  telemetry.stop(app.collector)
}

/// Deliver an inbound message, as the channel's webhook does.
pub fn admit(app: App, message: Inbound) -> Result(jobs.Admission, String) {
  jobs.admit(app.env, app.db, message, app.register)
}

/// The desk's HTTP root.
pub fn base_url(app: App) -> String {
  "http://127.0.0.1:" <> int.to_string(app.port)
}
