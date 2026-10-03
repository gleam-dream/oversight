//// Wiring: `warden/testing`'s provider, the billing API, Postgres, Warden
//// with its records in Postgres, the billing http_gun client, telemetry and
//// the portal itself.

import envoy
import gleam/crypto
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import gleam/uri
import http_gun
import http_gun/config as gun_config
import http_gun/destination
import pog
import sso_portal/billing_api.{type BillingApi}
import sso_portal/server.{type Server, Server}
import sso_portal/session_store
import sso_portal/telemetry.{type Telemetry}
import sso_portal/warden_records
import sso_portal/web
import warden
import warden/config
import warden/store.{type Store}
import warden/testing.{type Provider}
import wisp

/// The audience the provider puts in access tokens and the billing API
/// requires.
const billing_audience = "https://billing.test"

/// The table of Warden's sealed custody and login records.
const records_table = "warden_records"

pub type Options {
  Options(
    provider: testing.ProviderOptions,
    /// Who the test provider signs in.
    subject: String,
    /// `None` keeps Warden's default (5 s).
    clock_tolerance: Option(Duration),
    /// `None` keeps Warden's default (30 s).
    refresh_margin: Option(Duration),
    print_telemetry: Bool,
  )
}

pub fn default_options() -> Options {
  Options(
    provider: testing.provider_options()
      |> testing.with_access_token_audiences([billing_audience]),
    subject: "user-42",
    clock_tolerance: None,
    refresh_margin: None,
    print_telemetry: False,
  )
}

pub type App {
  App(
    options: Options,
    provider: Provider,
    billing_api: BillingApi,
    telemetry: Telemetry,
    db: pog.Connection,
    /// Warden's records in Postgres, and the key that seals them. Both
    /// outlive a Warden client.
    records: Store,
    sealing_key: config.SealingKey,
    warden: warden.Client,
    billing_client: http_gun.Client,
    portal: Server,
    portal_url: String,
    secret_key_base: String,
  )
}

pub fn start(options: Options) -> Result(App, String) {
  use telemetry <- result.try(telemetry.start(options.print_telemetry))
  use provider <- result.try(
    testing.start_provider(options.provider)
    |> result.replace_error("test provider did not start"),
  )
  use db <- result.try(connect_database())
  let records = warden_records.new(db, records_table)
  use sealing_key <- result.try(
    config.sealing_key(crypto.strong_random_bytes(32))
    |> result.replace_error("sealing key"),
  )
  use billing_api <- result.try(start_billing_api(options, provider))
  use port <- result.try(
    server.free_port() |> result.replace_error("no free port"),
  )
  let portal_url = "http://127.0.0.1:" <> int.to_string(port)
  use warden <- result.try(start_warden(
    options,
    provider,
    records,
    sealing_key,
    portal_url,
  ))
  use billing_client <- result.try(start_billing_client(telemetry))
  let app =
    App(
      options:,
      provider:,
      billing_api:,
      telemetry:,
      db:,
      records:,
      sealing_key:,
      warden:,
      billing_client:,
      // Placeholder: `serve_portal` starts the listener on this port.
      portal: Server(pid: process.self(), port:),
      portal_url:,
      secret_key_base: wisp.random_string(64),
    )
  serve_portal(app)
}

pub fn stop(app: App) -> Nil {
  server.stop(app.portal)
  warden.stop(app.warden)
  http_gun.stop(app.billing_client)
  billing_api.stop(app.billing_api)
  warden.stop(app.billing_api.warden)
  testing.stop_provider(app.provider)
  telemetry.stop(app.telemetry)
}

/// Restart only the web tier: a new mist server on the same address with the
/// same Warden client, database and cookie key.
pub fn restart_portal(app: App) -> Result(App, String) {
  server.stop(app.portal)
  serve_portal(app)
}

/// Restart Warden (a deploy, or a node crash): a new client over the same
/// Postgres records and sealing key. Its processes start empty; custody
/// comes back from the table.
pub fn restart_warden(app: App) -> Result(App, String) {
  warden.stop(app.warden)
  use warden <- result.try(start_warden(
    app.options,
    app.provider,
    app.records,
    app.sealing_key,
    app.portal_url,
  ))
  server.stop(app.portal)
  serve_portal(App(..app, warden:))
}

fn serve_portal(app: App) -> Result(App, String) {
  let context =
    web.Context(
      warden: app.warden,
      db: app.db,
      billing: app.billing_client,
      billing_url: app.billing_api.base_url,
      telemetry: app.telemetry,
      login_response: provider_login_page(app.provider, app.options.subject),
    )
  // The OS may hold the port briefly after the old listener closes.
  use portal <- result.try(
    retry(10, fn() {
      server.start_on(
        web.handle(_, context),
        app.secret_key_base,
        app.portal.port,
        None,
      )
    }),
  )
  Ok(App(..app, portal:))
}

