//// Tenants, their egress tier, and registration-time endpoint checks.
////
//// Registration checks apply the tier's destination policy to the URL's
//// host and port without resolving it. A host name can resolve to anything
//// at delivery time (DNS rebinding), so the authoritative SSRF check is the
//// same policy applied to the delivery's client view; see `webhooks/egress`.

import gleam/int
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri.{type Uri}
import http_gun/destination

/// Which egress client a tenant's deliveries use.
pub type Tier {
  /// Ordinary tenants: public destinations only, HTTPS only.
  PublicTier
  /// Operator-owned tenants whose receivers run on allowlisted loopback hosts.
  InternalTier
}

pub type Tenant {
  Tenant(name: String, tier: Tier)
}

pub type Status {
  Active
  Disabled(reason: String)
}

pub type Subscription {
  Subscription(
    id: String,
    tenant: String,
    url: String,
    secret: String,
    status: Status,
  )
}

pub type EndpointError {
  MalformedUrl
  UnsupportedScheme(String)
  CredentialsInUrl
  MissingHost
  /// The host is an IP literal outside the tier's permitted address classes.
  ForbiddenAddress(destination.Class)
  /// Internal tiers may only name allowlisted hosts (and ports); `host:port`.
  HostNotAllowlisted(String)
}

pub fn endpoint_error_message(error: EndpointError) -> String {
  case error {
    MalformedUrl -> "url is not an absolute URL"
    UnsupportedScheme(scheme) -> "scheme not allowed: " <> scheme
    CredentialsInUrl -> "url must not embed credentials"
    MissingHost -> "url has no host"
    ForbiddenAddress(class) ->
      "destination address class not allowed: " <> class_name(class)
    HostNotAllowlisted(host) -> "host not allowlisted: " <> host
  }
}

pub fn class_name(class: destination.Class) -> String {
  case class {
    destination.Public -> "public"
    destination.Loopback -> "loopback"
    destination.Private -> "private"
    destination.Reserved -> "reserved"
  }
}

/// The destinations a tier may reach. The egress client narrows each
/// delivery to it, and registration checks endpoints against the same value.
pub fn policy(tier: Tier, internal_hosts: List(String)) -> destination.Policy {
  case tier {
    PublicTier -> destination.default()
    InternalTier ->
      destination.loopback_only() |> destination.only_hosts(internal_hosts)
  }
}

/// Registration-time validation for one tier. `internal_hosts` is the same
/// allowlist (`host` or `host:port` entries) the egress client applies.
pub fn validate_endpoint(
  url: String,
  tier: Tier,
  internal_hosts: List(String),
) -> Result(Uri, EndpointError) {
  use parsed <- result.try(uri.parse(url) |> result.replace_error(MalformedUrl))
  use scheme <- result.try(option.to_result(parsed.scheme, MalformedUrl))
  use port <- result.try(case tier, string.lowercase(scheme) {
    _, "https" -> Ok(option.unwrap(parsed.port, 443))
    InternalTier, "http" -> Ok(option.unwrap(parsed.port, 80))
    _, other -> Error(UnsupportedScheme(other))
  })
  use Nil <- result.try(case parsed.userinfo {
    Some(_) -> Error(CredentialsInUrl)
    None -> Ok(Nil)
  })
  use host <- result.try(case parsed.host {
    Some("") | None -> Error(MissingHost)
    Some(host) -> Ok(string.lowercase(host))
  })
  case destination.check(policy(tier, internal_hosts), host, port) {
    Ok(Nil) -> Ok(parsed)
    Error(destination.HostNotAllowed) ->
      Error(HostNotAllowlisted(host <> ":" <> int.to_string(port)))
    Error(destination.AddressRefused(class)) -> Error(ForbiddenAddress(class))
  }
}
