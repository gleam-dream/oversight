//// Starts and stops the whole system: scripted provider, Warden client,
//// Grind database and consumer, Relay server and the wisp/mist listener.

import gleam/erlang/process
import gleam/int
import gleam/result
import gleam/string
import grind/postgres
import grind/queue
import grind/registry
import mist
import relay/authorization
import relay/server
import secure_mcp/dev_provider
import secure_mcp/tools.{type ReportWorker}
import secure_mcp/web
import warden
import warden/config
import wisp
import wisp/wisp_mist

pub const client_id = "secure-mcp"

const client_secret = "dev-only-client-secret"

pub type Options {
  Options(
    database_url: String,
    /// Grind polling interval.
    poll_ms: Int,
    /// Endpoint scope every MCP request must carry.
    required_scope: String,
  )
}

pub fn options(database_url: String) -> Options {
  Options(database_url:, poll_ms: 50, required_scope: "reports")
}

pub type Running {
  Running(
    provider: dev_provider.Provider,
    warden: warden.Client,
    database: postgres.Database,
    consumer: queue.Consumer,
    report_worker: ReportWorker,
    listener: process.Pid,
    base_url: String,
    mcp_url: String,
  )
}

pub fn start(options: Options) -> Result(Running, String) {
  let port = dev_provider.free_port()
  let base_url = "http://127.0.0.1:" <> int.to_string(port)
  let mcp_url = base_url <> "/mcp"
  let redirect_uri = base_url <> "/auth/callback"
  let tls_dir = "build/secure_mcp_tls/" <> int.to_string(port)
  use provider <- result.try(dev_provider.start(
    dev_provider.Client(client_id, client_secret, redirect_uri),
    tls_dir,
  ))
  use warden_client <- result.try(start_warden(provider, redirect_uri))
  use #(database, consumer, report_worker) <- result.try(start_jobs(options))
  use registry <- result.try(tools.registry(database, report_worker))
  use protection <- result.try(protection(mcp_url, options.required_scope))
  let context =
    web.Context(
      warden: warden_client,
      mcp: server.server(registry),
      protection:,
      issuer: dev_provider.issuer(provider),
      mcp_url:,
      metadata_url: base_url <> "/.well-known/oauth-protected-resource/mcp",
    )
  let secret_key_base = wisp.random_string(64)
  use started <- result.try(
    wisp_mist.handler(web.handle(_, context), secret_key_base)
    |> mist.new
    |> mist.bind("127.0.0.1")
    |> mist.port(port)
    |> mist.start
    |> result.map_error(fn(e) { "app listener: " <> string.inspect(e) }),
  )
  Ok(Running(
    provider:,
    warden: warden_client,
    database:,
    consumer:,
    report_worker:,
    listener: started.pid,
    base_url:,
    mcp_url:,
  ))
}

fn start_warden(
  provider: dev_provider.Provider,
  redirect_uri: String,
) -> Result(warden.Client, String) {
  let transport =
    config.Transport(
      ..config.default_transport(),
      trust: config.TrustAnchorsPem(dev_provider.ca_pem(provider)),
      destinations: config.AllowLoopbackForTesting,
    )
  use validated <- result.try(
    config.new(
      issuer: dev_provider.issuer(provider),
      client_id:,
      redirect_uri:,
      authentication: config.ClientSecretBasic(config.secret(client_secret)),
    )
    |> config.with_scopes(["reports"])
    |> config.with_transport(transport)
    |> config.validate
    |> result.map_error(fn(e) { "warden config: " <> string.inspect(e) }),
  )
  warden.start(validated)
  |> result.map_error(fn(e) { "warden start: " <> string.inspect(e) })
}

fn start_jobs(
  options: Options,
) -> Result(#(postgres.Database, queue.Consumer, ReportWorker), String) {
  use report_worker <- result.try(tools.report_worker())
  use settings <- result.try(
    postgres.settings(options.database_url)
    |> postgres.validate
    |> result.map_error(describe("grind settings")),
  )
  use database <- result.try(
    postgres.start(settings) |> result.map_error(describe("grind start")),
  )
  use Nil <- result.try(
    postgres.migrate(database) |> result.map_error(describe("grind migrate")),
  )
  use workers <- result.try(
    registry.new(tools.queue)
    |> result.try(registry.register(_, report_worker))
    |> result.map_error(describe("grind registry")),
  )
  use policy <- result.try(
    queue.default_policy()
    |> queue.with_poll_interval(options.poll_ms)
    |> queue.validate_policy
    |> result.map_error(describe("grind policy")),
  )
  use consumer <- result.try(
    queue.start(database, workers, policy)
    |> result.map_error(describe("grind consumer")),
  )
  Ok(#(database, consumer, report_worker))
}

fn protection(
  mcp_url: String,
  scope: String,
) -> Result(authorization.ProtectionConfig, String) {
  use resource <- result.try(
    authorization.resource(mcp_url) |> result.replace_error("empty resource"),
  )
  use scope <- result.try(
    authorization.scope(scope) |> result.replace_error("empty scope"),
  )
  Ok(authorization.protection_config(resource, [scope]))
}

/// Stops everything in reverse order. Must run in the process that called
/// `start`: Grind's consumer accepts `stop` only from its starting process.
pub fn stop(running: Running) -> Nil {
  shutdown(running.listener)
  let _ = queue.stop(running.consumer)
  let _ = postgres.close(running.database)
  warden.stop(running.warden)
  dev_provider.stop(running.provider)
}

fn describe(label: String) -> fn(a) -> String {
  fn(error) { label <> ": " <> string.inspect(error) }
}

@external(erlang, "secure_mcp_dev_ffi", "shutdown")
fn shutdown(pid: process.Pid) -> Nil