fn start_warden(
  options: Options,
  provider: Provider,
  records: Store,
  sealing_key: config.SealingKey,
  portal_url: String,
) -> Result(warden.Client, String) {
  let configuration =
    testing.config(provider, portal_url <> "/callback")
    |> config.with_scopes(["email"])
    |> config.with_custody_store(records)
    |> config.with_transaction_store(records)
    |> config.with_sealing_key(sealing_key)
  let configuration = case options.clock_tolerance {
    Some(tolerance) -> config.with_clock_tolerance(configuration, tolerance)
    None -> configuration
  }
  let configuration = case options.refresh_margin {
    Some(margin) -> config.with_refresh_margin(configuration, margin)
    None -> configuration
  }
  use client <- result.try(
    warden.new(configuration)
    |> result.map_error(fn(e) { "warden: " <> warden.describe_start_error(e) }),
  )
  warden.start(client)
  |> result.map(fn(_) { client })
  |> result.map_error(fn(e) { "warden: " <> warden.describe_start_error(e) })
}

/// The billing API validates tokens as a resource server of the provider.
fn start_billing_api(
  options: Options,
  provider: Provider,
) -> Result(BillingApi, String) {
  let configuration =
    config.resource_server(issuer: testing.issuer(provider))
    |> testing.trusting(provider)
  // The billing API lives with the same provider clock.
  let configuration = case options.clock_tolerance {
    Some(tolerance) -> config.with_clock_tolerance(configuration, tolerance)
    None -> configuration
  }
  use client <- result.try(
    configuration
    |> warden.new
    |> result.map_error(fn(e) { "billing: " <> warden.describe_start_error(e) }),
  )
  use _ <- result.try(
    warden.start(client)
    |> result.map_error(fn(e) { "billing: " <> warden.describe_start_error(e) }),
  )
  billing_api.start(client, audience: billing_audience)
}

/// The provider's login page, played by the test provider: it approves the
/// authorization request for the configured subject and sends the browser
/// straight back to the portal's callback.
/// `warden/testing` serves no `/authorize`, so the portal's redirect is
/// taken here, where the opaque `LoginRedirect` is still in hand.
fn provider_login_page(
  provider: Provider,
  subject: String,
) -> fn(wisp.Response, warden.LoginRedirect) -> wisp.Response {
  fn(res, redirect) {
    let res = warden.login_response(res, redirect)
    case testing.authorize(provider, redirect, subject:) {
      Ok(callback) ->
        response.set_header(
          res,
          "location",
          uri.to_string(request.to_uri(callback)),
        )
      Error(_) -> res
    }
  }
}

/// The billing API's own http_gun client. Warden cannot share it (Warden
/// builds a private client from its own policy), and should not: this one
/// allows plain-HTTP loopback and reports to the app's Sinal forwarder.
fn start_billing_client(
  telemetry: Telemetry,
) -> Result(http_gun.Client, String) {
  gun_config.default()
  |> gun_config.with_request_timeout(gun_config.After(duration.seconds(5)))
  |> gun_config.with_connect_timeout(duration.seconds(1))
  |> gun_config.with_observations(telemetry.forwarder(telemetry))
  |> gun_config.with_destination(destination.loopback_only())
  |> http_gun.start
  |> result.map_error(fn(failure) {
    "billing client: " <> http_gun.describe_start_error(failure)
  })
}

pub fn connect_database() -> Result(pog.Connection, String) {
  use url <- result.try(
    envoy.get("DATABASE_URL")
    |> result.replace_error("DATABASE_URL is not set (use with-postgres.sh)"),
  )
  use cfg <- result.try(
    pog.url_config(process.new_name("sso_portal_db"), url)
    |> result.replace_error("DATABASE_URL is not a postgres URL"),
  )
  use started <- result.try(
    cfg
    |> pog.pool_size(4)
    |> pog.start
    |> result.map_error(fn(e) { "postgres: " <> string.inspect(e) }),
  )
  let db = started.data
  use _ <- result.try(
    session_store.migrate(db)
    |> result.map_error(fn(e) { "migrate: " <> string.inspect(e) }),
  )
  use _ <- result.try(
    warden_records.migrate(db, records_table)
    |> result.map_error(fn(e) { "migrate: " <> string.inspect(e) }),
  )
  Ok(db)
}

fn retry(times: Int, run: fn() -> Result(a, String)) -> Result(a, String) {
  case run() {
    Ok(value) -> Ok(value)
    Error(error) if times <= 1 -> Error(error)
    Error(_) -> {
      process.sleep(50)
      retry(times - 1, run)
    }
  }
}
