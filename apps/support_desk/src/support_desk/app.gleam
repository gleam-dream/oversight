//// Wires the desk: telemetry first, then the scripted services and provider,
//// one caller-owned http_gun client that admits loopback only, the ledger,
//// and the agent.

import fabric/agent
import gleam/function
import gleam/http/request
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import http_gun
import http_gun/config as http_config
import http_gun/destination
import support_desk/approvers.{type Credential}
import support_desk/desk.{type Desk, type Session}
import support_desk/domain.{type Resolution}
import support_desk/ledger.{type Ledger}
import support_desk/provider.{type Provider}
import support_desk/services.{type Services}
import support_desk/shop
import support_desk/telemetry.{type Telemetry}
import warden
import warden/config
import warden/resource
import warden/testing

pub type App {
  App(
    desk: Desk,
    ledger: Ledger,
    services: Services,
    provider: Provider,
    telemetry: Telemetry,
    client: http_gun.Client,
    /// The scripted OIDC provider the approvers sign in with, and the
    /// desk's client of it (the relying party that signs them in and the
    /// key cache that validates their tokens).
    identity: testing.Provider,
    warden: warden.Client,
  )
}

/// The audience of the access tokens the desk accepts from approvers.
pub const audience = "https://support-desk.test"

const callback = "https://support-desk.test/callback"

/// The ordinary configuration: default agent limits and a one-second
/// budget for the shop's APIs.
pub fn start() -> Result(App, String) {
  start_with(function.identity, shop_deadline: duration.seconds(1))
}

/// `tune` adjusts the agent's spec, for example with `agent.with_max_turns`.
pub fn start_with(
  tune: fn(agent.Spec(Session, Resolution)) -> agent.Spec(Session, Resolution),
  shop_deadline shop_deadline: Duration,
) -> Result(App, String) {
  use telemetry <- result.try(telemetry.start())
  use services <- result.try(services.start())
  use provider <- result.try(provider.start())
  use client <- result.try(
    http_gun.start(
      // The default policy admits public hosts only; the scripted services
      // are on loopback, and nothing else is reachable.
      http_config.default()
      |> http_config.with_destination(destination.loopback_only())
      |> http_config.with_request_timeout(
        http_config.After(duration.seconds(10)),
      ),
    )
    |> result.map_error(http_gun.describe_start_error),
  )
  use identity <- result.try(
    testing.provider_options()
    |> testing.with_access_token_audiences([audience])
    |> testing.start_provider
    |> result.replace_error("identity provider did not start"),
  )
  use warden <- result.try(
    warden.new(
      testing.config(identity, callback) |> config.with_scopes(["openid"]),
    )
    |> result.map_error(fn(_) { "warden configuration" }),
  )
  use Nil <- result.try(
    warden.start(warden)
    |> result.map_error(fn(error) { "warden: " <> string.inspect(error) }),
  )
  use ledger <- result.try(ledger.start())
  // One client; the shop's tighter budget is a view of it.
  let shop_view =
    http_gun.with_timeout(client, http_config.After(shop_deadline))
  let shop = shop.Shop(shop_view, services.base_url)
  use desk <- result.map(
    desk.start(desk.Settings(
      llm_client: client,
      provider_url: provider.base_url,
      shop:,
      ledger:,
      approvers: approvers.new(resource.new(warden, audience:)),
      tune:,
    )),
  )
  App(desk, ledger, services, provider, telemetry, client, identity, warden)
}

/// An approver signs in through OIDC and gets an access token for the
/// desk. The scripted provider's login page signs `subject` in; the request
/// the browser would make is played in process, as Warden's reference
/// consumer does.
pub fn sign_in(app: App, subject: String) -> Result(Credential, String) {
  use redirect <- result.try(
    warden.begin_login(app.warden, request.new(), warden.default_login())
    |> result.map_error(warden.describe_login_error),
  )
  use callback <- result.try(
    testing.authorize(app.identity, redirect, subject:)
    |> result.map_error(fn(error) { "sign-in: " <> string.inspect(error) }),
  )
  use session <- result.try(
    warden.complete_login(app.warden, callback)
    |> result.map_error(warden.describe_login_error),
  )
  use access <- result.map(
    warden.access_token(app.warden, session)
    |> result.map_error(warden.describe_session_error),
  )
  approvers.Bearer(warden.access_token_value(access.token))
}

pub fn stop(app: App) -> Nil {
  warden.stop(app.warden)
  testing.stop_provider(app.identity)
  http_gun.stop(app.client)
  telemetry.stop(app.telemetry)
}
