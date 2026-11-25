//// The two keys that let the portal's stored state outlive a restart, read
//// from the environment at start-up. Both are required: without them every
//// sealed custody record and every signed cookie would be unreadable after
//// a restart, and two nodes could not share sessions.
////
//// - `SSO_PORTAL_SEALING_KEY` seals Hellhound's custody and login records
////   in PostgreSQL (`config.with_sealing_key`). It is 32 bytes, written as
////   64 hex digits or as base64, and not all zero, the rule `email_portal`
////   applies to its challenge key. Generate one with
////   `openssl rand -hex 32`.
//// - `SSO_PORTAL_SECRET_KEY_BASE` signs the portal's session cookie (wisp's
////   `secret_key_base`). Wisp requires at least 64 characters.
////
//// Changing a key is not a rotation: records sealed under the old sealing
//// key no longer open (`hellhound.SessionRecordUnreadable`, which asks an
//// operator to act and keeps the record), so every signed-in person signs
//// in again and the refresh tokens in those records are never used or
//// revoked; cookies signed under the old secret are refused, which signs
//// everyone out.

import envoy
import gleam/bit_array
import gleam/int
import gleam/result
import gleam/string
import hellhound/config

pub const sealing_key_variable = "SSO_PORTAL_SEALING_KEY"

pub const secret_key_base_variable = "SSO_PORTAL_SECRET_KEY_BASE"

const key_bytes = 32

const least_secret_key_base = 64

pub type Keys {
  Keys(sealing_key: config.SealingKey, secret_key_base: String)
}

/// Why a key was refused. Each names its environment variable.
pub type KeyError {
  KeyMissing(variable: String)
  KeyNotEncoded(variable: String)
  KeyWrongLength(variable: String, bytes: Int)
  KeyAllZero(variable: String)
  SecretTooShort(variable: String, length: Int)
}

/// Both keys from the environment.
pub fn from_environment() -> Result(Keys, KeyError) {
  from(
    sealing_key: envoy.get(sealing_key_variable),
    secret_key_base: envoy.get(secret_key_base_variable),
  )
}

/// Both keys from configured values; `Error(Nil)` is an unset variable.
pub fn from(
  sealing_key sealing_key: Result(String, Nil),
  secret_key_base secret_key_base: Result(String, Nil),
) -> Result(Keys, KeyError) {
  use sealing_key <- result.try(sealing(sealing_key))
  use secret_key_base <- result.try(secret(secret_key_base))
  Ok(Keys(sealing_key:, secret_key_base:))
}

fn sealing(
  configured: Result(String, Nil),
) -> Result(config.SealingKey, KeyError) {
  let variable = sealing_key_variable
  use text <- result.try(
    configured |> result.replace_error(KeyMissing(variable)),
  )
  let text = string.trim(text)
  // Hex first: 64 hex digits are also valid base64 of another length, while
  // padded base64 of 32 bytes is never valid hex.
  use bytes <- result.try(
    bit_array.base16_decode(text)
    |> result.lazy_or(fn() { bit_array.base64_decode(text) })
    |> result.replace_error(KeyNotEncoded(variable)),
  )
  use bytes <- result.try(case bit_array.byte_size(bytes) {
    size if size != key_bytes -> Error(KeyWrongLength(variable, size))
    _ ->
      case bytes == <<0:size(key_bytes)-unit(8)>> {
        True -> Error(KeyAllZero(variable))
        False -> Ok(bytes)
      }
  })
  config.sealing_key(bytes)
  |> result.replace_error(KeyWrongLength(variable, bit_array.byte_size(bytes)))
}

fn secret(configured: Result(String, Nil)) -> Result(String, KeyError) {
  let variable = secret_key_base_variable
  use text <- result.try(
    configured |> result.replace_error(KeyMissing(variable)),
  )
  case string.byte_size(text) >= least_secret_key_base {
    True -> Ok(text)
    False -> Error(SecretTooShort(variable, string.byte_size(text)))
  }
}

pub fn describe(error: KeyError) -> String {
  case error {
    KeyMissing(variable) -> variable <> " is not set"
    KeyNotEncoded(variable) -> variable <> " is neither hex nor base64"
    KeyWrongLength(variable, bytes) ->
      variable
      <> " decodes to "
      <> int.to_string(bytes)
      <> " bytes; it must be "
      <> int.to_string(key_bytes)
    KeyAllZero(variable) -> variable <> " is all zero bytes"
    SecretTooShort(variable, length) ->
      variable
      <> " has "
      <> int.to_string(length)
      <> " characters; it needs at least "
      <> int.to_string(least_secret_key_base)
  }
}
