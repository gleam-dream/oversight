// THROWAWAY: Construct typed span event shapes without claiming native telemetry behavior.
import lab/blueprint
import lab/sinal
import lab/sinal_fields.{type FieldMap, type Fields, FieldMap}
import lab/value.{type Value, Text}

/// Logical label strings only; they are not BEAM atoms or validated native names.
pub opaque type EventPrefix {
  EventPrefix(List(String))
}

type Lookup(a) {
  Missing
  Present(a)
}

/// Wraps logical string labels only. Production atom-backed naming remains pending.
pub fn event_prefix(segments: List(String)) -> EventPrefix {
  EventPrefix(segments)
}

/// Native values have no public constructors. The symbolic probe below uses
/// private string stand-ins only to show logical FieldMap layout.
pub opaque type SystemTime {
  SystemTime(String)
}

pub opaque type MonotonicTime {
  MonotonicTime(String)
}

pub opaque type NativeDuration {
  NativeDuration(String)
}

pub opaque type SpanContext {
  SpanContext(String)
}

pub opaque type ExceptionReason {
  ExceptionReason(String)
}

pub opaque type ExceptionStacktrace {
  ExceptionStacktrace(String)
}

pub type ExceptionKind {
  ExceptionError
  ExceptionExit
  ExceptionThrow
}

pub type StartMeasurements {
  StartMeasurements(system_time: SystemTime, monotonic_time: MonotonicTime)
}

pub type StopMeasurements(extra) {
  StopMeasurements(
    duration: NativeDuration,
    monotonic_time: MonotonicTime,
    extra: extra,
  )
}

pub type ExceptionMeasurements {
  ExceptionMeasurements(duration: NativeDuration, monotonic_time: MonotonicTime)
}

pub type StartMetadata(metadata) {
  StartMetadata(metadata: metadata, context: SpanContext)
}

pub type StopMetadata(metadata) {
  StopMetadata(metadata: metadata, context: SpanContext)
}

pub type ExceptionMetadata(metadata) {
  ExceptionMetadata(
    metadata: metadata,
    context: SpanContext,
    kind: ExceptionKind,
    reason: ExceptionReason,
    stacktrace: ExceptionStacktrace,
  )
}

pub opaque type Span(start_metadata, extra_measurements, stop_metadata) {
  Span(
    prefix: EventPrefix,
    start_metadata: Fields(start_metadata),
    extra_measurements: Fields(extra_measurements),
    stop_metadata: Fields(stop_metadata),
  )
}

pub type SpanDefinitionError {
  ReservedMeasurementField(String)
  ReservedMetadataField(String)
}

/// A reusable typed descriptor. Construction checks the labels owned by the span protocol.
pub fn define_span(
  prefix: EventPrefix,
  start_metadata: Fields(start_metadata),
  extra_measurements: Fields(extra_measurements),
  stop_metadata: Fields(stop_metadata),
) -> Result(
  Span(start_metadata, extra_measurements, stop_metadata),
  SpanDefinitionError,
) {
  case
    check_reserved(
      extra_measurements,
      ["duration", "monotonic_time"],
      ReservedMeasurementField,
    ),
    check_reserved(
      start_metadata,
      ["telemetry_span_context", "kind", "reason", "stacktrace"],
      ReservedMetadataField,
    ),
    check_reserved(
      stop_metadata,
      ["telemetry_span_context"],
      ReservedMetadataField,
    )
  {
    Ok(Nil), Ok(Nil), Ok(Nil) ->
      Ok(Span(prefix, start_metadata, extra_measurements, stop_metadata))
    Error(error), _, _ -> Error(error)
    _, Error(error), _ -> Error(error)
    _, _, Error(error) -> Error(error)
  }
}

pub type SpanEvents(start_metadata, extra_measurements, stop_metadata) {
  SpanEvents(
    start: sinal.Event(StartMeasurements, StartMetadata(start_metadata)),
    stop: sinal.Event(
      StopMeasurements(extra_measurements),
      StopMetadata(stop_metadata),
    ),
    exception: sinal.Event(
      ExceptionMeasurements,
      ExceptionMetadata(start_metadata),
    ),
  )
}

