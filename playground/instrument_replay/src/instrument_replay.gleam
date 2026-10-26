import gleam/bit_array
import gleam/erlang/process
import gleam/http/request
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import http_gun
import http_gun/cancellation
import http_gun/cassette
import http_gun/config
import http_gun/error
import http_gun/redaction
import http_gun/telemetry
import http_gun/testing
import json/blueprint/codec
import json/blueprint/contract
import json/blueprint/value
import sinal
import sinal/correlation
import sinal/fields

@external(erlang, "instrument_replay_env", "get")
fn env(name: String) -> String

pub type Instrument {
  Instrument(id: String)
}

pub type Measurement {
  Measurement(wavelength_nm: Int, counts: Int)
}

pub type Page {
  Page(
    instrument: Instrument,
    measurements: List(Measurement),
    next: Option(Int),
  )
}

pub type Policy {
  Historical
  Strict
}

pub type RuntimePolicy {
  RuntimePolicy(codec: codec.Codec(Page), contract: contract.Contract)
}

pub type AdmissionFailure {
  Transport(error.Failure)
  HttpStatus(Int)
  Incomplete
  Parse(value.ParseError)
  Schema(contract.ValidationError)
  Decode(codec.DecodeError)
}

pub type RunObservation {
  RunObservation(run: correlation.Correlation, instrument: String)
}

fn instrument_codec() -> codec.Codec(Instrument) {
  use id <- codec.field("id", codec.string(), get: fn(i) { i.id })
  codec.success(Instrument(id:))
}

fn measurement_codec(policy: Policy) -> codec.Codec(Measurement) {
  let upper = case policy {
    Historical -> 4095
    Strict -> 100
  }
  use wavelength_nm <- codec.field(
    "wavelength_nm",
    codec.integer_between(1, 2000),
    get: fn(m) { m.wavelength_nm },
  )
  use counts <- codec.field(
    "counts",
    codec.integer_between(0, upper),
    get: fn(m) { m.counts },
  )
  codec.success(Measurement(wavelength_nm:, counts:))
}

fn page_codec(policy: Policy) -> codec.Codec(Page) {
  use instrument <- codec.field("instrument", instrument_codec(), get: fn(p) {
    p.instrument
  })
  use measurements <- codec.field(
    "measurements",
    codec.list(measurement_codec(policy)),
    get: fn(p) { p.measurements },
  )
  use next <- codec.field(
    "next",
    codec.nullable(codec.integer_between(1, 2)),
    get: fn(p) { p.next },
  )
  codec.success(Page(instrument:, measurements:, next:))
}

fn runtime_policy(policy: Policy) -> RuntimePolicy {
  // Exercise a runtime schema document, then bind to the separately retained codec.
  let assert Ok(schema_text) = codec.schema_json(page_codec(policy))
  let assert Ok(found) =
    contract.parse(
      schema_text,
      value.default_limits() |> value.with_max_bytes(4096),
    )
  RuntimePolicy(page_codec(policy), found)
}

fn limits() -> value.Limits {
  // Byte admission bounds parsing; the page codec validates the accepted shape.
  value.default_limits() |> value.with_max_bytes(512)
}

fn admitted_event() -> sinal.Event(Int, RunObservation) {
  let metadata = {
    use run <- fields.include(correlation.required_field(), get: fn(m) { m.run })
    use instrument <- fields.include(fields.string("instrument"), get: fn(m) {
      m.instrument
    })
    fields.success(RunObservation(run:, instrument:))
  }
  sinal.event(
    ["instrument_replay", "admitted"],
    fields.int("measurements"),
    metadata,
  )
}

fn settings(label: String) -> config.Config {
  let scrub =
    redaction.default()
    |> redaction.with_headers(["x-instrument-fixture"])
    |> redaction.with_query_parameters(["fixture_token"])
    |> redaction.with_body(fn(bytes) {
      case bit_array.to_string(bytes) {
        Ok(text) ->
          text
          |> string.replace("FIXTURE-BODY-MARKER", "REDACTED")
          |> bit_array.from_string
        Error(_) -> bytes
      }
    })
  config.default()
  |> config.allow_loopback
  |> config.with_label(label)
  |> config.with_redaction(scrub)
  |> config.with_max_response_body_bytes(512)
  |> config.with_request_timeout(config.After(duration.seconds(2)))
  |> config.with_shutdown_timeout(duration.seconds(1))
}

fn req(path: String, token: String) -> request.Request(BitArray) {
  let assert Ok(req) =
    request.to(env("INSTRUMENT_URL") <> path <> "&fixture_token=" <> token)
  req
  |> request.set_body(<<>>)
  |> request.set_header("authorization", "Bearer FIXTURE-HEADER-MARKER")
  |> request.set_header("x-instrument-fixture", "FIXTURE-CUSTOM-MARKER")
}

