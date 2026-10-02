//// Bounded document fetch over the fetcher's own http_gun client.
////
//// The response head is checked before any body byte is read: a non-2xx
//// status, an unsupported content type, or a declared length over the cap
//// stops the fetch, and the scope closes the body. Bodies without a usable
//// content-length are collected with the per-request cap, so the cap holds
//// even when the server lies about or omits the length.

import gleam/bit_array
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import http_gun
import http_gun/body
import http_gun/error as http_error

pub type Fetched {
  Fetched(content_type: String, text: String, bytes: Int)
}

pub type FetchError {
  InvalidUrl(url: String)
  /// The fetch never produced a usable response head.
  Transport(http_error.Failure)
  HttpStatus(status: Int)
  UnsupportedContentType(content_type: String)
  TooLarge(limit: Int, observed: Int)
  NotUtf8
}

pub type Limits {
  Limits(max_bytes: Int, accepted_types: List(String))
}

pub fn default_limits() -> Limits {
  Limits(max_bytes: 65_536, accepted_types: ["text/plain", "text/markdown"])
}

pub fn fetch(
  client: http_gun.Client,
  url: String,
  limits: Limits,
) -> Result(Fetched, FetchError) {
  use base <- result.try(
    request.to(url) |> result.replace_error(InvalidUrl(url)),
  )
  let req = request.set_body(base, <<>>)
  http_gun.try_with_response(client, req, Transport, fn(resp) {
    use content_type <- result.try(check_head(resp, limits))
    use collected <- result.try(
      body.collect(resp.body, limits.max_bytes)
      |> result.map_error(collect_error),
    )
    let size = bit_array.byte_size(collected.bytes)
    use text <- result.try(
      bit_array.to_string(collected.bytes) |> result.replace_error(NotUtf8),
    )
    Ok(Fetched(content_type:, text:, bytes: size))
  })
}

fn check_head(
  resp: response.Response(body.Body),
  limits: Limits,
) -> Result(String, FetchError) {
  use <- guard(resp.status < 200 || resp.status > 299, HttpStatus(resp.status))
  let content_type =
    response.get_header(resp, "content-type")
    |> result.unwrap("")
    |> string.split(";")
    |> list.first
    |> result.unwrap("")
    |> string.trim
    |> string.lowercase
  use <- guard(
    !list.contains(limits.accepted_types, content_type),
    UnsupportedContentType(content_type),
  )
  case response.get_header(resp, "content-length") |> result.try(int.parse) {
    Ok(declared) if declared > limits.max_bytes ->
      Error(TooLarge(limits.max_bytes, declared))
    _ -> Ok(content_type)
  }
}

fn collect_error(failure: http_error.Failure) -> FetchError {
  case failure.reason {
    http_error.LimitExceeded(http_error.CollectedBodyBytes, limit, observed) ->
      TooLarge(limit, observed)
    _ -> Transport(failure)
  }
}

fn guard(
  condition: Bool,
  error: FetchError,
  next: fn() -> Result(a, FetchError),
) -> Result(a, FetchError) {
  case condition {
    True -> Error(error)
    False -> next()
  }
}

pub fn describe(error: FetchError) -> String {
  case error {
    InvalidUrl(url) -> "invalid document URL " <> url
    Transport(failure) ->
      "document fetch failed: " <> http_error.describe(failure)
    HttpStatus(status) -> "document server answered " <> int.to_string(status)
    UnsupportedContentType(kind) -> "unsupported content type '" <> kind <> "'"
    TooLarge(limit, observed) ->
      "document exceeds "
      <> int.to_string(limit)
      <> " bytes (saw "
      <> int.to_string(observed)
      <> ")"
    NotUtf8 -> "document is not UTF-8 text"
  }
}
