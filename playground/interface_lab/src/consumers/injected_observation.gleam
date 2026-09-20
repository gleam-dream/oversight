// THROWAWAY: Can an injected backend connect typed producers and subscribers?
import consumers/observation
import lab/blueprint
import lab/sinal
import lab/sinal_fields as fields
import lab/value

pub type SubscriberError {
  ObservationDeclined
}

type ScriptedState {
  ScriptedState(registrations: List(Registration), records: List(ScriptRecord))
}

type Registration {
  Registration(
    id: sinal.HandlerId,
    names: List(List(String)),
    callback: fn(List(String), fields.FieldMap, fields.FieldMap) ->
      sinal.CallbackDisposition,
  )
}

type ScriptRecord {
  BackendEmitted(List(String), fields.FieldMap, fields.FieldMap)
  HandlerObserved(List(String), Int, String)
  FailureObserved(List(String), sinal.HandlerFailure(SubscriberError))
  UnexpectedBackendSelection(List(String))
}

@external(erlang, "sinal_scripted_backend", "get")
fn get_scripted_state(key: Int, default: ScriptedState) -> ScriptedState

@external(erlang, "sinal_scripted_backend", "put")
fn put_scripted_state(key: Int, state: ScriptedState) -> Nil

@external(erlang, "erlang", "unique_integer")
fn fresh_script_key() -> Int

