//// Wiring: the scripted provider, the billing API, Postgres, Warden, the
//// billing http_gun client, telemetry and the portal itself.

import envoy
import gleam/erlang/process
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import http_gun
import http_gun/config as gun_config
import http_gun/destination
import pog
import sso_portal/access
import sso_portal/billing_api.{type BillingApi}
import sso_portal/fake_idp.{type Idp}
import sso_portal/pki.{type Pki}
import sso_portal/server.{type Server}
import sso_portal/session_store
import sso_portal/telemetry.{type Telemetry}
import sso_portal/web
import warden
import warden/config
import wisp

pub type Options {
  Options(
    idp: fake_idp.Settings,
    /// `None` keeps Warden's default (5 s).
    clock_tolerance_seconds: Option(Int),
    access_policy: access.Policy,
    print_telemetry: Bool,
  )
}

pub fn default_options() -> Options {
  Options(
    idp: fake_idp.default_settings(),
    clock_tolerance_seconds: None,
    access_policy: access.default_policy(),
    print_telemetry: False,
  )
}

pub type App {
  App(
    options: Options,
    pki: Pki,
    idp: Idp,
    billing_api: BillingApi,
    telemetry: Telemetry,
    db: pog.Connection,
    warden: warden.Client,
    billing_client: http_gun.Client,
    portal: Server,
    portal_url: String,
    secret_key_base: String,
  )
}

pub fn start(options: Options) -> Result(App, String) {
  let tmp = envoy.get("TMPDIR") |> result.unwrap("/tmp")
  use pki <- result.try(pki.generate(tmp))
  use telemetry <- result.try(telemetry.start(options.print_telemetry))
  use idp <- result.try(fake_idp.start(options.idp, pki))
  use billing_api <- result.try(billing_api.start(idp))
  use db <- result.try(connect_database())
  use port <- result.try(
    server.free_port() |> result.replace_error("no free port"),
  )
  let portal_url = "http://127.0.0.1:" <> int.to_string(port)
  use warden <- result.try(start_warden(options, idp, pki, portal_url))
  use billing_client <- result.try(start_billing_client(telemetry))
  let secret_key_base = wisp.random_string(64)
  let context =
    web.Context(
      warden:,
      db:,
      billing: billing_client,
      billing_url: billing_api.base_url,
      telemetry:,
      access_policy: options.access_policy,
    )
  use portal <- result.try(server.start_on(
    web.handle(_, context),
    secret_key_base,
    port,
    None,
  ))
  Ok(App(
    options:,
    pki:,
    idp:,
    billing_api:,
    telemetry:,
    db:,
    warden:,
    billing_client:,
    portal:,
    portal_url:,
    secret_key_base:,
  ))
}

pub fn stop(app: App) -> Nil {
  server.stop(app.portal)
  warden.stop(app.warden)
  let _ = http_gun.stop(app.billing_client)
  billing_api.stop(app.billing_api)
  fake_idp.stop(app.idp)
  telemetry.stop(app.telemetry)
}

/// Restart only the web tier: a new mist server on the same address with the
/// same Warden client, database and cookie key.
pub fn restart_portal(app: App) -> Result(App, String) {
  server.stop(app.portal)
  serve_portal(app)
}

/// Restart Warden (a deploy, or a node crash): its in-memory custody is gone.
pub fn restart_warden(app: App) -> Result(App, String) {
  warden.stop(app.warden)
  use warden <- result.try(start_warden(
    app.options,
    app.idp,
    app.pki,
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
      access_policy: app.options.access_policy,
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
  idp: Idp,
  pki: Pki,
  portal_url: String,
) -> Result(warden.Client, String) {
  let idp_settings = options.idp
  let settings =
    config.new(
      issuer: fake_idp.issuer(idp),
      client_id: idp_settings.client_id,
      redirect_uri: portal_url <> "/callback",
      authentication: config.ClientSecretBasic(config.secret(
        idp_settings.client_secret,
      )),
    )
    |> config.with_scopes(["email"])
    // The scripted provider is on loopback with a self-signed certificate.
    |> config.with_trust(config.TrustAnchorsPem(pki.certificate_pem))
    |> config.with_destinations(config.AllowLoopbackForTesting)
  let settings = case options.clock_tolerance_seconds {
    Some(seconds) -> config.with_clock_tolerance(settings, seconds)
    None -> settings
  }
  use validated <- result.try(
    config.validate(settings)
    |> result.map_error(fn(errors) {
      "warden config: " <> string.inspect(errors)
    }),
  )
  warden.start(validated)
  |> result.map_error(fn(error) { "warden start: " <> string.inspect(error) })
}

/// The billing API's own http_gun client. Warden cannot share it (Warden
/// builds a private client from its own policy), and should not: this one
/// allows plain-HTTP loopback and reports to the app's Sinal forwarder.
fn start_billing_client(
  telemetry: Telemetry,
) -> Result(http_gun.Client, String) {
  let defaults = gun_config.default()
  gun_config.Config(
    ..defaults,
    deadline_ms: 5000,
    connect_ms: 1000,
    observations: Some(telemetry.forwarder(telemetry)),
    destination: destination.Policy(
      ..defaults.destination,
      allow_public: False,
      allow_loopback: True,
    ),
  )
  |> http_gun.start
  |> result.map_error(fn(failure) {
    "billing client: " <> string.inspect(failure)
  })
}

fn connect_database() -> Result(pog.Connection, String) {
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
