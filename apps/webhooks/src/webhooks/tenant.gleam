//// Tenants and the API keys that identify them.
////
//// A caller names no tenant: it presents `Authorization: Bearer <key>`, and
//// the key resolves the tenant. Every state-changing route and every read is
//// bound to that tenant, so a body or path can never act for another one.

import envoy
import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/list
import gleam/string
import webhooks/subscription.{type Tier}

pub type Tenant {
  Tenant(name: String, tier: Tier, api_key: String)
}

/// Where a tenant's key came from at boot.
pub type KeySource {
  FromEnvironment
  /// No variable was set; the key is random and lasts for this run.
  Generated
}

/// `WEBHOOKS_API_KEY_<NAME>`, for example `WEBHOOKS_API_KEY_ACME`.
pub fn key_variable(name: String) -> String {
  "WEBHOOKS_API_KEY_" <> string.uppercase(name)
}

/// The tenant's key from `key_variable(name)`, or a random one when the
/// variable is unset or empty.
pub fn from_environment(name: String, tier: Tier) -> #(Tenant, KeySource) {
  case envoy.get(key_variable(name)) {
    Ok(key) if key != "" -> #(
      Tenant(name:, tier:, api_key: key),
      FromEnvironment,
    )
    _ -> #(Tenant(name:, tier:, api_key: generate_key()), Generated)
  }
}

pub fn generate_key() -> String {
  "whk_"
  <> {
    crypto.strong_random_bytes(24)
    |> bit_array.base16_encode
    |> string.lowercase
  }
}

/// The tier of each tenant, by name, for the delivery worker.
pub fn tiers(tenants: List(Tenant)) -> Dict(String, Tier) {
  tenants
  |> list.map(fn(tenant) { #(tenant.name, tenant.tier) })
  |> dict.from_list
}

/// Resolves an `Authorization` header value to its tenant.
///
/// Both sides are hashed before a constant-time comparison, so neither the
/// key length nor the first differing byte shows in the timing, and every
/// tenant is compared, so neither does the matching tenant's position.
pub fn authenticate(
  tenants: List(Tenant),
  authorization: Result(String, Nil),
) -> Result(Tenant, Nil) {
  case authorization {
    Ok("Bearer " <> key) if key != "" -> {
      let presented = digest(key)
      list.fold(tenants, Error(Nil), fn(found, tenant) {
        let matches = crypto.secure_compare(digest(tenant.api_key), presented)
        case matches, found {
          True, Error(Nil) -> Ok(tenant)
          _, _ -> found
        }
      })
    }
    _ -> Error(Nil)
  }
}

fn digest(key: String) -> BitArray {
  crypto.hash(crypto.Sha256, bit_array.from_string(key))
}
