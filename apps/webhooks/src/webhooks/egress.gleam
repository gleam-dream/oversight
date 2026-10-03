//// Egress: one http_gun client for every tenant. Its destination policy is
//// the union of the tiers (public and loopback), and each delivery narrows
//// it to its tenant's tier with a client view (`subscription.policy`), the
//// same policy registration checks. The client refuses any request that
//// skips the view (`config.require_view_destination`), so a public tenant
//// can never reach loopback through the base client.

import gleam/option.{type Option, None, Some}
import gleam/result
import http_gun
import http_gun/config
import http_gun/destination
import webhooks/subscription.{type Tier}

pub type Egress {
  Egress(client: http_gun.Client, internal_hosts: List(String))
}

pub type Settings {
  Settings(
    /// Request ceiling for one delivery attempt.
    deadline_ms: Int,
    /// `host` or `host:port` entries the internal tier may reach on loopback.
    internal_hosts: List(String),
    /// Test seam: simulated DNS. `None` uses the system resolver.
    resolver: Option(config.Resolver),
    /// Test seam: how the client starts, e.g. `testing.playback(script, _)`.
    start_client: fn(config.Config) ->
      Result(http_gun.Client, http_gun.StartError),
  )
}

pub fn default_settings() -> Settings {
  Settings(
    deadline_ms: 5000,
    internal_hosts: ["127.0.0.1", "localhost"],
    resolver: None,
    start_client: http_gun.start,
  )
}

pub fn config(settings: Settings) -> config.Config {
  let base =
    config.default()
    |> config.with_request_timeout(config.Milliseconds(settings.deadline_ms))
    |> config.with_destination(
      destination.default() |> destination.allow_loopback,
    )
    |> config.require_view_destination
  case settings.resolver {
    Some(resolver) -> config.with_resolver(base, resolver)
    None -> base
  }
}

pub fn start(settings: Settings) -> Result(Egress, http_gun.StartError) {
  use client <- result.map(settings.start_client(config(settings)))
  Egress(client:, internal_hosts: settings.internal_hosts)
}

pub fn stop(egress: Egress) -> Nil {
  http_gun.stop(egress.client)
}

/// The client view for one tier: it can only narrow the client's policy.
pub fn client_for(egress: Egress, tier: Tier) -> http_gun.Client {
  egress.client
  |> http_gun.with_destination(subscription.policy(tier, egress.internal_hosts))
}
