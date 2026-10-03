//// Starts and stops the whole system: scripted provider, Warden clients,
//// Grind runtime, Relay endpoint and the one mist listener that serves both
//// the wisp routes and `/mcp`.

import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/int
import gleam/option.{type Option, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import grind
import grind/queue
import mist
import pog
import relay/authorization
import relay/http as mcp_http
import relay/server
import secure_mcp/auth.{type Principal}
import secure_mcp/tools.{type ReportWorker}
import secure_mcp/web
import sinal/correlation.{type Correlation}
import warden
import warden/config
import warden/resource
import warden/testing
import wisp
import wisp/wisp_mist

pub const client_id = "secure-mcp"

/// The scripted provider's client secret.
pub const client_secret = "dev-only-client-secret"

/// How `/mcp` verifies a bearer token.
pub type Verification {
  /// Local RFC 9068 validation with `warden/resource` (the default).
  LocalJwt
  /// RFC 7662 introspection with `warden.introspect`.
  Introspection
}

pub type Options {
  Options(
    database_url: String,
    /// How often Grind polls its queue.
    poll_interval: duration.Duration,
    /// Endpoint scope every MCP request must carry.
    required_scope: String,
    verification: Verification,
  )
}

pub fn options(database_url: String) -> Options {
  Options(
    database_url:,
    poll_interval: duration.milliseconds(50),
    required_scope: "reports",
    verification: LocalJwt,
  )
}

pub type Running {
  Running(
    provider: testing.Provider,
    warden: warden.Client,
    resource_server: warden.Client,
    jobs: grind.Grind,
    report_worker: ReportWorker,
    mcp: mcp_http.Handler(Principal),
    listener: process.Pid,
    base_url: String,
    mcp_url: String,
  )
}

pub fn start(options: Options) -> Result(Running, String) {
  let port = free_port()
  let base_url = "http://127.0.0.1:" <> int.to_string(port)
  let mcp_url = base_url <> "/mcp"
  use provider <- result.try(
    testing.provider_options()
    |> testing.with_client(client_id:, secret: client_secret)
    |> testing.with_access_token_audiences([mcp_url])
    |> testing.start_provider
    |> result.map_error(fn(e) { "provider: " <> string.inspect(e) }),
  )
  let issuer = testing.issuer(provider)
  use warden_client <- result.try(start_warden(
    testing.config(provider, base_url <> "/auth/callback")
    |> config.with_scopes([options.required_scope]),
  ))
  use resource_server <- result.try(start_warden(
    config.resource_server(issuer:) |> testing.trusting(provider),
  ))
  let report_worker = tools.report_worker()
  use jobs <- result.try(start_jobs(options, report_worker))
  let verifier = case options.verification {
    LocalJwt ->
      auth.jwt_verifier(resource.new(resource_server, audience: mcp_url))
    Introspection -> auth.introspection_verifier(warden_client)
  }
  use resource <- result.try(
    authorization.protected_resource(mcp_url)
    |> result.replace_error("invalid resource " <> mcp_url),
  )
  use scope <- result.try(
    authorization.scope(options.required_scope)
    |> result.replace_error("empty scope"),
  )
  let protection =
    authorization.protection(resource, [scope])
    |> authorization.with_authorization_servers([issuer])
  use mcp <- result.try(
    server.new(tools.tools(jobs, report_worker))
    |> mcp_http.new_protected(verifier, protection, fn(_request, grant) {
      Ok(authorization.grant_principal(grant))
    })
    |> mcp_http.with_correlation(request_correlation)
    |> mcp_http.handler
    |> result.map_error(mcp_http.describe_start_error),
  )
  let context = web.Context(warden: warden_client, mcp_url:)
  let browser =
    wisp_mist.handler(web.handle(_, context), wisp.random_string(64))
  // Relay's mist handler streams (SSE, keepalives, cancellation on
  // disconnect); `mcp_http.handle` inside the wisp router would buffer.
  let endpoint = mcp_http.mist_handler(mcp)
  let metadata_path = authorization.metadata_path(protection)
  use started <- result.try(
    fn(req: Request(mist.Connection)) {
      case req.path == "/mcp" || req.path == metadata_path {
        True -> endpoint(req)
        False -> browser(req)
      }
    }
    |> mist.new
    |> mist.bind("127.0.0.1")
    |> mist.port(port)
    |> mist.start
    |> result.map_error(fn(e) { "app listener: " <> string.inspect(e) }),
  )
  Ok(Running(
    provider:,
    warden: warden_client,
    resource_server:,
    jobs:,
    report_worker:,
    mcp:,
    listener: started.pid,
    base_url:,
    mcp_url:,
  ))
}

fn start_warden(configuration: config.Config) -> Result(warden.Client, String) {
  use client <- result.try(
    warden.new(configuration) |> result.map_error(warden.describe_start_error),
  )
  warden.start(client)
  |> result.map(fn(_) { client })
  |> result.map_error(warden.describe_start_error)
}

/// The caller's `x-request-id` when it is a valid correlation (1 to 128
/// bytes); otherwise a fresh one. The header is untrusted input, so it is
/// validated where it enters the app. Relay puts it on its events and on
/// each tool call.
fn request_correlation(req: Request(BitArray)) -> Option(Correlation) {
  request.get_header(req, "x-request-id")
  |> result.try(fn(value) {
    correlation.from_string(value) |> result.replace_error(Nil)
  })
  |> result.lazy_unwrap(correlation.unique)
  |> Some
}

fn start_jobs(
  options: Options,
  report_worker: ReportWorker,
) -> Result(grind.Grind, String) {
  use pool <- result.try(
    pog.url_config(process.new_name("secure_mcp_pool"), options.database_url)
    |> result.replace_error("grind: DATABASE_URL is not a postgres url"),
  )
  let config =
    grind.new(pool)
    |> grind.with_startup_migration
    |> grind.with_worker(report_worker)
    |> grind.with_queue(
      queue.new(tools.queue) |> queue.with_poll_interval(options.poll_interval),
    )
  grind.start(config, process.new_name("secure_mcp_jobs"))
  |> result.map_error(fn(error) {
    "grind start: " <> grind.describe_start_error(error)
  })
}

/// Stops everything in reverse order. Grind drains its running jobs first.
pub fn stop(running: Running) -> Nil {
  shutdown(running.listener)
  mcp_http.stop(running.mcp)
  let _ = grind.stop(running.jobs)
  warden.stop(running.resource_server)
  warden.stop(running.warden)
  testing.stop_provider(running.provider)
}

@external(erlang, "secure_mcp_ffi", "free_port")
fn free_port() -> Int

@external(erlang, "secure_mcp_ffi", "shutdown")
fn shutdown(pid: process.Pid) -> Nil