/// Creates three distinct event descriptors. Names here remain logical strings.
pub fn events(
  span: Span(start_metadata, extra_measurements, stop_metadata),
) -> SpanEvents(start_metadata, extra_measurements, stop_metadata) {
  SpanEvents(
    start: sinal.event(
      terminal_name(span.prefix, "start"),
      start_measurement_fields(),
      start_metadata_fields(span.start_metadata),
    ),
    stop: sinal.event(
      terminal_name(span.prefix, "stop"),
      stop_measurement_fields(span.extra_measurements),
      stop_metadata_fields(span.stop_metadata),
    ),
    exception: sinal.event(
      terminal_name(span.prefix, "exception"),
      exception_measurement_fields(),
      exception_metadata_fields(span.start_metadata),
    ),
  )
}

/// An ordinary return always carries a stop-shaped observation, even when `result` is `Error`.
pub type Completion(result, extra_measurements, stop_metadata) {
  Completion(
    result: result,
    measurements: extra_measurements,
    metadata: stop_metadata,
  )
}

pub type NormalCompletion(result, extra_measurements, stop_metadata) {
  NormalCompletion(
    event_name: List(String),
    result: result,
    measurements: StopMeasurements(extra_measurements),
    metadata: StopMetadata(stop_metadata),
  )
}

/// Assembles the typed ordinary-return path. This does not run work or emit an event.
pub fn normal_completion(
  span: Span(start_metadata, extra_measurements, stop_metadata),
  completion: Completion(result, extra_measurements, stop_metadata),
  duration: NativeDuration,
  monotonic_time: MonotonicTime,
  context: SpanContext,
) -> NormalCompletion(result, extra_measurements, stop_metadata) {
  let Completion(result, measurements, metadata) = completion
  NormalCompletion(
    event_name: terminal_name(span.prefix, "stop"),
    result: result,
    measurements: StopMeasurements(duration, monotonic_time, measurements),
    metadata: StopMetadata(metadata, context),
  )
}

pub type ReservationChecks {
  ReservationChecks(
    duration: Bool,
    monotonic_time: Bool,
    start_context: Bool,
    stop_context: Bool,
    kind: Bool,
    reason: Bool,
    stacktrace: Bool,
  )
}

// This output contains logical labels and symbolic stand-ins only. Its FieldMaps
// do not prove native BEAM maps, atom binding, native term retention, clocks, or re-raising.
pub type SymbolicLayoutProbe {
  SymbolicLayoutProbe(
    event_names: List(List(String)),
    start_measurements: FieldMap,
    start_metadata: FieldMap,
    stop_measurements: FieldMap,
    stop_metadata: FieldMap,
    exception_measurements: FieldMap,
    exception_metadata: FieldMap,
    start_measurement_names: List(String),
    stop_measurement_names: List(String),
    exception_measurement_names: List(String),
    start_metadata_names: List(String),
    stop_metadata_names: List(String),
    exception_metadata_names: List(String),
    context_matches: Bool,
    success_terminal_event: List(String),
    success_result_preserved: Bool,
    error_terminal_event: List(String),
    error_result_preserved: Bool,
    empty_fields_ignore_unowned: Bool,
    reservation_checks: ReservationChecks,
  )
}

