//// The demo's caller identity: a configured table from bearer token to
//// customer id. A real deployment would verify a signed token or a session
//// instead (see `sso_portal` and `secure_mcp`); the shape the order API
//// relies on is the same: one authenticated customer id per request, or a
//// 401 before anything else happens.

import gleam/dict.{type Dict}
import gleam/list

pub opaque type Customers {
  Customers(by_token: Dict(String, String))
}

/// Builds the table from `#(token, customer_id)` pairs. Empty tokens or
/// customer ids are dropped, so an empty bearer never authenticates.
pub fn from_list(pairs: List(#(String, String))) -> Customers {
  pairs
  |> list.filter(fn(pair) { pair.0 != "" && pair.1 != "" })
  |> dict.from_list
  |> Customers
}

/// The customer an `Authorization` header value authenticates.
pub fn authenticate(
  customers: Customers,
  authorization: Result(String, Nil),
) -> Result(String, Nil) {
  case authorization {
    Ok("Bearer " <> token) -> dict.get(customers.by_token, token)
    _ -> Error(Nil)
  }
}
