//// Wires the desk: telemetry first, then the scripted services and provider,
//// one caller-owned http_gun client that admits loopback only, the ledger,
//// and the agent.

import fabric/agent
import gleam/result
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
    client: http_gun.Client,
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
  use client <- result.try(
    http_gun.start(
      // The default policy admits public hosts only; the scripted services
      // are on loopback, and nothing else is reachable.
      http_config.default()
      |> http_config.with_destination(destination.loopback_only())
      |> http_config.with_request_timeout(http_config.Milliseconds(10_000)),
    )
    |> result.map_error(http_gun.describe_start_error),
  )
  use ledger <- result.try(ledger.start())
  // One client; the shop's tighter budget is a view of it.
  let shop_view =
    http_gun.with_timeout(client, http_config.Milliseconds(shop_deadline_ms))
  let shop = shop.Shop(shop_view, services.base_url)
  use desk <- result.map(
    desk.start(desk.Settings(
      llm_client: client,
      provider_url: provider.base_url,
      shop:,
      ledger:,
      limits:,
    )),
  )
  App(desk, ledger, services, provider, telemetry, client)
}

pub fn stop(app: App) -> Nil {
  http_gun.stop(app.client)
  telemetry.stop(app.telemetry)
}
