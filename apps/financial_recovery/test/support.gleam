import envoy
import financial_recovery/coordinator
import financial_recovery/payments
import financial_recovery/provider
import gleam/erlang/process
import gleam/int
import gleam/time/duration
import grind
import grind/queue
import http_gun
import http_gun/config
import http_gun/destination
import pog
import saga_postgres
import scripted_provider

pub type Fixture {
  Fixture(
    jobs: grind.Grind,
    deps: coordinator.Deps,
    peer: scripted_provider.Provider,
    notices: process.Subject(String),
  )
}

pub fn with_runtime(
  schema: String,
  mode: scripted_provider.Mode,
  body: fn(Fixture) -> a,
) -> a {
  let assert Ok(url) = envoy.get("DATABASE_URL")
  let notices = process.new_subject()
  let peer = scripted_provider.start(mode, notices)
  let authority = "127.0.0.1:" <> int.to_string(peer.port)
  let assert Ok(http) =
    http_gun.start(
      config.default()
      |> config.with_destination(
        destination.loopback_only() |> destination.only_hosts([authority]),
      )
      |> config.with_request_timeout(config.After(duration.seconds(20))),
    )
  let pool_name = process.new_name("financial_pool")
  let assert Ok(pool) = pog.url_config(pool_name, url)
  let pool =
    pool
    |> pog.connection_parameter("search_path", schema <> ",public")
    |> pog.pool_size(5)
  // Migrations precede queue polling; startup uses a separate temporary pool.
  let assert Ok(migrations) = pog.start(pool)
  let connection = pog.named_connection(pool_name)
  let assert Ok(_) =
    pog.query("CREATE SCHEMA " <> schema) |> pog.execute(connection)
  let assert Ok(Nil) = payments.migrate(connection)
  let assert Ok(saga_config) =
    saga_postgres.config(connection) |> saga_postgres.with_schema(schema)
  let assert Ok(Nil) = saga_postgres.migrate(saga_config)
  shutdown(migrations.pid)
  let deps =
    coordinator.Deps(
      connection,
      saga_postgres.storage(saga_config),
      provider.Provider(http, "http://" <> authority),
    )
  let settings =
    grind.new(pool)
    |> grind.with_schema(schema)
    |> grind.with_startup_migration
    |> grind.with_worker(coordinator.definition(deps))
    |> grind.with_statement_deadline(duration.milliseconds(1500))
    |> grind.with_unique_lock_wait(duration.milliseconds(100))
    |> grind.with_queue(
      queue.new("payments")
      |> queue.with_poll_interval(duration.milliseconds(20))
      |> queue.with_concurrency(1)
      |> queue.with_lease(duration.seconds(6))
      |> queue.with_shutdown_grace(duration.seconds(1)),
    )
  let assert Ok(jobs) =
    grind.start(settings, process.new_name("financial_jobs"))
  let answer = body(Fixture(jobs, deps, peer, notices))
  let assert Ok(_) = grind.stop(jobs)
  http_gun.stop(http)
  scripted_provider.stop(peer.pid)
  answer
}

@external(erlang, "financial_fixture", "shutdown")
fn shutdown(pid: process.Pid) -> Nil
