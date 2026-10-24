//// Standard-Webhooks-style signing: HMAC-SHA256 over `id.timestamp.body`.
//// The `webhook-id` header doubles as the receiver's idempotency key: it is
//// the delivery id, stable across every retry of one delivery.

import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/list
import gleam/string

pub const id_header = "webhook-id"

pub const timestamp_header = "webhook-timestamp"

pub const signature_header = "webhook-signature"

/// `v1,<base64 HMAC-SHA256(secret, id "." timestamp "." body)>`.
pub fn sign(
  secret: String,
  id: String,
  timestamp: Int,
  body: BitArray,
) -> String {
  let message =
    bit_array.concat([
      bit_array.from_string(id <> "." <> int.to_string(timestamp) <> "."),
      body,
    ])
  let mac = crypto.hmac(message, crypto.Sha256, bit_array.from_string(secret))
  "v1," <> bit_array.base64_encode(mac, True)
}

/// The three signing headers, in a stable order.
pub fn headers(
  secret: String,
  id: String,
  timestamp: Int,
  body: BitArray,
) -> List(#(String, String)) {
  [
    #(id_header, id),
    #(timestamp_header, int.to_string(timestamp)),
    #(signature_header, sign(secret, id, timestamp, body)),
  ]
}

/// Receiver-side check: constant-time comparison of any listed `v1,` value.
pub fn verify(
  secret: String,
  id: String,
  timestamp: Int,
  body: BitArray,
  header: String,
) -> Bool {
  let expected = bit_array.from_string(sign(secret, id, timestamp, body))
  header
  |> string.split(" ")
  |> list.any(fn(candidate) {
    crypto.secure_compare(bit_array.from_string(candidate), expected)
  })
}
