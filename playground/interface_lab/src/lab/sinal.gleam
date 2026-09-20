// THROWAWAY: Does a shared event descriptor constrain emitted values?
import lab/blueprint.{type EncodeError}
import lab/sinal_exception as exception
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
  BackendFailed(BackendError)
}

pub fn emit(
  backend: Backend,
  event: Event(m, d),
  measurements: m,
  metadata: d,
) -> Result(Nil, EmitError) {
  case sinal_fields.encode(event.measurements, measurements) {
    Error(error) -> Error(EncodingFailed(error))
    Ok(raw_measurements) ->
      case sinal_fields.encode(event.metadata, metadata) {
        Error(error) -> Error(EncodingFailed(error))
        Ok(raw_metadata) -> {
          let Backend(send, _) = backend
          case send(event.name, raw_measurements, raw_metadata) {
            Ok(Nil) -> Ok(Nil)
            Error(error) -> Error(BackendFailed(error))
          }
        }
      }
  }
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
  PublicHandlerId(String)
  ScopedHandlerId(Int)
}

pub type IdentityError {
  EmptyHandlerId
}

pub fn handler_id(name: String) -> Result(HandlerId, IdentityError) {
  case name {
    "" -> Error(EmptyHandlerId)
    _ -> Ok(PublicHandlerId(name))
  }
}

@external(erlang, "erlang", "unique_integer")
fn fresh_scoped_handler_number() -> Int

pub type AttachError {
  AlreadyExists
  DuplicateEventName(List(String))
  BackendNotAvailable
}

pub type DetachError {
  NotAttached
  DetachBackendNotAvailable
}

pub type BackendError {
  BackendUnavailable
  BackendRejected
}

pub type CallbackDisposition {
  CallbackDelivered
  CallbackFailed
  CallbackUnknownEventName(List(String))
}

pub opaque type Backend {
  Backend(
    emit: fn(List(String), FieldMap, FieldMap) -> Result(Nil, BackendError),
    attach: fn(
      HandlerId,
      List(List(String)),
      fn(List(String), FieldMap, FieldMap) -> CallbackDisposition,
    ) -> Result(BackendAttachment, AttachError),
  )
}

// A configured adapter supplies these callbacks. The public constructor
// is a trust boundary for this experiment; it does not validate backend code.
pub fn backend(
  emit: fn(List(String), FieldMap, FieldMap) -> Result(Nil, BackendError),
  attach: fn(
    HandlerId,
    List(List(String)),
    fn(List(String), FieldMap, FieldMap) -> CallbackDisposition,
  ) -> Result(BackendAttachment, AttachError),
) -> Backend {
  Backend(emit, attach)
}

pub opaque type BackendAttachment {
  BackendAttachment(detach: fn() -> Result(Nil, DetachError))
}

// Called by the trusted configured adapter when it creates an attachment.
pub fn backend_attachment(
  detach: fn() -> Result(Nil, DetachError),
) -> BackendAttachment {
  BackendAttachment(detach)
}

pub opaque type Attachment {
  Attachment(BackendAttachment)
}

pub type ScopeCleanupFailure {
  DetachReturnedError(DetachError)
  DetachRaisedException(exception.BeamException)
}

pub type ScopedCompletion(a) {
  ScopedCompletion(
    work_result: a,
    cleanup_result: Result(Nil, ScopeCleanupFailure),
  )
}

@external(erlang, "sinal_scope_ffi", "with_scope")
fn native_with_scope(
  work: fn() -> a,
  cleanup: fn() -> Result(Nil, DetachError),
  on_cleanup_failure: fn(ScopeCleanupFailure) -> Nil,
) -> ScopedCompletion(a)

pub fn attach(
  backend: Backend,
  id: HandlerId,
  event: Event(m, d),
  handler: Handler(m, d, e),
  on_failure: fn(Event(m, d), HandlerFailure(e)) -> Nil,
) -> Result(Attachment, AttachError) {
  attach_many(backend, id, event, [], handler, on_failure)
}

pub fn attach_many(
  backend: Backend,
  id: HandlerId,
  first: Event(m, d),
  rest: List(Event(m, d)),
  handler: Handler(m, d, e),
  on_failure: fn(Event(m, d), HandlerFailure(e)) -> Nil,
) -> Result(Attachment, AttachError) {
  case validate_event_names(first, rest) {
    Error(error) -> Error(error)
    Ok(Nil) -> attach_validated(backend, id, first, rest, handler, on_failure)
  }
}

pub fn with_attachments(
  backend: Backend,
  first: Event(m, d),
  rest: List(Event(m, d)),
  handler: Handler(m, d, e),
  on_failure: fn(Event(m, d), HandlerFailure(e)) -> Nil,
  on_exception_cleanup_failure: fn(ScopeCleanupFailure) -> Nil,
  run: fn() -> a,
) -> Result(ScopedCompletion(a), AttachError) {
  case validate_event_names(first, rest) {
    Error(error) -> Error(error)
    Ok(Nil) -> {
      let id = ScopedHandlerId(fresh_scoped_handler_number())
      case attach_validated(backend, id, first, rest, handler, on_failure) {
        Error(error) -> Error(error)
        Ok(attachment) -> {
          Ok(native_with_scope(
            run,
            fn() { detach(attachment) },
            on_exception_cleanup_failure,
          ))
        }
      }
    }
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

pub fn detach(attachment: Attachment) -> Result(Nil, DetachError) {
  let Attachment(BackendAttachment(detach)) = attachment
  detach()
}

fn event_names(events: List(Event(m, d))) -> List(List(String)) {
  case events {
    [] -> []
    [event, ..rest] -> [event.name, ..event_names(rest)]
  }
}

fn dispatch_selected(
  events: List(Event(m, d)),
  handler: Handler(m, d, e),
  on_failure: fn(Event(m, d), HandlerFailure(e)) -> Nil,
  name: List(String),
  measurements: FieldMap,
  metadata: FieldMap,
) -> CallbackDisposition {
  case find_event(events, name) {
    Error(_) -> CallbackUnknownEventName(name)
    Ok(event) ->
      case deliver_foreign(event, handler, measurements, metadata) {
        Ok(Nil) -> CallbackDelivered
        Error(failure) -> {
          on_failure(event, failure)
          CallbackFailed
        }
      }
  }
}

fn find_event(
  events: List(Event(m, d)),
  name: List(String),
) -> Result(Event(m, d), Nil) {
  case events {
    [] -> Error(Nil)
    [event, ..rest] ->
      case event.name == name {
        True -> Ok(event)
        False -> find_event(rest, name)
      }
  }
}

fn attach_validated(
  backend: Backend,
  id: HandlerId,
  first: Event(m, d),
  rest: List(Event(m, d)),
  handler: Handler(m, d, e),
  on_failure: fn(Event(m, d), HandlerFailure(e)) -> Nil,
) -> Result(Attachment, AttachError) {
  let Backend(_, register) = backend
  let events = [first, ..rest]
  let names = event_names(events)
  let callback = fn(name, measurements, metadata) {
    dispatch_selected(events, handler, on_failure, name, measurements, metadata)
  }
  case register(id, names, callback) {
    Error(error) -> Error(error)
    Ok(backend_attachment) -> Ok(Attachment(backend_attachment))
  }
}
