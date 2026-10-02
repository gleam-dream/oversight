//// Tenants, their egress tier, and registration-time endpoint checks.
////
//// Registration checks are a first, cheap filter only. A host name can
//// resolve to anything at delivery time (DNS rebinding), so the authoritative
//// SSRF check is http_gun's destination policy on the tenant's client; see
//// `webhooks/egress`.

import gleam/list
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
  /// Internal tiers may only name allowlisted hosts.
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

/// Registration-time validation for one tier. `internal_hosts` is the same
/// allowlist the internal egress client is configured with.
pub fn validate_endpoint(
  url: String,
  tier: Tier,
  internal_hosts: List(String),
) -> Result(Uri, EndpointError) {
  use parsed <- result.try(uri.parse(url) |> result.replace_error(MalformedUrl))
  use scheme <- result.try(option.to_result(parsed.scheme, MalformedUrl))
  use Nil <- result.try(case tier, string.lowercase(scheme) {
    PublicTier, "https" -> Ok(Nil)
    InternalTier, "https" | InternalTier, "http" -> Ok(Nil)
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
  case tier {
    InternalTier ->
      case list.contains(internal_hosts, host) {
        True -> Ok(parsed)
        False -> Error(HostNotAllowlisted(host))
      }
    PublicTier ->
      // Glue: http_gun classifies an `Address` but cannot parse a host.
      case parse_address(host) {
        Error(Nil) -> Ok(parsed)
        Ok(address) ->
          case destination.classify(address) {
            destination.Public -> Ok(parsed)
            class -> Error(ForbiddenAddress(class))
          }
      }
  }
}

/// Parse an IPv4 or IPv6 literal (brackets stripped) into http_gun's Address.
pub fn parse_address(host: String) -> Result(destination.Address, Nil) {
  let bare = case string.starts_with(host, "[") && string.ends_with(host, "]") {
    True -> string.slice(host, 1, string.length(host) - 2)
    False -> host
  }
  case parse_ip(bare) {
    Ok([a, b, c, d]) -> Ok(destination.Ipv4(a, b, c, d))
    Ok([a, b, c, d, e, f, g, h]) -> Ok(destination.Ipv6(a, b, c, d, e, f, g, h))
    _ -> Error(Nil)
  }
}

@external(erlang, "webhooks_ffi", "parse_ip")
fn parse_ip(text: String) -> Result(List(Int), Nil)