/// Produces a pure layout example with private symbolic native-value stand-ins.
pub fn symbolic_layout_probe() -> SymbolicLayoutProbe {
  let span = probe_span()
  let context = SpanContext("symbolic-context-1")
  let start_measurements =
    StartMeasurements(
      SystemTime("symbolic-system-time-1"),
      MonotonicTime("symbolic-monotonic-start-1"),
    )
  let start_metadata =
    StartMetadata(ProbeStartMetadata("GET", "/orders"), context)
  let stop_extra = ProbeStopMeasurements(512, 1)
  let stop_metadata = ProbeStopMetadata(200, "request-1")
  let duration = NativeDuration("symbolic-duration-1")
  let stop_monotonic = MonotonicTime("symbolic-monotonic-stop-1")

  let assert Ok(start_measurement_map) =
    sinal_fields.encode(start_measurement_fields(), start_measurements)
  let assert Ok(start_metadata_map) =
    sinal_fields.encode(
      start_metadata_fields(probe_start_fields()),
      start_metadata,
    )
  let assert Ok(stop_measurement_map) =
    sinal_fields.encode(
      stop_measurement_fields(probe_extra_fields()),
      StopMeasurements(duration, stop_monotonic, stop_extra),
    )
  let assert Ok(stop_metadata_map) =
    sinal_fields.encode(
      stop_metadata_fields(probe_stop_fields()),
      StopMetadata(stop_metadata, context),
    )

  let exception_metadata =
    ExceptionMetadata(
      ProbeStartMetadata("GET", "/orders"),
      context,
      ExceptionError,
      ExceptionReason("symbolic-reason"),
      ExceptionStacktrace("symbolic-stacktrace"),
    )
  let assert Ok(exception_measurement_map) =
    sinal_fields.encode(
      exception_measurement_fields(),
      ExceptionMeasurements(
        duration,
        MonotonicTime("symbolic-monotonic-exception-1"),
      ),
    )
  let assert Ok(exception_metadata_map) =
    sinal_fields.encode(
      exception_metadata_fields(probe_start_fields()),
      exception_metadata,
    )

  let success =
    normal_completion(
      span,
      Completion(Ok(ProbeResponse("ok")), stop_extra, stop_metadata),
      duration,
      stop_monotonic,
      context,
    )
  let error =
    normal_completion(
      span,
      Completion(
        Error(ProbeHttpError("unavailable")),
        stop_extra,
        stop_metadata,
      ),
      duration,
      stop_monotonic,
      context,
    )

  SymbolicLayoutProbe(
    event_names: [
      terminal_name(span.prefix, "start"),
      terminal_name(span.prefix, "stop"),
      terminal_name(span.prefix, "exception"),
    ],
    start_measurements: start_measurement_map,
    start_metadata: start_metadata_map,
    stop_measurements: stop_measurement_map,
    stop_metadata: stop_metadata_map,
    exception_measurements: exception_measurement_map,
    exception_metadata: exception_metadata_map,
    start_measurement_names: field_map_names(start_measurement_map),
    stop_measurement_names: field_map_names(stop_measurement_map),
    exception_measurement_names: field_map_names(exception_measurement_map),
    start_metadata_names: field_map_names(start_metadata_map),
    stop_metadata_names: field_map_names(stop_metadata_map),
    exception_metadata_names: field_map_names(exception_metadata_map),
    context_matches: same_field(
      start_metadata_map,
      stop_metadata_map,
      "telemetry_span_context",
    ),
    success_terminal_event: success.event_name,
    success_result_preserved: case success.result {
      Ok(ProbeResponse("ok")) -> True
      _ -> False
    },
    error_terminal_event: error.event_name,
    error_result_preserved: case error.result {
      Error(ProbeHttpError("unavailable")) -> True
      _ -> False
    },
    empty_fields_ignore_unowned: case
      sinal_fields.decode(
        sinal_fields.empty(),
        FieldMap([#("foreign", Text("unowned"))]),
      )
    {
      Ok(Nil) -> True
      Error(_) -> False
    },
    reservation_checks: reservation_checks(),
  )
}

type ProbeStartMetadata {
  ProbeStartMetadata(method: String, route: String)
}

type ProbeStopMeasurements {
  ProbeStopMeasurements(response_bytes: Int, retry_count: Int)
}

type ProbeStopMetadata {
  ProbeStopMetadata(status: Int, request_id: String)
}

type ProbeResponse {
  ProbeResponse(body: String)
}

type ProbeHttpError {
  ProbeHttpError(message: String)
}

fn reservation_checks() -> ReservationChecks {
  let prefix = EventPrefix([])
  let empty_fields = sinal_fields.empty()
  ReservationChecks(
    duration: rejects_reserved(
      prefix,
      empty_fields,
      sinal_fields.field("duration", blueprint.int()),
      empty_fields,
      "duration",
      True,
    ),
    monotonic_time: rejects_reserved(
      prefix,
      empty_fields,
      sinal_fields.field("monotonic_time", blueprint.int()),
      empty_fields,
      "monotonic_time",
      True,
    ),
    start_context: rejects_reserved(
      prefix,
      sinal_fields.field("telemetry_span_context", blueprint.text()),
      empty_fields,
      empty_fields,
      "telemetry_span_context",
      False,
    ),
    stop_context: rejects_reserved(
      prefix,
      empty_fields,
      empty_fields,
      sinal_fields.field("telemetry_span_context", blueprint.text()),
      "telemetry_span_context",
      False,
    ),
    kind: rejects_reserved(
      prefix,
      sinal_fields.field("kind", blueprint.text()),
      empty_fields,
      empty_fields,
      "kind",
      False,
    ),
    reason: rejects_reserved(
      prefix,
      sinal_fields.field("reason", blueprint.text()),
      empty_fields,
      empty_fields,
      "reason",
      False,
    ),
    stacktrace: rejects_reserved(
      prefix,
      sinal_fields.field("stacktrace", blueprint.text()),
      empty_fields,
      empty_fields,
      "stacktrace",
      False,
    ),
  )
}

fn rejects_reserved(
  prefix: EventPrefix,
  start_metadata: Fields(a),
  extra_measurements: Fields(b),
  stop_metadata: Fields(c),
  expected: String,
  is_measurement: Bool,
) -> Bool {
  case define_span(prefix, start_metadata, extra_measurements, stop_metadata) {
    Error(ReservedMeasurementField(name)) -> is_measurement && name == expected
    Error(ReservedMetadataField(name)) -> !is_measurement && name == expected
    Ok(_) -> False
  }
}

fn probe_span() -> Span(
  ProbeStartMetadata,
  ProbeStopMeasurements,
  ProbeStopMetadata,
) {
  let prefix = event_prefix(["http", "request"])
  let assert Ok(span) =
    define_span(
      prefix,
      probe_start_fields(),
      probe_extra_fields(),
      probe_stop_fields(),
    )
  span
}

fn probe_start_fields() -> Fields(ProbeStartMetadata) {
  let fields =
    pair_fields(
      sinal_fields.field("method", blueprint.text()),
      sinal_fields.field("route", blueprint.text()),
    )
  sinal_fields.imap(
    fields,
    fn(pair) {
      let #(method, route) = pair
      ProbeStartMetadata(method, route)
    },
    fn(metadata) { #(metadata.method, metadata.route) },
  )
}

fn probe_extra_fields() -> Fields(ProbeStopMeasurements) {
  let fields =
    pair_fields(
      sinal_fields.field("response_bytes", blueprint.int()),
      sinal_fields.field("retry_count", blueprint.int()),
    )
  sinal_fields.imap(
    fields,
    fn(pair) {
      let #(response_bytes, retry_count) = pair
      ProbeStopMeasurements(response_bytes, retry_count)
    },
    fn(measurements) {
      #(measurements.response_bytes, measurements.retry_count)
    },
  )
}

fn probe_stop_fields() -> Fields(ProbeStopMetadata) {
  let fields =
    pair_fields(
      sinal_fields.field("status", blueprint.int()),
      sinal_fields.field("request_id", blueprint.text()),
    )
  sinal_fields.imap(
    fields,
    fn(pair) {
      let #(status, request_id) = pair
      ProbeStopMetadata(status, request_id)
    },
    fn(metadata) { #(metadata.status, metadata.request_id) },
  )
}

fn start_measurement_fields() -> Fields(StartMeasurements) {
  let fields =
    pair_fields(
      sinal_fields.field(
        "system_time",
        symbolic_string_codec(SystemTime, system_time_symbol),
      ),
      sinal_fields.field(
        "monotonic_time",
        symbolic_string_codec(MonotonicTime, monotonic_time_symbol),
      ),
    )
  sinal_fields.imap(
    fields,
    fn(pair) {
      let #(system_time, monotonic_time) = pair
      StartMeasurements(system_time, monotonic_time)
    },
    fn(measurements) {
      #(measurements.system_time, measurements.monotonic_time)
    },
  )
}

fn stop_measurement_fields(extra: Fields(a)) -> Fields(StopMeasurements(a)) {
  let timing_fields =
    pair_fields(
      sinal_fields.field(
        "duration",
        symbolic_string_codec(NativeDuration, native_duration_symbol),
      ),
      sinal_fields.field(
        "monotonic_time",
        symbolic_string_codec(MonotonicTime, monotonic_time_symbol),
      ),
    )
  let fields = pair_fields(timing_fields, extra)
  sinal_fields.imap(
    fields,
    fn(pair) {
      let #(#(duration, monotonic_time), extra) = pair
      StopMeasurements(duration, monotonic_time, extra)
    },
    fn(measurements) {
      #(
        #(measurements.duration, measurements.monotonic_time),
        measurements.extra,
      )
    },
  )
}

fn exception_measurement_fields() -> Fields(ExceptionMeasurements) {
  let fields =
    pair_fields(
      sinal_fields.field(
        "duration",
        symbolic_string_codec(NativeDuration, native_duration_symbol),
      ),
      sinal_fields.field(
        "monotonic_time",
        symbolic_string_codec(MonotonicTime, monotonic_time_symbol),
      ),
    )
  sinal_fields.imap(
    fields,
    fn(pair) {
      let #(duration, monotonic_time) = pair
      ExceptionMeasurements(duration, monotonic_time)
    },
    fn(measurements) { #(measurements.duration, measurements.monotonic_time) },
  )
}

fn start_metadata_fields(metadata: Fields(a)) -> Fields(StartMetadata(a)) {
  let fields =
    pair_fields(
      metadata,
      sinal_fields.field(
        "telemetry_span_context",
        symbolic_string_codec(SpanContext, span_context_symbol),
      ),
    )
  sinal_fields.imap(
    fields,
    fn(pair) {
      let #(metadata, context) = pair
      StartMetadata(metadata, context)
    },
    fn(value) { #(value.metadata, value.context) },
  )
}

fn stop_metadata_fields(metadata: Fields(a)) -> Fields(StopMetadata(a)) {
  let fields =
    pair_fields(
      metadata,
      sinal_fields.field(
        "telemetry_span_context",
        symbolic_string_codec(SpanContext, span_context_symbol),
      ),
    )
  sinal_fields.imap(
    fields,
    fn(pair) {
      let #(metadata, context) = pair
      StopMetadata(metadata, context)
    },
    fn(value) { #(value.metadata, value.context) },
  )
}

fn exception_metadata_fields(
  metadata: Fields(a),
) -> Fields(ExceptionMetadata(a)) {
  let user_context =
    pair_fields(
      metadata,
      sinal_fields.field(
        "telemetry_span_context",
        symbolic_string_codec(SpanContext, span_context_symbol),
      ),
    )
  let with_kind =
    pair_fields(
      user_context,
      sinal_fields.field("kind", exception_kind_codec()),
    )
  let with_reason =
    pair_fields(
      with_kind,
      sinal_fields.field(
        "reason",
        symbolic_string_codec(ExceptionReason, exception_reason_symbol),
      ),
    )
  let fields =
    pair_fields(
      with_reason,
      sinal_fields.field(
        "stacktrace",
        symbolic_string_codec(ExceptionStacktrace, exception_stacktrace_symbol),
      ),
    )
  sinal_fields.imap(
    fields,
    fn(components) {
      let #(#(#(#(metadata, context), kind), reason), stacktrace) = components
      ExceptionMetadata(metadata, context, kind, reason, stacktrace)
    },
    fn(value) {
      #(
        #(#(#(value.metadata, value.context), value.kind), value.reason),
        value.stacktrace,
      )
    },
  )
}

fn exception_kind_codec() -> blueprint.Codec(ExceptionKind) {
  blueprint.new(
    fn(kind) {
      case kind {
        ExceptionError -> Ok(Text("error"))
        ExceptionExit -> Ok(Text("exit"))
        ExceptionThrow -> Ok(Text("throw"))
      }
    },
    fn(raw) {
      case raw {
        Text("error") -> Ok(ExceptionError)
        Text("exit") -> Ok(ExceptionExit)
        Text("throw") -> Ok(ExceptionThrow)
        _ -> Error(blueprint.CannotDecode("Expected an exception kind label"))
      }
    },
  )
}

fn symbolic_string_codec(
  from: fn(String) -> a,
  to: fn(a) -> String,
) -> blueprint.Codec(a) {
  blueprint.new(fn(item) { Ok(Text(to(item))) }, fn(raw) {
    case raw {
      Text(value) -> Ok(from(value))
      _ -> Error(blueprint.CannotDecode("Expected a symbolic text value"))
    }
  })
}

fn system_time_symbol(time: SystemTime) -> String {
  let SystemTime(value) = time
  value
}

fn monotonic_time_symbol(time: MonotonicTime) -> String {
  let MonotonicTime(value) = time
  value
}

fn native_duration_symbol(duration: NativeDuration) -> String {
  let NativeDuration(value) = duration
  value
}

fn span_context_symbol(context: SpanContext) -> String {
  let SpanContext(value) = context
  value
}

fn exception_reason_symbol(reason: ExceptionReason) -> String {
  let ExceptionReason(value) = reason
  value
}

fn exception_stacktrace_symbol(stacktrace: ExceptionStacktrace) -> String {
  let ExceptionStacktrace(value) = stacktrace
  value
}

fn pair_fields(left: Fields(a), right: Fields(b)) -> Fields(#(a, b)) {
  let assert Ok(fields) = sinal_fields.pair(left, right)
  fields
}

fn check_reserved(
  fields: Fields(a),
  reserved: List(String),
  make_error: fn(String) -> SpanDefinitionError,
) -> Result(Nil, SpanDefinitionError) {
  case first_overlap(sinal_fields.declared_names(fields), reserved) {
    Missing -> Ok(Nil)
    Present(name) -> Error(make_error(name))
  }
}

fn first_overlap(
  names: List(String),
  reserved: List(String),
) -> Lookup(String) {
  case names {
    [] -> Missing
    [name, ..rest] ->
      case contains(reserved, name) {
        True -> Present(name)
        False -> first_overlap(rest, reserved)
      }
  }
}

fn contains(items: List(String), item: String) -> Bool {
  case items {
    [] -> False
    [head, ..rest] -> head == item || contains(rest, item)
  }
}

fn terminal_name(prefix: EventPrefix, terminal: String) -> List(String) {
  let EventPrefix(segments) = prefix
  append(segments, [terminal])
}

fn append(left: List(a), right: List(a)) -> List(a) {
  case left {
    [] -> right
    [item, ..rest] -> [item, ..append(rest, right)]
  }
}

fn field_map_names(fields: FieldMap) -> List(String) {
  let FieldMap(entries) = fields
  map_entry_names(entries)
}

fn map_entry_names(entries: List(#(String, Value))) -> List(String) {
  case entries {
    [] -> []
    [#(name, _), ..rest] -> [name, ..map_entry_names(rest)]
  }
}

fn same_field(left: FieldMap, right: FieldMap, name: String) -> Bool {
  case map_value(left, name), map_value(right, name) {
    Present(left_value), Present(right_value) -> left_value == right_value
    _, _ -> False
  }
}

fn map_value(fields: FieldMap, name: String) -> Lookup(Value) {
  let FieldMap(entries) = fields
  case entries {
    [] -> Missing
    [#(key, value), ..rest] ->
      case key == name {
        True -> Present(value)
        False -> map_value(FieldMap(rest), name)
      }
  }
}