pub fn probe() -> Nil {
  let panic_backend =
    sinal.backend(
      fn(_, _, _) { panic as "failed encoding must not call the backend" },
      fn(_, _, _) { panic as "emission must not attach a handler" },
    )
  let failed_integer_codec =
    blueprint.new(
      fn(_) { Error(blueprint.CannotEncode("outbound sentinel")) },
      fn(_) { Error(blueprint.CannotDecode("unused inbound sentinel")) },
    )
  let failed_event =
    sinal.event(
      ["application", "failed-encode"],
      fields.field("duration", failed_integer_codec),
      fields.field("run", blueprint.text()),
    )
  let assert Error(sinal.EncodingFailed(blueprint.EncodeAtField(
    "duration",
    blueprint.CannotEncode("outbound sentinel"),
  ))) = sinal.emit(panic_backend, failed_event, 17, "run-17")

  let #(backend, backend_key) = scripted_backend()
  let shared_event = observation.event()
  let shared_id = required_handler_id("shared-subscriber")
  let shared_handler = recording_subscriber(backend_key)
  let assert Ok(shared_attachment) =
    sinal.attach_many(
      backend,
      shared_id,
      shared_event,
      [secondary_event()],
      shared_handler,
      failure_observer(backend_key),
    )
  let assert Ok(Nil) = observation.completed(backend, 17, "external-producer")
  let assert Ok(Nil) = sinal.emit(backend, secondary_event(), 4, "indexer")
  let assert True = has_registration(backend_key, shared_id)
  let assert True =
    has_record(
      scripted_records(backend_key),
      BackendEmitted(
        ["application", "completed"],
        fields.FieldMap([#("duration", value.Int(17))]),
        fields.FieldMap([#("run", value.Text("external-producer"))]),
      ),
    )
  let assert True =
    has_record(
      scripted_records(backend_key),
      HandlerObserved(["application", "completed"], 17, "external-producer"),
    )
  let assert True =
    has_record(
      scripted_records(backend_key),
      BackendEmitted(
        ["application", "indexed"],
        fields.FieldMap([#("count", value.Int(4))]),
        fields.FieldMap([#("source", value.Text("indexer"))]),
      ),
    )
  let assert True =
    has_record(
      scripted_records(backend_key),
      HandlerObserved(["application", "indexed"], 4, "indexer"),
    )
  let assert Ok(Nil) = sinal.detach(shared_attachment)

  malformed_callback_is_classified_before_handler(shared_event)
  late_selected_callback_survives_detach(shared_event)
  failure_removes_only_its_registration(shared_event)
  independent_backend_keys_keep_separate_registries(shared_event)

  let rejecting_backend =
    sinal.backend(fn(_, _, _) { Error(sinal.BackendUnavailable) }, fn(_, _, _) {
      panic as "this check only exercises emission"
    })
  let assert Error(sinal.BackendFailed(sinal.BackendUnavailable)) =
    observation.completed(rejecting_backend, 4, "backend-rejected")
  Nil
}

fn malformed_callback_is_classified_before_handler(
  event: sinal.Event(Int, String),
) -> Nil {
  let #(backend, backend_key) = scripted_backend()
  let id = required_handler_id("malformed-subscriber")
  let forbidden_handler =
    sinal.handler(fn(_event, _duration, _run) {
      panic as "malformed fields must not reach the typed handler"
    })
  let assert Ok(_attachment) =
    sinal.attach(
      backend,
      id,
      event,
      forbidden_handler,
      failure_observer(backend_key),
    )
  let assert Ok(callback) = callback_for(backend_key, id)
  let disposition =
    callback(
      ["application", "completed"],
      fields.FieldMap([#("duration", value.Text("bad"))]),
      fields.FieldMap([#("run", value.Text("malformed"))]),
    )
  let assert sinal.CallbackFailed = disposition
  let assert True =
    has_malformed_measurement_failure(scripted_records(backend_key), [
      "application",
      "completed",
    ])
  let assert False = has_handler_observation(scripted_records(backend_key))
  let assert sinal.CallbackUnknownEventName(["unregistered", "event"]) =
    scripted_backend_selection(
      backend_key,
      callback,
      ["unregistered", "event"],
      fields.FieldMap([#("duration", value.Int(1))]),
      fields.FieldMap([#("run", value.Text("unknown"))]),
    )
  Nil
}

fn late_selected_callback_survives_detach(
  event: sinal.Event(Int, String),
) -> Nil {
  let #(backend, backend_key) = scripted_backend()
  let id = required_handler_id("late-subscriber")
  let handler = recording_subscriber(backend_key)
  let assert Ok(attachment) =
    sinal.attach(backend, id, event, handler, failure_observer(backend_key))
  let attachment_copy = attachment
  let assert Ok(selected_callback) = callback_for(backend_key, id)
  let assert Ok(Nil) = sinal.detach(attachment)
  let assert False = has_registration(backend_key, id)
  let assert sinal.CallbackDelivered =
    selected_callback(
      ["application", "completed"],
      fields.FieldMap([#("duration", value.Int(9))]),
      fields.FieldMap([#("run", value.Text("selected-before-detach"))]),
    )
  let assert True =
    has_record(
      scripted_records(backend_key),
      HandlerObserved(["application", "completed"], 9, "selected-before-detach"),
    )

  // Both copied values retain a detach-by-ID operation. Reusing the ID does not
  // add a generation check, so a stale copy can detach the replacement.
  let replacement_handler = recording_subscriber(backend_key)
  let assert Ok(replacement) =
    sinal.attach(
      backend,
      id,
      event,
      replacement_handler,
      failure_observer(backend_key),
    )
  let assert True = has_registration(backend_key, id)
  let assert Ok(Nil) = sinal.detach(attachment_copy)
  let assert False = has_registration(backend_key, id)
  let assert Error(sinal.NotAttached) = sinal.detach(replacement)
  Nil
}

fn failure_removes_only_its_registration(
  event: sinal.Event(Int, String),
) -> Nil {
  let #(backend, backend_key) = scripted_backend()
  let failing_id = required_handler_id("failing-subscriber")
  let surviving_id = required_handler_id("surviving-subscriber")
  let selected_event = secondary_event()
  let failing_handler =
    sinal.handler(fn(_event, _duration, _run) { Error(ObservationDeclined) })
  let surviving_handler = recording_subscriber(backend_key)
  let assert Ok(_failing_attachment) =
    sinal.attach_many(
      backend,
      failing_id,
      event,
      [selected_event],
      failing_handler,
      failure_observer(backend_key),
    )
  let assert Ok(surviving_attachment) =
    sinal.attach_many(
      backend,
      surviving_id,
      event,
      [selected_event],
      surviving_handler,
      failure_observer(backend_key),
    )
  let assert Ok(Nil) =
    sinal.emit(backend, selected_event, 23, "failure-isolation")
  let assert False = has_registration(backend_key, failing_id)
  let assert True = has_registration(backend_key, surviving_id)
  let assert True =
    has_record(
      scripted_records(backend_key),
      FailureObserved(
        ["application", "indexed"],
        sinal.HandlerReturned(ObservationDeclined),
      ),
    )
  let assert True =
    has_record(
      scripted_records(backend_key),
      HandlerObserved(["application", "indexed"], 23, "failure-isolation"),
    )
  let assert Ok(Nil) = sinal.detach(surviving_attachment)
  Nil
}

fn independent_backend_keys_keep_separate_registries(
  event: sinal.Event(Int, String),
) -> Nil {
  let #(older_backend, older_key) = scripted_backend()
  let #(newer_backend, newer_key) = scripted_backend()
  let shared_id = required_handler_id("same-id-on-independent-backends")
  let older_handler = recording_subscriber(older_key)
  let newer_handler = recording_subscriber(newer_key)
  let assert Ok(older_attachment) =
    sinal.attach(
      older_backend,
      shared_id,
      event,
      older_handler,
      failure_observer(older_key),
    )
  let assert Ok(newer_attachment) =
    sinal.attach(
      newer_backend,
      shared_id,
      event,
      newer_handler,
      failure_observer(newer_key),
    )
  let assert True = has_registration(older_key, shared_id)
  let assert True = has_registration(newer_key, shared_id)
  let assert Ok(Nil) = sinal.detach(older_attachment)
  let assert False = has_registration(older_key, shared_id)
  let assert True = has_registration(newer_key, shared_id)
  let assert Error(sinal.NotAttached) = sinal.detach(older_attachment)
  let assert True = has_registration(newer_key, shared_id)
  let assert Ok(Nil) = observation.completed(newer_backend, 6, "newer-backend")
  let assert True =
    has_record(
      scripted_records(newer_key),
      HandlerObserved(["application", "completed"], 6, "newer-backend"),
    )
  let assert False = has_handler_observation(scripted_records(older_key))
  let assert Ok(Nil) = sinal.detach(newer_attachment)
  Nil
}

fn scripted_backend() -> #(sinal.Backend, Int) {
  let key = fresh_script_key()
  write_scripted_state(key, ScriptedState([], []))
  let backend =
    sinal.backend(
      fn(name, measurements, metadata) {
        scripted_emit(key, name, measurements, metadata)
      },
      fn(id, names, callback) { scripted_attach(key, id, names, callback) },
    )
  #(backend, key)
}

fn scripted_emit(
  key: Int,
  name: List(String),
  measurements: fields.FieldMap,
  metadata: fields.FieldMap,
) -> Result(Nil, sinal.BackendError) {
  record(key, BackendEmitted(name, measurements, metadata))
  let failed_ids =
    dispatch_to_selected(
      key,
      name,
      measurements,
      metadata,
      scripted_state(key).registrations,
    )
  let state = scripted_state(key)
  write_scripted_state(
    key,
    ScriptedState(
      remove_registrations(state.registrations, failed_ids),
      state.records,
    ),
  )
  Ok(Nil)
}

fn scripted_attach(
  key: Int,
  id: sinal.HandlerId,
  names: List(List(String)),
  callback: fn(List(String), fields.FieldMap, fields.FieldMap) ->
    sinal.CallbackDisposition,
) -> Result(sinal.BackendAttachment, sinal.AttachError) {
  let state = scripted_state(key)
  case has_registration_in(state.registrations, id) {
    True -> Error(sinal.AlreadyExists)
    False -> {
      write_scripted_state(
        key,
        ScriptedState(
          [Registration(id, names, callback), ..state.registrations],
          state.records,
        ),
      )
      Ok(sinal.backend_attachment(fn() { scripted_detach(key, id) }))
    }
  }
}

fn scripted_detach(
  key: Int,
  id: sinal.HandlerId,
) -> Result(Nil, sinal.DetachError) {
  let state = scripted_state(key)
  case remove_registration(state.registrations, id) {
    Error(Nil) -> Error(sinal.NotAttached)
    Ok(remaining) -> {
      write_scripted_state(key, ScriptedState(remaining, state.records))
      Ok(Nil)
    }
  }
}

fn dispatch_to_selected(
  key: Int,
  name: List(String),
  measurements: fields.FieldMap,
  metadata: fields.FieldMap,
  registrations: List(Registration),
) -> List(sinal.HandlerId) {
  case registrations {
    [] -> []
    [Registration(id, names, callback), ..rest] ->
      case contains_name(names, name) {
        False -> dispatch_to_selected(key, name, measurements, metadata, rest)
        True ->
          case callback(name, measurements, metadata) {
            sinal.CallbackDelivered ->
              dispatch_to_selected(key, name, measurements, metadata, rest)
            sinal.CallbackFailed -> [
              id,
              ..dispatch_to_selected(key, name, measurements, metadata, rest)
            ]
            sinal.CallbackUnknownEventName(unknown_name) -> {
              record(key, UnexpectedBackendSelection(unknown_name))
              [
                id,
                ..dispatch_to_selected(key, name, measurements, metadata, rest)
              ]
            }
          }
      }
  }
}

fn remove_registrations(
  registrations: List(Registration),
  ids: List(sinal.HandlerId),
) -> List(Registration) {
  case registrations {
    [] -> []
    [registration, ..rest] ->
      case contains_id(ids, registration.id) {
        True -> remove_registrations(rest, ids)
        False -> [registration, ..remove_registrations(rest, ids)]
      }
  }
}

fn remove_registration(
  registrations: List(Registration),
  id: sinal.HandlerId,
) -> Result(List(Registration), Nil) {
  case registrations {
    [] -> Error(Nil)
    [registration, ..rest] -> {
      let Registration(found, _, _) = registration
      case found == id {
        True -> Ok(rest)
        False ->
          case remove_registration(rest, id) {
            Error(Nil) -> Error(Nil)
            Ok(remaining) -> Ok([registration, ..remaining])
          }
      }
    }
  }
}

fn callback_for(
  key: Int,
  id: sinal.HandlerId,
) -> Result(
  fn(List(String), fields.FieldMap, fields.FieldMap) ->
    sinal.CallbackDisposition,
  Nil,
) {
  find_callback(scripted_state(key).registrations, id)
}

fn find_callback(
  registrations: List(Registration),
  id: sinal.HandlerId,
) -> Result(
  fn(List(String), fields.FieldMap, fields.FieldMap) ->
    sinal.CallbackDisposition,
  Nil,
) {
  case registrations {
    [] -> Error(Nil)
    [Registration(found, _, callback), ..rest] ->
      case found == id {
        True -> Ok(callback)
        False -> find_callback(rest, id)
      }
  }
}

fn recording_subscriber(
  key: Int,
) -> sinal.Handler(Int, String, SubscriberError) {
  sinal.handler(fn(event, duration, run_label) {
    record(key, HandlerObserved(sinal.event_name(event), duration, run_label))
    Ok(Nil)
  })
}

fn failure_observer(
  key: Int,
) -> fn(sinal.Event(Int, String), sinal.HandlerFailure(SubscriberError)) -> Nil {
  fn(event, failure) {
    record(key, FailureObserved(sinal.event_name(event), failure))
  }
}

fn record(key: Int, event: ScriptRecord) -> Nil {
  let state = scripted_state(key)
  write_scripted_state(
    key,
    ScriptedState(state.registrations, append(state.records, [event])),
  )
}

fn scripted_state(key: Int) -> ScriptedState {
  get_scripted_state(key, ScriptedState([], []))
}

fn write_scripted_state(key: Int, state: ScriptedState) -> Nil {
  let _ = put_scripted_state(key, state)
  Nil
}

fn has_registration(key: Int, id: sinal.HandlerId) -> Bool {
  has_registration_in(scripted_state(key).registrations, id)
}

fn has_registration_in(
  registrations: List(Registration),
  id: sinal.HandlerId,
) -> Bool {
  case registrations {
    [] -> False
    [Registration(found, _, _), ..rest] ->
      found == id || has_registration_in(rest, id)
  }
}

fn contains_name(names: List(List(String)), expected: List(String)) -> Bool {
  case names {
    [] -> False
    [name, ..rest] -> name == expected || contains_name(rest, expected)
  }
}

fn contains_id(ids: List(sinal.HandlerId), expected: sinal.HandlerId) -> Bool {
  case ids {
    [] -> False
    [id, ..rest] -> id == expected || contains_id(rest, expected)
  }
}

fn scripted_records(key: Int) -> List(ScriptRecord) {
  scripted_state(key).records
}

fn has_record(records: List(ScriptRecord), expected: ScriptRecord) -> Bool {
  case records {
    [] -> False
    [record, ..rest] -> record == expected || has_record(rest, expected)
  }
}

fn has_handler_observation(records: List(ScriptRecord)) -> Bool {
  case records {
    [] -> False
    [HandlerObserved(_, _, _), ..] -> True
    [_, ..rest] -> has_handler_observation(rest)
  }
}

fn has_malformed_measurement_failure(
  records: List(ScriptRecord),
  expected_name: List(String),
) -> Bool {
  case records {
    [] -> False
    [
      FailureObserved(
        name,
        sinal.MalformedMeasurements(fields.InvalidField("duration", _)),
      ),
      ..rest
    ] ->
      name == expected_name
      || has_malformed_measurement_failure(rest, expected_name)
    [_, ..rest] -> has_malformed_measurement_failure(rest, expected_name)
  }
}

fn required_handler_id(name: String) -> sinal.HandlerId {
  let assert Ok(id) = sinal.handler_id(name)
  id
}

fn secondary_event() -> sinal.Event(Int, String) {
  sinal.event(
    ["application", "indexed"],
    fields.field("count", blueprint.int()),
    fields.field("source", blueprint.text()),
  )
}

fn scripted_backend_selection(
  key: Int,
  callback: fn(List(String), fields.FieldMap, fields.FieldMap) ->
    sinal.CallbackDisposition,
  name: List(String),
  measurements: fields.FieldMap,
  metadata: fields.FieldMap,
) -> sinal.CallbackDisposition {
  case callback(name, measurements, metadata) {
    sinal.CallbackUnknownEventName(unknown_name) -> {
      record(key, UnexpectedBackendSelection(unknown_name))
      sinal.CallbackUnknownEventName(unknown_name)
    }
    disposition -> disposition
  }
}

fn append(left: List(a), right: List(a)) -> List(a) {
  case left {
    [] -> right
    [item, ..rest] -> [item, ..append(rest, right)]
  }
}
