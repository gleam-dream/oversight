//// Compiler-only contract sketch. No runtime backend is supplied.
//// External declarations check separate-package type composition only.

import gleam/http/request.{type Request}
import gleam/http/response.{type Response}

pub type ProtocolPreference {
  Http1Only
  PreferHttp2
  RequireHttp2
}

pub type Settings {
  Settings(protocol: ProtocolPreference, max_connections: Int)
}

pub type Limits {
  Limits(response_bytes: Int, chunk_bytes: Int, overall_timeout_ms: Int)
}

pub type Client

pub type Body

pub type BufferedResponse {
  BufferedResponse(
    response: Response(BitArray),
    trailers: List(#(String, String)),
  )
}

pub type BodyEvent {
  Chunk(bytes: BitArray)
  End(trailers: List(#(String, String)))
}

pub type Failure {
  InvalidRequest(reason: String)
  TransportFailure(reason: String)
  DeadlineExceeded
  LimitExceeded(name: String, limit: Int, measured: Int)
  ClientClosed
}

pub type ReadError {
  Failed(failure: Failure)
  ReadConflict
  BodyClosed
  WaitTimedOut
}

pub fn settings() -> Settings {
  Settings(PreferHttp2, 16)
}

pub fn limits() -> Limits {
  Limits(8_388_608, 65_536, 60_000)
}

@external(erlang, "http_gun_probe_only", "start")
pub fn start(settings: Settings) -> Result(Client, Failure)

@external(erlang, "http_gun_probe_only", "stop")
pub fn stop(client: Client) -> Result(Nil, Failure)

@external(erlang, "http_gun_probe_only", "send")
pub fn send(
  client: Client,
  request: Request(BitArray),
  limits: Limits,
) -> Result(BufferedResponse, Failure)

@external(erlang, "http_gun_probe_only", "open")
pub fn open(
  client: Client,
  request: Request(BitArray),
  limits: Limits,
) -> Result(Response(Body), Failure)

@external(erlang, "http_gun_probe_only", "next")
pub fn next(body: Body, wait_ms: Int) -> Result(BodyEvent, ReadError)

@external(erlang, "http_gun_probe_only", "close")
pub fn close(body: Body) -> Nil

@external(erlang, "http_gun_probe_only", "with_response")
pub fn with_response(
  client: Client,
  request: Request(BitArray),
  limits: Limits,
  consume: fn(Response(Body)) -> Result(value, error),
) -> Result(Result(value, error), Failure)
