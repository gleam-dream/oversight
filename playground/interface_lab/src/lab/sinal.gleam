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
  Handler(run: fn(m, d) -> Result(Nil, e))
}

pub fn handler(run: fn(m, d) -> Result(Nil, e)) -> Handler(m, d, e) {
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
          case handler.run(m, d) {
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
  BackendNotAvailable
}

pub type DetachError {
  NotAttached
  DetachBackendNotAvailable
}

pub fn attach(
  _id: HandlerId,
  _event: Event(m, d),
  _handler: Handler(m, d, e),
  _on_failure: fn(HandlerFailure(e)) -> Nil,
) -> Result(Attachment, AttachError) {
  todo as "attach native telemetry callback; errors detach it without propagating through emit"
}

pub fn detach(_attachment: Attachment) -> Result(Nil, DetachError) {
  todo as "detach by ID; copied attachment values cannot guarantee single consumption"
}
