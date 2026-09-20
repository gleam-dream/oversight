// THROWAWAY: Does a shared event descriptor constrain emitted values?
import lab/blueprint.{type EncodeError}
import lab/sinal_fields.{type FieldError, type FieldMap, type Fields}

pub opaque type Event(measurements, metadata) {
  Event(
    name: List(String),
    measurements: Fields(measurements),
    metadata: Fields(metadata),
  )
}

pub fn event(
  name: List(String),
  measurements: Fields(m),
  metadata: Fields(d),
) -> Event(m, d) {
  Event(name, measurements, metadata)
}

pub fn event_name(event: Event(m, d)) -> List(String) {
  event.name
}

pub type EmitError {
  EncodingFailed(EncodeError)
  BackendUnavailable
}

pub fn emit(
  _event: Event(m, d),
  _measurements: m,
  _metadata: d,
) -> Result(Nil, EmitError) {
  todo as "Synchronous telemetry bridge is outside the type experiment"
}

pub type HandlerFailure(e) {
  MalformedMeasurements(FieldError)
  MalformedMetadata(FieldError)
  HandlerReturned(e)
}

pub opaque type Handler(m, d, e) {
  Handler(run: fn(Event(m, d), m, d) -> Result(Nil, e))
}

pub fn handler(
  run: fn(Event(m, d), m, d) -> Result(Nil, e),
) -> Handler(m, d, e) {
  Handler(run)
}

// A pure callback-boundary probe. This result is NOT returned by telemetry emit.
// A future bridge must explicitly turn a returned error into its selected
// failure/detach policy; telemetry itself handles callback exceptions.
pub fn deliver_foreign(
  event: Event(m, d),
  handler: Handler(m, d, e),
  measurements: FieldMap,
  metadata: FieldMap,
) -> Result(Nil, HandlerFailure(e)) {
  case sinal_fields.decode(event.measurements, measurements) {
    Error(error) -> Error(MalformedMeasurements(error))
    Ok(m) ->
      case sinal_fields.decode(event.metadata, metadata) {
        Error(error) -> Error(MalformedMetadata(error))
        Ok(d) ->
          case handler.run(event, m, d) {
            Ok(Nil) -> Ok(Nil)
            Error(error) -> Error(HandlerReturned(error))
          }
      }
  }
}

pub opaque type HandlerId {
  HandlerId(String)
}

pub type IdentityError {
  EmptyHandlerId
}

pub fn handler_id(name: String) -> Result(HandlerId, IdentityError) {
  case name {
    "" -> Error(EmptyHandlerId)
    _ -> Ok(HandlerId(name))
  }
}

pub opaque type Attachment {
  Attachment(HandlerId)
}

pub type AttachError {
  AlreadyExists
  DuplicateEventName(List(String))
  BackendNotAvailable
}

pub type DetachError {
  NotAttached
  DetachBackendNotAvailable
}

pub fn attach(
  id: HandlerId,
  event: Event(m, d),
  handler: Handler(m, d, e),
  on_failure: fn(Event(m, d), HandlerFailure(e)) -> Nil,
) -> Result(Attachment, AttachError) {
  attach_many(id, event, [], handler, on_failure)
}

pub fn attach_many(
  _id: HandlerId,
  first: Event(m, d),
  rest: List(Event(m, d)),
  _handler: Handler(m, d, e),
  _on_failure: fn(Event(m, d), HandlerFailure(e)) -> Nil,
) -> Result(Attachment, AttachError) {
  case validate_event_names(first, rest) {
    Error(error) -> Error(error)
    Ok(Nil) ->
      todo as "attach one native handler under every admitted event descriptor"
  }
}

pub fn with_attachments(
  first: Event(m, d),
  rest: List(Event(m, d)),
  _handler: Handler(m, d, e),
  _on_failure: fn(Event(m, d), HandlerFailure(e)) -> Nil,
  _run: fn() -> a,
) -> Result(a, AttachError) {
  case validate_event_names(first, rest) {
    Error(error) -> Error(error)
    Ok(Nil) ->
      todo as "attach with a fresh private generation and detach on ordinary or caught completion"
  }
}

pub fn validate_event_names(
  first: Event(m, d),
  rest: List(Event(m, d)),
) -> Result(Nil, AttachError) {
  validate_rest_names(rest, [first.name])
}

fn validate_rest_names(
  rest: List(Event(m, d)),
  seen: List(List(String)),
) -> Result(Nil, AttachError) {
  case rest {
    [] -> Ok(Nil)
    [event, ..tail] ->
      case contains_name(seen, event.name) {
        True -> Error(DuplicateEventName(event.name))
        False -> validate_rest_names(tail, [event.name, ..seen])
      }
  }
}

fn contains_name(names: List(List(String)), expected: List(String)) -> Bool {
  case names {
    [] -> False
    [name, ..rest] -> name == expected || contains_name(rest, expected)
  }
}

pub fn detach(_attachment: Attachment) -> Result(Nil, DetachError) {
  todo as "detach by ID; copied attachment values cannot guarantee single consumption"
}
