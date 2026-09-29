//// These functions are compiled, never executed by the probe.

import gleam/bit_array
import gleam/http/request
import gleam/http/response
import gleam/result
import http_gun
import http_gun/cassette

pub type Download {
  Download(bytes: BitArray, content_type: String)
}

pub type AppError {
  BadUrl
  UnexpectedStatus(status: Int)
  HttpFailed(failure: http_gun.Failure)
  BodyFailed(error: http_gun.ReadError)
  FixtureFailed(error: cassette.Error)
}

pub fn common(
  client: http_gun.Client,
  url: String,
) -> Result(Download, AppError) {
  use req <- result.try(request.to(url) |> result.replace_error(BadUrl))
  let req = request.set_body(req, <<>>)
  use received <- result.try(
    http_gun.send(client, req, http_gun.limits())
    |> result.map_error(HttpFailed),
  )
  case received.response.status {
    200 -> Ok(Download(received.response.body, content_type(received.response)))
    status -> Error(UnexpectedStatus(status))
  }
}

pub fn advanced() -> Result(http_gun.Client, AppError) {
  let settings =
    http_gun.Settings(protocol: http_gun.RequireHttp2, max_connections: 2)
  http_gun.start(settings) |> result.map_error(HttpFailed)
}

pub fn first_chunk(
  client: http_gun.Client,
  url: String,
) -> Result(Int, AppError) {
  use req <- result.try(request.to(url) |> result.replace_error(BadUrl))
  use consumed <- result.try(
    http_gun.with_response(
      client,
      request.set_body(req, <<>>),
      http_gun.limits(),
      fn(received) {
        case http_gun.next(received.body, 5000) {
          Ok(http_gun.Chunk(bytes)) -> Ok(bit_array.byte_size(bytes))
          Ok(http_gun.End(_)) -> Ok(0)
          Error(error) -> Error(BodyFailed(error))
        }
      },
    )
    |> result.map_error(HttpFailed),
  )
  consumed
}

pub fn offline(path: String) -> Result(http_gun.Client, AppError) {
  use fixture <- result.try(
    cassette.load(path, 8_388_608) |> result.map_error(FixtureFailed),
  )
  cassette.playback(fixture, http_gun.settings())
  |> result.map_error(FixtureFailed)
}

pub fn capture(
  live: http_gun.Client,
  path: String,
) -> Result(#(http_gun.Client, cassette.Recording), AppError) {
  cassette.record(live, path, 8_388_608) |> result.map_error(FixtureFailed)
}

fn content_type(received: response.Response(body)) -> String {
  response.get_header(received, "content-type")
  |> result.unwrap("application/octet-stream")
}

pub fn main() -> Nil {
  Nil
}
