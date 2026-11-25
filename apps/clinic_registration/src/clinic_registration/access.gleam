//// Who the application believes. Nothing a request says about its sender
//// is taken as identity: a desk request acts as the validator its bearer
//// token resolves to in the application's own table, with the decision
//// sets that table gives, and the webhook admits only a body signed with
//// the secret the clinic shares with the messaging channel.
////
//// Both are unset by default, and unset means closed: with no staff every
//// desk route answers 401, and with no channel secret so does the webhook.
////
//// The staff table stands in for the clinic's sign-in. An application
//// with one verifies its session or access token here instead and looks
//// the decision sets up by the verified subject; the rest of the
//// application only needs what `authenticate` returns.

import decisions/vocabulary.{type Validator}
import gleam/bit_array
import gleam/crypto
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// The least bytes a bearer token or a channel secret may have.
pub const least_secret_bytes = 32

/// The people who may use the desk, by the digest of their bearer token.
pub opaque type Staff {
  Staff(members: List(#(BitArray, Validator)))
}

/// Nobody: every desk request is refused.
pub fn nobody() -> Staff {
  Staff([])
}

/// The staff table from `#(bearer token, validator)` pairs. A token
/// shorter than `least_secret_bytes` or used twice refuses the table.
pub fn staff(members: List(#(String, Validator))) -> Result(Staff, String) {
  let tokens = list.map(members, fn(member) { member.0 })
  case
    list.any(tokens, fn(token) { string.byte_size(token) < least_secret_bytes }),
    list.unique(tokens) == tokens
  {
    True, _ -> Error("a staff token is shorter than 32 bytes")
    False, False -> Error("two staff members share a token")
    False, True ->
      Ok(Staff(list.map(members, fn(member) { #(digest(member.0), member.1) })))
  }
}

/// The validator an `Authorization` header value authenticates.
///
/// Both sides are hashed before a constant-time comparison and every
/// member is compared, so the timing shows neither how much of a token
/// matched nor which member did.
pub fn authenticate(
  staff: Staff,
  authorization: Result(String, Nil),
) -> Result(Validator, Nil) {
  case authorization {
    Ok("Bearer " <> token) -> {
      let presented = digest(token)
      list.fold(staff.members, Error(Nil), fn(found, member) {
        case crypto.secure_compare(member.0, presented), found {
          True, Error(Nil) -> Ok(member.1)
          _, _ -> found
        }
      })
    }
    _ -> Error(Nil)
  }
}

fn digest(token: String) -> BitArray {
  crypto.hash(crypto.Sha256, bit_array.from_string(token))
}

/// The secret the clinic shares with the messaging channel.
pub opaque type ChannelSecret {
  ChannelSecret(key: BitArray)
}

/// A channel secret of at least `least_secret_bytes` bytes.
pub fn channel_secret(text: String) -> Result(ChannelSecret, String) {
  case string.byte_size(text) >= least_secret_bytes {
    True -> Ok(ChannelSecret(bit_array.from_string(text)))
    False -> Error("the channel secret is shorter than 32 bytes")
  }
}

/// The header that carries a webhook body's signature.
pub const signature_header = "x-channel-signature"

/// The signature of a webhook body: `sha256=` and the lowercase hex
/// HMAC-SHA256 of the exact bytes sent. The channel computes it; so do the
/// scripted run and the tests, which play the channel.
pub fn sign(secret: ChannelSecret, body: BitArray) -> String {
  "sha256="
  <> string.lowercase(
    bit_array.base16_encode(crypto.hmac(body, crypto.Sha256, secret.key)),
  )
}

/// Whether `signature` is the channel's signature of `body`. Without a
/// configured secret, or without a signature, nothing verifies.
///
/// The signature covers the body only. A captured delivery can be sent
/// again; the message id in the body makes that a duplicate, which admits
/// nothing.
pub fn verified(
  secret: Option(ChannelSecret),
  signature: Result(String, Nil),
  body: BitArray,
) -> Bool {
  case secret, signature {
    Some(secret), Ok(signature) ->
      crypto.secure_compare(
        bit_array.from_string(sign(secret, body)),
        bit_array.from_string(signature),
      )
    None, _ | _, Error(Nil) -> False
  }
}