fn fetch(
  client: http_gun.Client,
  path: String,
  token: String,
  policy: RuntimePolicy,
) -> Result(Page, AdmissionFailure) {
  use response <- result.try(
    http_gun.send(client, req(path, token)) |> result.map_error(Transport),
  )
  use Nil <- result.try(case response.truncated {
    True -> Error(Incomplete)
    False -> Ok(Nil)
  })
  use Nil <- result.try(case response.response.status {
    200 -> Ok(Nil)
    other -> Error(HttpStatus(other))
  })
  use raw <- result.try(
    value.parse_bits(response.response.body, limits())
    |> result.map_error(Parse),
  )
  use validated <- result.try(
    contract.validate(policy.contract, raw) |> result.map_error(Schema),
  )
  contract.decode(policy.codec, validated) |> result.map_error(Decode)
}

fn pages(
  client: http_gun.Client,
  policy: Policy,
  run: correlation.Correlation,
  token: String,
) -> Result(List(Measurement), AdmissionFailure) {
  acquire(client, runtime_policy(policy), run, token, fn() { Nil })
}

fn acquire(
  client: http_gun.Client,
  policy: RuntimePolicy,
  run: correlation.Correlation,
  token: String,
  after_first: fn() -> Nil,
) -> Result(List(Measurement), AdmissionFailure) {
  let client = http_gun.with_correlation(client, run)
  use first <- result.try(fetch(client, "/measurements?page=1", token, policy))
  sinal.emit(
    admitted_event(),
    list.length(first.measurements),
    RunObservation(run, first.instrument.id),
  )
  assert first.next == Some(2)
  after_first()
  use second <- result.try(fetch(client, "/measurements?page=2", token, policy))
  assert second.next == None
  assert second.instrument == first.instrument
  sinal.emit(
    admitted_event(),
    list.length(second.measurements),
    RunObservation(run, second.instrument.id),
  )
  Ok(list.append(first.measurements, second.measurements))
}

fn expected() -> List(Measurement) {
  [Measurement(500, 42), Measurement(600, 4090)]
}

fn ordinary_decode() {
  let text =
    "{\"instrument\":{\"id\":\"synthetic-spectrometer\"},\"measurements\":[{\"wavelength_nm\":500,\"counts\":42}],\"next\":2}"
  let assert Ok(page) =
    codec.decode_json_with_limits(page_codec(Historical), text, limits())
  assert page
    == Page(
      Instrument("synthetic-spectrometer"),
      [Measurement(500, 42)],
      Some(2),
    )
}

fn idle(client: http_gun.Client) {
  let assert Ok(stats) = http_gun.stats(client)
  assert stats.open_bodies == 0
  assert stats.queued_requests == 0
}

fn stop(client: http_gun.Client) {
  idle(client)
  http_gun.stop(client)
  let assert Error(failure) =
    http_gun.send(client, req("/measurements?page=1", "after-stop"))
  assert error.reason(failure) == error.ClientClosed
  assert error.evidence(failure) == error.NotSent
}

fn faults(client: http_gun.Client) {
  let policy = runtime_policy(Historical)
  let assert Error(Schema(problem)) =
    fetch(client, "/invalid?page=1", "capture", policy)
  assert problem.path
    == [codec.Field("measurements"), codec.Index(0), codec.Field("counts")]
  let assert Error(Transport(problem)) =
    fetch(client, "/truncated?page=1", "capture", policy)
  assert error.status(problem) == Some(200)
  assert error.evidence(problem) == error.MaybeSent
  io.println("truncated reason: " <> error.describe(problem))
  let assert Error(Transport(problem)) =
    fetch(client, "/oversized?page=1", "capture", policy)
  assert error.status(problem) == Some(200)
  assert error.kind(problem) == error.TooLarge
  io.println("oversized reason: " <> error.describe(problem))
}

fn capture() {
  let assert Ok(recorded) =
    cassette.record(
      settings("capture"),
      env("INSTRUMENT_CASSETTE"),
      cassette.options() |> cassette.with_max_bytes(65_536),
    )
  let assert Ok(data) =
    pages(
      recorded.client,
      Historical,
      correlation.from_key("capture"),
      "capture",
    )
  assert data == expected()
  faults(recorded.client)
  let assert Ok(_) = cassette.finish(recorded.recording, duration.seconds(2))
  let assert Error(closed) =
    http_gun.send(recorded.client, req("/measurements?page=1", "capture"))
  assert error.reason(closed) == error.RecordingClosed
  stop(recorded.client)
  io.println("PASS capture: native pages, separated failures, finish and stop")
}

fn playback(label: String) -> http_gun.Client {
  let assert Ok(script) = cassette.load(env("INSTRUMENT_CASSETTE"), 65_536)
  let assert Ok(client) = testing.playback(script, settings(label))
  client
}

