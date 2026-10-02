//// Wires the desk: telemetry first (its forwarder carries http_gun's
//// observations), then the scripted services and provider, two
//// caller-owned http_gun clients that admit loopback, the ledger, and the
//// agent.

import fabric/agent
import gleam/option.{Some}
import gleam/result
import gleam/string
import http_gun
import http_gun/config as http_config
import http_gun/destination
import support_desk/desk.{type Desk}
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
    llm_client: http_gun.Client,
    shop_client: http_gun.Client,
  )
}

/// The ordinary configuration: every refund needs approval, default
/// agent limits, and a one-second budget for the shop's APIs.
pub fn start() -> Result(App, String) {
  start_with(agent.default_limits(), shop_deadline_ms: 1000)
}

pub fn start_with(
  limits: agent.Limits,
  shop_deadline_ms shop_deadline_ms: Int,
) -> Result(App, String) {
  use telemetry <- result.try(telemetry.start())
  use services <- result.try(services.start())
  use provider <- result.try(provider.start())
  let observed =
    http_config.Config(
      ..loopback(),
      observations: Some(telemetry.forwarder(telemetry)),
    )
  use llm_client <- result.try(
    http_gun.start(http_config.Config(..observed, deadline_ms: 10_000))
    |> result.map_error(string.inspect),
  )
  use shop_client <- result.try(
    http_gun.start(
      http_config.Config(..observed, deadline_ms: shop_deadline_ms),
    )
    |> result.map_error(string.inspect),
  )
  use ledger <- result.try(ledger.start())
  let shop = shop.Shop(shop_client, services.base_url)
  use desk <- result.map(
    desk.start(desk.Settings(
      llm_client:,
      provider_url: provider.base_url,
      shop:,
      ledger:,
      limits:,
    )),
  )
  App(desk, ledger, services, provider, telemetry, llm_client, shop_client)
}

pub fn stop(app: App) -> Nil {
  let _ = http_gun.stop(app.llm_client)
  let _ = http_gun.stop(app.shop_client)
  telemetry.stop(app.telemetry)
}

/// http_gun's default policy admits public destinations only; the scripted
/// services live on loopback. `http_config.allow_loopback` would admit
/// loopback but leave public destinations open, and these clients reach
/// nothing else, so the policy closes public destinations as well.
pub fn loopback() -> http_config.Config {
  http_config.Config(
    ..http_config.default(),
    destination: destination.Policy(
      ..destination.default(),
      allow_public: False,
      allow_loopback: True,
    ),
  )
}
