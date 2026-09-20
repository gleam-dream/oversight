// THROWAWAY: One consumer composes independent typed Sinal span descriptors.
import lab/blueprint
import lab/sinal
import lab/sinal_fields as fields
import lab/sinal_span as span
import lab/value

pub type RequestStartMetadata {
  RequestStartMetadata(method: String, route: String)
}

pub type ResponseMeasurements {
  ResponseMeasurements(bytes: Int, retries: Int)
}

pub type RequestStopMetadata {
  RequestStopMetadata(status: Int, request_id: String)
}

/// Two independent descriptors compose at the application boundary without package runtime state.
pub fn nested_spans() -> #(
  span.Span(RequestStartMetadata, ResponseMeasurements, RequestStopMetadata),
  span.Span(RequestStartMetadata, ResponseMeasurements, RequestStopMetadata),
) {
  #(
    request_span(["service", "request"]),
    request_span(["service", "cache", "lookup"]),
  )
}

/// A span with no application metadata or extra stop measurements remains constructible.
pub fn empty_span() -> span.Span(Nil, Nil, Nil) {
  let prefix = span.event_prefix(["internal", "heartbeat"])
  let empty_fields = fields.empty()
  let assert Ok(request) =
    span.define_span(prefix, empty_fields, empty_fields, empty_fields)
  request
}

pub fn request_events(
  request: span.Span(
    RequestStartMetadata,
    ResponseMeasurements,
    RequestStopMetadata,
  ),
) -> span.SpanEvents(
  RequestStartMetadata,
  ResponseMeasurements,
  RequestStopMetadata,
) {
  span.events(request)
}

/// Each handler is constructed with the exact measurement and metadata type of its event.
pub fn request_handlers() -> #(
  sinal.Handler(
    span.StartMeasurements,
    span.StartMetadata(RequestStartMetadata),
    Nil,
  ),
  sinal.Handler(
    span.StopMeasurements(ResponseMeasurements),
    span.StopMetadata(RequestStopMetadata),
    Nil,
  ),
  sinal.Handler(
    span.ExceptionMeasurements,
    span.ExceptionMetadata(RequestStartMetadata),
    Nil,
  ),
) {
  let start: sinal.Handler(
    span.StartMeasurements,
    span.StartMetadata(RequestStartMetadata),
    Nil,
  ) = sinal.handler(fn(_event, _measurements, _metadata) { Ok(Nil) })
  let stop: sinal.Handler(
    span.StopMeasurements(ResponseMeasurements),
    span.StopMetadata(RequestStopMetadata),
    Nil,
  ) = sinal.handler(fn(_event, _measurements, _metadata) { Ok(Nil) })
  let exception: sinal.Handler(
    span.ExceptionMeasurements,
    span.ExceptionMetadata(RequestStartMetadata),
    Nil,
  ) = sinal.handler(fn(_event, _measurements, _metadata) { Ok(Nil) })

  #(start, stop, exception)
}

pub fn probe() -> Nil {
  let symbolic = span.symbolic_layout_probe()
  let assert [
    ["http", "request", "start"],
    ["http", "request", "stop"],
    ["http", "request", "exception"],
  ] = symbolic.event_names
  let assert fields.FieldMap([
    #("system_time", value.Text("symbolic-system-time-1")),
    #("monotonic_time", value.Text("symbolic-monotonic-start-1")),
  ]) = symbolic.start_measurements
  let assert fields.FieldMap([
    #("method", value.Text("GET")),
    #("route", value.Text("/orders")),
    #("telemetry_span_context", value.Text("symbolic-context-1")),
  ]) = symbolic.start_metadata
  let assert fields.FieldMap([
    #("duration", value.Text("symbolic-duration-1")),
    #("monotonic_time", value.Text("symbolic-monotonic-stop-1")),
    #("response_bytes", value.Int(512)),
    #("retry_count", value.Int(1)),
  ]) = symbolic.stop_measurements
  let assert fields.FieldMap([
    #("status", value.Int(200)),
    #("request_id", value.Text("request-1")),
    #("telemetry_span_context", value.Text("symbolic-context-1")),
  ]) = symbolic.stop_metadata
  let assert fields.FieldMap([
    #("duration", value.Text("symbolic-duration-1")),
    #("monotonic_time", value.Text("symbolic-monotonic-exception-1")),
  ]) = symbolic.exception_measurements
  let assert fields.FieldMap([
    #("method", value.Text("GET")),
    #("route", value.Text("/orders")),
    #("telemetry_span_context", value.Text("symbolic-context-1")),
    #("kind", value.Text("error")),
    #("reason", value.Text("symbolic-reason")),
    #("stacktrace", value.Text("symbolic-stacktrace")),
  ]) = symbolic.exception_metadata
  let assert ["method", "route", "telemetry_span_context"] =
    symbolic.start_metadata_names
  let assert ["status", "request_id", "telemetry_span_context"] =
    symbolic.stop_metadata_names
  let assert [
    "method",
    "route",
    "telemetry_span_context",
    "kind",
    "reason",
    "stacktrace",
  ] = symbolic.exception_metadata_names
  let assert True = symbolic.context_matches
  let assert ["http", "request", "stop"] = symbolic.success_terminal_event
  let assert True = symbolic.success_result_preserved
  let assert ["http", "request", "stop"] = symbolic.error_terminal_event
  let assert True = symbolic.error_result_preserved
  let assert True = symbolic.empty_fields_ignore_unowned
  let assert span.ReservationChecks(True, True, True, True, True, True, True) =
    symbolic.reservation_checks

  let #(outer, inner) = nested_spans()
  let _outer_events = request_events(outer)
  let _inner_events = request_events(inner)
  let _empty_events = span.events(empty_span())
  let #(_, _, _) = request_handlers()
  Nil
}

fn request_span(
  prefix: List(String),
) -> span.Span(RequestStartMetadata, ResponseMeasurements, RequestStopMetadata) {
  let event_prefix = span.event_prefix(prefix)
  let assert Ok(method_route_fields) =
    fields.pair(
      fields.field("method", blueprint.text()),
      fields.field("route", blueprint.text()),
    )
  let assert Ok(request_start_pair) =
    fields.pair(fields.empty(), method_route_fields)
  let start_metadata =
    fields.imap(
      request_start_pair,
      fn(pair) {
        let #(Nil, #(method, route)) = pair
        RequestStartMetadata(method, route)
      },
      fn(metadata) { #(Nil, #(metadata.method, metadata.route)) },
    )

  let assert Ok(response_measurement_pair) =
    fields.pair(
      fields.field("bytes", blueprint.int()),
      fields.field("retries", blueprint.int()),
    )
  let extra_measurements =
    fields.imap(
      response_measurement_pair,
      fn(pair) {
        let #(bytes, retries) = pair
        ResponseMeasurements(bytes, retries)
      },
      fn(measurements) { #(measurements.bytes, measurements.retries) },
    )

  let assert Ok(request_stop_pair) =
    fields.pair(
      fields.field("status", blueprint.int()),
      fields.field("request_id", blueprint.text()),
    )
  let stop_metadata =
    fields.imap(
      request_stop_pair,
      fn(pair) {
        let #(status, request_id) = pair
        RequestStopMetadata(status, request_id)
      },
      fn(metadata) { #(metadata.status, metadata.request_id) },
    )

  let assert Ok(request) =
    span.define_span(
      event_prefix,
      start_metadata,
      extra_measurements,
      stop_metadata,
    )
  request
}
