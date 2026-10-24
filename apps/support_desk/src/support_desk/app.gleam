//// Wires the desk: telemetry first, then the scripted services and provider,
//// one caller-owned http_gun client that admits loopback only, the ledger,
//// and the agent.

import fabric/agent
import gleam/function
import gleam/http/request
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import hellhound
import hellhound/config
import hellhound/resource
import hellhound/testing
import http_gun
import http_gun/config as http_config
import http_gun/destination
import support_desk/approvers
import support_desk/desk.{type Desk, type Session}
import support_desk/domain.{type Resolution}
import support_desk/executions
import support_desk/ledger.{type Ledger}
import support_desk/provider.{type Provider}
import support_desk/services.{type Services}
import support_desk/shop
import support_desk/telemetry.{type Telemetry}

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
    hellhound: hellhound.Client,
  )
}

/// The audience of the access tokens the desk accepts from approvers.
pub const audience = "https://support-desk.test"

const callback = "https://support-desk.test/callback"

/// What a signed-in approver is granted: `openid` and the scope that lets
/// them answer the desk's refund requirement.
fn approver_scopes() -> List(String) {
  ["openid", "approve:" <> desk.approver.name]
}

/// The credential of a caller who presented nothing. `check` refuses it as
/// not authenticated.
pub const anonymous = ""

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
  use <- release_on_error(fn() {
    telemetry.stop(telemetry)
    Ok(Nil)
  })
  use services <- result.try(services.start())
  use <- release_on_error(fn() { services.stop(services) })
  use provider <- result.try(provider.start())
  use <- release_on_error(fn() { provider.stop(provider) })
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
  use <- release_on_error(fn() {
    http_gun.stop(client)
    Ok(Nil)
  })
  use identity <- result.try(
    testing.provider_options()
    |> testing.with_access_token_audiences([audience])
    // The scope `approve:<requirement name>` is what lets an approver
    // answer; mallory signs in but may not.
    |> testing.with_granted_scopes("alice", approver_scopes())
    |> testing.with_granted_scopes("bob", approver_scopes())
    |> testing.with_granted_scopes("carol", approver_scopes())
    |> testing.with_granted_scopes("mallory", ["openid"])
    |> testing.start_provider
    |> result.replace_error("identity provider did not start"),
  )
  use <- release_on_error(fn() {
    testing.stop_provider(identity)
    Ok(Nil)
  })
  use hellhound <- result.try(
    hellhound.new(
      testing.config(identity, callback) |> config.with_scopes(["openid"]),
    )
    |> result.map_error(fn(_) { "hellhound configuration" }),
  )
  use <- release_on_error(fn() {
    hellhound.stop(hellhound)
    Ok(Nil)
  })
  use Nil <- result.try(
    hellhound.start(hellhound)
    |> result.map_error(fn(error) { "hellhound: " <> string.inspect(error) }),
  )
  use ledger <- result.try(ledger.start())
  use <- release_on_error(fn() {
    ledger.stop(ledger)
    Ok(Nil)
  })
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
      approvers: approvers.hellhound_approvers(resource.new(
        hellhound,
        audience:,
      )),
      tune:,
    )),
  )
  App(desk, ledger, services, provider, telemetry, client, identity, hellhound)
}

/// An approver signs in through OIDC and gets an access token for the
/// desk. The scripted provider's login page signs `subject` in; the request
/// the browser would make is played in process, as Hellhound's reference
/// consumer does.
pub fn sign_in(app: App, subject: String) -> Result(String, String) {
  use redirect <- result.try(
    hellhound.begin_login(
      app.hellhound,
      request.new(),
      hellhound.default_login(),
    )
    |> result.map_error(hellhound.describe_login_error),
  )
  use callback <- result.try(
    testing.authorize(app.identity, redirect, subject:)
    |> result.map_error(fn(error) { "sign-in: " <> string.inspect(error) }),
  )
  use session <- result.try(
    hellhound.complete_login(app.hellhound, callback)
    |> result.map_error(hellhound.describe_login_error),
  )
  use access <- result.map(
    hellhound.access_token(app.hellhound, session)
    |> result.map_error(hellhound.describe_session_error),
  )
  hellhound.access_token_value(access.token)
}

/// Close Fabric admission and drain its runners before releasing their
/// borrowed clients and actors. The in-memory ticket records are discarded;
/// this is resource shutdown, not a claim of refund reversal or completion.
/// If draining fails, retain the borrowed resources so the caller can retry.
pub fn stop(app: App) -> Result(Nil, String) {
  use Nil <- result.try(desk.stop(app.desk))
  hellhound.stop(app.hellhound)
  testing.stop_provider(app.identity)
  http_gun.stop(app.client)
  use Nil <- result.try(provider.stop(app.provider))
  use Nil <- result.map(services.stop(app.services))
  ledger.stop(app.ledger)
  telemetry.stop(app.telemetry)
  executions.stop(app.desk.executions)
}

/// Register each release immediately after acquisition. On refused startup,
/// unwind the resources in reverse order and retain any cleanup failure.
fn release_on_error(
  release: fn() -> Result(Nil, String),
  next: fn() -> Result(value, String),
) -> Result(value, String) {
  case next() {
    Ok(value) -> Ok(value)
    Error(error) ->
      case release() {
        Ok(Nil) -> Error(error)
        Error(cleanup) -> Error(error <> "; cleanup: " <> cleanup)
      }
  }
}
