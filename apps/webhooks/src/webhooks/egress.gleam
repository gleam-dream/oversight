//// Per-tenant egress. http_gun's destination policy belongs to a client
//// (one pool, one policy), with no per-request override, so a multi-tenant
//// app keeps one client per policy tier and routes each delivery to the
//// client of its tenant's tier.

import gleam/option.{type Option, None, Some}
import gleam/result
import http_gun
import http_gun/config
import http_gun/destination
import http_gun/error
import sinal/forwarder
import webhooks/subscription.{type Tier, InternalTier, PublicTier}

pub type Egress {
  Egress(public: http_gun.Client, internal: http_gun.Client)
}

pub type Settings {
  Settings(
    /// Request ceiling for one delivery attempt.
    deadline_ms: Int,
    /// Hosts the internal tier may reach; loopback is allowed only for them.
    internal_hosts: List(String),
    /// Test seam: simulated DNS for the public tier. `None` uses the system resolver.
    public_resolver: Option(destination.Resolver),
    observations: Option(forwarder.Forwarder),
  )
}

pub fn default_settings() -> Settings {
  Settings(
    deadline_ms: 5000,
    internal_hosts: ["127.0.0.1", "localhost"],
    public_resolver: None,
    observations: None,
  )
}

/// Shared limits for both tiers. The response-body bound is per request
/// (`delivery.send`), not per client.
pub fn base_config(settings: Settings) -> config.Config {
  let d = config.default()
  config.Config(
    ..d,
    deadline_ms: settings.deadline_ms,
    connect_ms: int_min(settings.deadline_ms, d.connect_ms),
    observations: settings.observations,
  )
}

/// Public destinations only. Private, loopback, link-local and metadata
/// addresses are refused for every answer the resolver returns.
pub fn public_config(settings: Settings) -> config.Config {
  let base = base_config(settings)
  config.Config(
    ..base,
    destination: destination.Policy(
      allow_public: True,
      allow_loopback: False,
      allow_private: False,
      allowed_hosts: None,
      resolver: settings.public_resolver,
    ),
  )
}

/// Loopback, but only for the named hosts (no port matching is available).
pub fn internal_config(settings: Settings) -> config.Config {
  let base = base_config(settings)
  config.Config(
    ..base,
    destination: destination.Policy(
      ..base.destination,
      allow_public: False,
      allowed_hosts: Some(settings.internal_hosts),
    ),
  )
  |> config.allow_loopback
}

pub fn start(settings: Settings) -> Result(Egress, error.Failure) {
  use public <- result.try(http_gun.start(public_config(settings)))
  use internal <- result.try(http_gun.start(internal_config(settings)))
  Ok(Egress(public:, internal:))
}

pub fn stop(egress: Egress) -> Nil {
  let _ = http_gun.stop(egress.public)
  let _ = http_gun.stop(egress.internal)
  Nil
}

pub fn client_for(egress: Egress, tier: Tier) -> http_gun.Client {
  case tier {
    PublicTier -> egress.public
    InternalTier -> egress.internal
  }
}

fn int_min(a: Int, b: Int) -> Int {
  case a < b {
    True -> a
    False -> b
  }
}