fn replay() {
  let client = playback("identity")
  let assert Error(mismatch) =
    http_gun.send(client, req("/measurements?page=2", "different-token"))
  assert error.reason(mismatch) == error.PlaybackMismatch(0)
  let assert Ok(data) =
    pages(
      client,
      Historical,
      correlation.from_key("offline"),
      "different-token",
    )
  assert data == expected()
  faults(client)
  let assert Error(exhausted) =
    http_gun.send(client, req("/measurements?page=1", "capture"))
  assert error.reason(exhausted) == error.PlaybackExhausted
  stop(client)
  io.println(
    "PASS offline: native equality, redacted-token match, page mismatch preserves position, faults",
  )

  let client = playback("strict")
  let assert Error(Schema(drift)) =
    pages(client, Strict, correlation.from_key("strict"), "capture")
  assert drift.path
    == [codec.Field("measurements"), codec.Index(0), codec.Field("counts")]
  assert drift.reason == codec.IntegerOutsideRange(0, 100)
  stop(client)
  let assert Ok(raw) =
    codec.encode(
      page_codec(Historical),
      Page(
        Instrument("synthetic-spectrometer"),
        [Measurement(500, 42)],
        Some(2),
      ),
    )
  let assert Ok(validated) =
    contract.validate(runtime_policy(Historical).contract, raw)
  let assert Error(codec.DecodeError([], codec.ContractMismatch)) =
    contract.decode(page_codec(Strict), validated)
  io.println(
    "PASS evolution: located range drift and explicit ContractMismatch",
  )

  let client = playback("cancel")
  cancellation.with_token(fn(token) {
    cancellation.cancel(token)
    let assert Error(cancelled) =
      http_gun.send(
        http_gun.with_cancellation(client, token),
        req("/measurements?page=1", "capture"),
      )
    assert error.reason(cancelled) == error.Cancelled
    assert error.evidence(cancelled) == error.NotSent
  })
  // Refused work must leave the first exchange available.
  let assert Ok(_) =
    fetch(client, "/measurements?page=1", "capture", runtime_policy(Historical))
  stop(client)
  io.println(
    "PASS cancellation: pre-cancelled NotSent preserves cassette position",
  )
  concurrent()
}

fn concurrent() {
  let observations = process.new_subject()
  let terminals = process.new_subject()
  let completed = process.new_subject()
  let ready = process.new_subject()
  let app_attachment =
    sinal.observe(admitted_event(), fn(count, metadata) {
      process.send(observations, #(count, metadata))
    })
  let http_attachment =
    sinal.observe(telemetry.event(), fn(_, metadata) {
      case metadata.milestone {
        telemetry.HttpTerminated(_) -> process.send(terminals, metadata)
        _ -> Nil
      }
    })
  let clients = [
    #("replay-a", playback("replay-a")),
    #("replay-b", playback("replay-b")),
  ]
  list.each(clients, fn(pair) {
    process.spawn(fn() {
      let release = process.new_subject()
      let run = correlation.from_key(pair.0)
      let outcome =
        acquire(pair.1, runtime_policy(Historical), run, "parallel-token", fn() {
          process.send(ready, release)
          let assert Ok(Nil) = process.receive(release, 3000)
          Nil
        })
      process.send(completed, #(pair.0, outcome))
    })
  })
  let releases =
    list.map(clients, fn(_) {
      let assert Ok(release) = process.receive(ready, 3000)
      release
    })
  list.each(releases, fn(release) { process.send(release, Nil) })
  list.each(clients, fn(_) {
    let assert Ok(#(_, Ok(data))) = process.receive(completed, 3000)
    assert data == expected()
  })
  let seen =
    list.map([1, 2, 3, 4], fn(_) {
      let assert Ok(#(count, metadata)) = process.receive(observations, 1000)
      assert count == 1
      assert metadata.instrument == "synthetic-spectrometer"
      metadata.run
    })
  list.each(clients, fn(pair) {
    assert list.count(seen, fn(run) { run == correlation.from_key(pair.0) })
      == 2
  })
  list.each([1, 2, 3, 4], fn(_) {
    let assert Ok(metadata) = process.receive(terminals, 1000)
    let assert Some(label) = metadata.client
    assert metadata.correlation == Some(correlation.from_key(label))
    assert metadata.mode == telemetry.Offline
  })
  let assert Ok(Nil) = sinal.detach(app_attachment)
  let assert Ok(Nil) = sinal.detach(http_attachment)
  let assert Error(Nil) = sinal.detach(app_attachment)
  list.each(clients, fn(pair) { stop(pair.1) })
  io.println(
    "PASS concurrent: independent streams, native observations and HTTP correlation, detach and stop",
  )
}

pub fn main() {
  ordinary_decode()
  case env("INSTRUMENT_MODE") {
    "capture" -> capture()
    "replay" -> replay()
    _ -> panic as "unknown instrument experiment mode"
  }
}
