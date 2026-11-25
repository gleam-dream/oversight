//// Who the application believes. Nothing a request says about its sender
//// is taken as identity. A member of staff signs in through the clinic's
//// OpenID provider (Hellhound verifies the login); the desk acts as the
//// validator the application's staff table names for that verified issuer
//// and subject, with the decision sets the table gives. The webhook admits
//// only a body signed with the secret the clinic shares with the messaging
//// channel.
////
//// Both are unset by default, and unset means closed: with no sign-in
//// configured every desk route answers 401, and with no channel secret so
//// does the webhook. A verified login whose subject the table does not
//// name gets no desk session.

import decisions/vocabulary.{type Validator}
import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import hellhound
import hellhound/config as hellhound_config

/// The least bytes a channel secret may have.
pub const least_secret_bytes = 32

/// How staff sign in, and who of those who sign in is staff.
pub type SignIn {
  SignIn(
    /// The relying-party configuration of the desk at the clinic's OpenID
    /// provider. Its redirect URI is the desk's `/auth/callback`.
    relying_party: hellhound_config.Config,
    /// The validator each verified subject acts as.
    staff: Staff,
  )
}

/// The people who may use the desk: the verified issuer and subject of a
/// sign-in, and the validator that sign-in acts as.
pub opaque type Staff {
  Staff(members: Dict(#(String, String), Validator))
}

/// One member of staff: the subject the provider at `issuer` signs them in
/// as, and the validator the desk acts as for them.
pub type Member {
  Member(issuer: String, subject: String, acts_as: Validator)
}

/// The staff table. A subject named twice for one issuer refuses the table.
pub fn staff(members: List(Member)) -> Result(Staff, String) {
  let keys = list.map(members, fn(member) { #(member.issuer, member.subject) })
  case list.unique(keys) == keys {
    False -> Error("two staff members share an issuer and subject")
    True ->
      Ok(
        Staff(
          list.fold(members, dict.new(), fn(table, member) {
            dict.insert(table, #(member.issuer, member.subject), member.acts_as)
          }),
        ),
      )
  }
}

/// The validator a verified sign-in acts as, when the staff table names it.
pub fn member(
  staff: Staff,
  identity: hellhound.VerifiedIdentity,
) -> Result(Validator, Nil) {
  dict.get(staff.members, #(
    hellhound.issuer(identity),
    hellhound.subject(identity),
  ))
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
