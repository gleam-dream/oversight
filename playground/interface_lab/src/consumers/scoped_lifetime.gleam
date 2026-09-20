// THROWAWAY: Does scoped attachment run one cleanup and preserve native raises?
import lab/blueprint
import lab/sinal
import lab/sinal_exception
import lab/sinal_fields as fields
import lab/value

type Maybe(a) {
  Absent
  Present(a)
}

type AttachPlan {
  AttachAllowed
  AttachRejected
}

type DetachPlan {
  DetachSucceeds
  DetachReturnsError
  DetachRaises
}

type NativeWorkFailure {
  RaiseError
  RaiseExit
  RaiseThrow
}

type ExpectedCleanupReport {
  ExpectedReturnedCleanupError
  ExpectedRaisedCleanupError
  ExpectedNoCleanupReport
}

type Registration {
  Registration(
    id: sinal.HandlerId,
    names: List(List(String)),
    callback: fn(List(String), fields.FieldMap, fields.FieldMap) ->
      sinal.CallbackDisposition,
  )
}

type ScriptedState {
  ScriptedState(
    registrations: List(Registration),
    attach_count: Int,
    detach_count: Int,
    handler_count: Int,
    reporter_count: Int,
    selected: Maybe(
      fn(List(String), fields.FieldMap, fields.FieldMap) ->
        sinal.CallbackDisposition,
    ),
    saved_exception: Maybe(sinal_exception.BeamException),
    reported_failure: Maybe(sinal.ScopeCleanupFailure),
    attach_plan: AttachPlan,
    detach_plan: DetachPlan,
  )
}

@external(erlang, "sinal_scripted_backend", "get")
fn get_scripted_state(key: Int, default: ScriptedState) -> ScriptedState

@external(erlang, "sinal_scripted_backend", "put")
fn put_scripted_state(key: Int, state: ScriptedState) -> Nil

@external(erlang, "erlang", "unique_integer")
fn fresh_script_key() -> Int

@external(erlang, "sinal_scope_ffi", "capture")
fn capture_exception(
  work: fn() -> a,
) -> Result(a, sinal_exception.BeamException)

@external(erlang, "sinal_scope_ffi", "raise_error")
fn raise_native_error() -> a

@external(erlang, "sinal_scope_ffi", "raise_exit")
fn raise_native_exit() -> a

@external(erlang, "sinal_scope_ffi", "raise_throw")
fn raise_native_throw() -> a

@external(erlang, "sinal_scope_ffi", "raise_cleanup")
fn raise_cleanup_exception() -> a

pub fn probe() -> Nil {
  let event = event()
  nested_scopes_keep_business_results(event)
  attach_rejection_and_duplicates_stop_before_work(event)
  late_selected_callback_survives_scope_exit(event)
  self_removal_is_reported_by_cleanup(event)
  normal_cleanup_outcomes_keep_the_work_value(event)
  exceptional_work_cleans_once_and_reraises_exactly(event)
  Nil
}

fn nested_scopes_keep_business_results(event: sinal.Event(Int, String)) -> Nil {
  let #(backend, key) = scripted_backend(AttachAllowed, DetachSucceeds)
  let callback = recording_handler(key)
  let assert Ok(sinal.ScopedCompletion(
    Error("ordinary business rejection"),
    Ok(Nil),
  )) =
    sinal.with_attachments(
      backend,
      event,
      [],
      callback,
      ignore_handler_failure,
      ignore_cleanup_failure,
      fn() {
        let assert Ok(sinal.ScopedCompletion(23, Ok(Nil))) =
          sinal.with_attachments(
            backend,
            event,
            [],
            callback,
            ignore_handler_failure,
            ignore_cleanup_failure,
            fn() { 23 },
          )
        Error("ordinary business rejection")
      },
    )
  let assert 2 = attach_count(key)
  let assert 2 = detach_count(key)
  let assert 0 = reporter_count(key)
  Nil
}

fn attach_rejection_and_duplicates_stop_before_work(
  event: sinal.Event(Int, String),
) -> Nil {
  let #(rejecting_backend, rejecting_key) =
    scripted_backend(AttachRejected, DetachSucceeds)
  let assert Error(sinal.BackendNotAvailable) =
    sinal.with_attachments(
      rejecting_backend,
      event,
      [],
      recording_handler(rejecting_key),
      ignore_handler_failure,
      ignore_cleanup_failure,
      fn() { panic as "rejected attachment must skip scoped work" },
    )
  let assert 1 = attach_count(rejecting_key)
  let assert 0 = detach_count(rejecting_key)

  let duplicate =
    sinal.event(
      sinal.event_name(event),
      fields.field("other_duration", blueprint.int()),
      fields.field("other_actor", blueprint.text()),
    )
  let panic_backend =
    sinal.backend(
      fn(_, _, _) { panic as "duplicate names must not emit" },
      fn(_, _, _) { panic as "duplicate names must be rejected before attach" },
    )
  let assert Error(sinal.DuplicateEventName(name)) =
    sinal.with_attachments(
      panic_backend,
      event,
      [duplicate],
      recording_handler(rejecting_key),
      ignore_handler_failure,
      ignore_cleanup_failure,
      fn() { panic as "duplicate names must skip scoped work" },
    )
  let assert True = sinal.event_name(event) == name
  Nil
}

fn late_selected_callback_survives_scope_exit(
  event: sinal.Event(Int, String),
) -> Nil {
  let #(backend, key) = scripted_backend(AttachAllowed, DetachSucceeds)
  let assert Ok(sinal.ScopedCompletion("finished", Ok(Nil))) =
    sinal.with_attachments(
      backend,
      event,
      [],
      recording_handler(key),
      ignore_handler_failure,
      ignore_cleanup_failure,
      fn() { "finished" },
    )
  let assert 1 = detach_count(key)
  let assert False = has_registration(key)
  let assert Present(selected) = selected_callback(key)
  let assert sinal.CallbackDelivered =
    selected(
      sinal.event_name(event),
      fields.FieldMap([#("duration", value.Int(8))]),
      fields.FieldMap([#("actor", value.Text("late"))]),
    )
  let assert 1 = handler_count(key)
  Nil
}

fn self_removal_is_reported_by_cleanup(event: sinal.Event(Int, String)) -> Nil {
  let #(backend, key) = scripted_backend(AttachAllowed, DetachSucceeds)
  let self_removing =
    sinal.handler(fn(selected_event, _duration, _actor) {
      increment_handler_count(key)
      remove_registration_for(key, sinal.event_name(selected_event))
      Ok(Nil)
    })
  let assert Ok(sinal.ScopedCompletion(
    "handler removed itself",
    Error(sinal.DetachReturnedError(sinal.NotAttached)),
  )) =
    sinal.with_attachments(
      backend,
      event,
      [],
      self_removing,
      ignore_handler_failure,
      ignore_cleanup_failure,
      fn() {
        let assert Present(selected) = selected_callback(key)
        let assert sinal.CallbackDelivered =
          selected(
            sinal.event_name(event),
            fields.FieldMap([#("duration", value.Int(5))]),
            fields.FieldMap([#("actor", value.Text("self-remove"))]),
          )
        "handler removed itself"
      },
    )
  let assert 1 = detach_count(key)
  let assert 1 = handler_count(key)
  let assert False = has_registration(key)
  Nil
}

fn normal_cleanup_outcomes_keep_the_work_value(
  event: sinal.Event(Int, String),
) -> Nil {
  let #(returned_error_backend, returned_error_key) =
    scripted_backend(AttachAllowed, DetachReturnsError)
  let assert Ok(sinal.ScopedCompletion(
    17,
    Error(sinal.DetachReturnedError(sinal.DetachBackendNotAvailable)),
  )) =
    sinal.with_attachments(
      returned_error_backend,
      event,
      [],
      recording_handler(returned_error_key),
      ignore_handler_failure,
      recording_cleanup_observer(returned_error_key),
      fn() { 17 },
    )
  let assert 1 = detach_count(returned_error_key)
  let assert 0 = reporter_count(returned_error_key)

  let #(raised_error_backend, raised_error_key) =
    scripted_backend(AttachAllowed, DetachRaises)
  let assert Ok(sinal.ScopedCompletion(
    19,
    Error(sinal.DetachRaisedException(cleanup_exception)),
  )) =
    sinal.with_attachments(
      raised_error_backend,
      event,
      [],
      recording_handler(raised_error_key),
      ignore_handler_failure,
      recording_cleanup_observer(raised_error_key),
      fn() { 19 },
    )
  let assert sinal_exception.ErrorClass =
    sinal_exception.exception_class(cleanup_exception)
  let assert 1 = detach_count(raised_error_key)
  let assert 0 = reporter_count(raised_error_key)
  Nil
}

fn exceptional_work_cleans_once_and_reraises_exactly(
  event: sinal.Event(Int, String),
) -> Nil {
  assert_exception_preserved(
    event,
    RaiseError,
    DetachReturnsError,
    False,
    sinal_exception.ErrorClass,
    ExpectedReturnedCleanupError,
  )
  assert_exception_preserved(
    event,
    RaiseExit,
    DetachRaises,
    True,
    sinal_exception.ExitClass,
    ExpectedRaisedCleanupError,
  )
  assert_exception_preserved(
    event,
    RaiseThrow,
    DetachSucceeds,
    False,
    sinal_exception.ThrowClass,
    ExpectedNoCleanupReport,
  )
  Nil
}

fn assert_exception_preserved(
  event: sinal.Event(Int, String),
  failure: NativeWorkFailure,
  detach_plan: DetachPlan,
  reporter_raises: Bool,
  expected_class: sinal_exception.ExceptionClass,
  expected_reported_failure: ExpectedCleanupReport,
) -> Nil {
  let #(backend, key) = scripted_backend(AttachAllowed, detach_plan)
  let observer = case reporter_raises {
    True -> raising_cleanup_observer(key)
    False -> recording_cleanup_observer(key)
  }
  let assert Error(caught) =
    capture_exception(fn() {
      let _ =
        sinal.with_attachments(
          backend,
          event,
          [],
          recording_handler(key),
          ignore_handler_failure,
          observer,
          native_failure_work(key, failure),
        )
      Nil
    })
  let assert Present(original) = saved_exception(key)
  // Equality compares the complete captured BEAM triple, including its stack.
  let assert True = original == caught
  let assert True = expected_class == sinal_exception.exception_class(caught)
  let assert 1 = detach_count(key)
  case expected_reported_failure {
    ExpectedNoCleanupReport -> {
      let assert 0 = reporter_count(key)
      let assert Absent = reported_failure(key)
      Nil
    }
    ExpectedReturnedCleanupError -> {
      let assert 1 = reporter_count(key)
      let assert Present(reported) = reported_failure(key)
      let assert sinal.DetachReturnedError(sinal.DetachBackendNotAvailable) =
        reported
      Nil
    }
    ExpectedRaisedCleanupError -> {
      let assert 1 = reporter_count(key)
      let assert Present(reported) = reported_failure(key)
      let assert sinal.DetachRaisedException(cleanup_exception) = reported
      let assert sinal_exception.ErrorClass =
        sinal_exception.exception_class(cleanup_exception)
      Nil
    }
  }
  Nil
}

fn native_failure_work(key: Int, failure: NativeWorkFailure) -> fn() -> Nil {
  fn() {
    case capture_exception(fn() { raise_work_failure(failure) }) {
      Ok(_) -> panic as "the native sentinel unexpectedly returned"
      Error(original) -> {
        save_exception(key, original)
        sinal_exception.reraise(original)
      }
    }
  }
}

fn raise_work_failure(failure: NativeWorkFailure) -> Nil {
  case failure {
    RaiseError -> raise_native_error()
    RaiseExit -> raise_native_exit()
    RaiseThrow -> raise_native_throw()
  }
}

fn scripted_backend(
  attach_plan: AttachPlan,
  detach_plan: DetachPlan,
) -> #(sinal.Backend, Int) {
  let key = fresh_script_key()
  write_state(
    key,
    ScriptedState(
      [],
      0,
      0,
      0,
      0,
      Absent,
      Absent,
      Absent,
      attach_plan,
      detach_plan,
    ),
  )
  let backend =
    sinal.backend(fn(_, _, _) { Ok(Nil) }, fn(id, names, callback) {
      scripted_attach(key, id, names, callback)
    })
  #(backend, key)
}

fn scripted_attach(
  key: Int,
  id: sinal.HandlerId,
  names: List(List(String)),
  callback: fn(List(String), fields.FieldMap, fields.FieldMap) ->
    sinal.CallbackDisposition,
) -> Result(sinal.BackendAttachment, sinal.AttachError) {
  increment_attach_count(key)
  case state(key).attach_plan {
    AttachRejected -> Error(sinal.BackendNotAvailable)
    AttachAllowed -> {
      let current = state(key)
      case has_registration_with_id(current.registrations, id) {
        True -> Error(sinal.AlreadyExists)
        False -> {
          update_state(key, fn(current) {
            ScriptedState(
              ..current,
              registrations: [
                Registration(id, names, callback),
                ..current.registrations
              ],
              selected: Present(callback),
            )
          })
          Ok(sinal.backend_attachment(fn() { scripted_detach(key, id) }))
        }
      }
    }
  }
}

fn scripted_detach(
  key: Int,
  id: sinal.HandlerId,
) -> Result(Nil, sinal.DetachError) {
  increment_detach_count(key)
  case state(key).detach_plan {
    DetachReturnsError -> Error(sinal.DetachBackendNotAvailable)
    DetachRaises -> raise_cleanup_exception()
    DetachSucceeds ->
      case remove_registration_with_id(state(key).registrations, id) {
        Error(Nil) -> Error(sinal.NotAttached)
        Ok(remaining) -> {
          set_registrations(key, remaining)
          Ok(Nil)
        }
      }
  }
}

fn recording_handler(key: Int) -> sinal.Handler(Int, String, Nil) {
  sinal.handler(fn(_event, _duration, _actor) {
    increment_handler_count(key)
    Ok(Nil)
  })
}

fn ignore_handler_failure(
  _event: sinal.Event(Int, String),
  _failure: sinal.HandlerFailure(Nil),
) -> Nil {
  Nil
}

fn ignore_cleanup_failure(_failure: sinal.ScopeCleanupFailure) -> Nil {
  Nil
}

fn recording_cleanup_observer(
  key: Int,
) -> fn(sinal.ScopeCleanupFailure) -> Nil {
  fn(failure) {
    update_state(key, fn(current) {
      ScriptedState(
        ..current,
        reporter_count: current.reporter_count + 1,
        reported_failure: Present(failure),
      )
    })
  }
}

fn raising_cleanup_observer(key: Int) -> fn(sinal.ScopeCleanupFailure) -> Nil {
  fn(failure) {
    record_cleanup_failure(key, failure)
    raise_cleanup_exception()
  }
}

fn remove_registration_for(key: Int, name: List(String)) -> Nil {
  let current = state(key)
  case remove_first_matching_name(current.registrations, name) {
    Error(Nil) -> Nil
    Ok(remaining) -> set_registrations(key, remaining)
  }
}

fn remove_first_matching_name(
  registrations: List(Registration),
  name: List(String),
) -> Result(List(Registration), Nil) {
  case registrations {
    [] -> Error(Nil)
    [registration, ..rest] -> {
      let Registration(_, names, _) = registration
      case contains_name(names, name) {
        True -> Ok(rest)
        False ->
          case remove_first_matching_name(rest, name) {
            Error(Nil) -> Error(Nil)
            Ok(remaining) -> Ok([registration, ..remaining])
          }
      }
    }
  }
}

fn remove_registration_with_id(
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
          case remove_registration_with_id(rest, id) {
            Error(Nil) -> Error(Nil)
            Ok(remaining) -> Ok([registration, ..remaining])
          }
      }
    }
  }
}

fn has_registration_with_id(
  registrations: List(Registration),
  id: sinal.HandlerId,
) -> Bool {
  case registrations {
    [] -> False
    [Registration(found, _, _), ..rest] ->
      found == id || has_registration_with_id(rest, id)
  }
}

fn has_registration(key: Int) -> Bool {
  state(key).registrations != []
}

fn selected_callback(
  key: Int,
) -> Maybe(
  fn(List(String), fields.FieldMap, fields.FieldMap) ->
    sinal.CallbackDisposition,
) {
  state(key).selected
}

fn saved_exception(key: Int) -> Maybe(sinal_exception.BeamException) {
  state(key).saved_exception
}

fn reported_failure(key: Int) -> Maybe(sinal.ScopeCleanupFailure) {
  state(key).reported_failure
}

fn attach_count(key: Int) -> Int {
  state(key).attach_count
}

fn detach_count(key: Int) -> Int {
  state(key).detach_count
}

fn handler_count(key: Int) -> Int {
  state(key).handler_count
}

fn reporter_count(key: Int) -> Int {
  state(key).reporter_count
}

fn increment_attach_count(key: Int) -> Nil {
  update_state(key, fn(current) {
    ScriptedState(..current, attach_count: current.attach_count + 1)
  })
}

fn increment_detach_count(key: Int) -> Nil {
  update_state(key, fn(current) {
    ScriptedState(..current, detach_count: current.detach_count + 1)
  })
}

fn increment_handler_count(key: Int) -> Nil {
  update_state(key, fn(current) {
    ScriptedState(..current, handler_count: current.handler_count + 1)
  })
}

fn record_cleanup_failure(key: Int, failure: sinal.ScopeCleanupFailure) -> Nil {
  update_state(key, fn(current) {
    ScriptedState(
      ..current,
      reporter_count: current.reporter_count + 1,
      reported_failure: Present(failure),
    )
  })
}

fn save_exception(key: Int, exception: sinal_exception.BeamException) -> Nil {
  update_state(key, fn(current) {
    ScriptedState(..current, saved_exception: Present(exception))
  })
}

fn set_registrations(key: Int, registrations: List(Registration)) -> Nil {
  update_state(key, fn(current) {
    ScriptedState(..current, registrations: registrations)
  })
}

fn update_state(key: Int, update: fn(ScriptedState) -> ScriptedState) -> Nil {
  write_state(key, update(state(key)))
}

fn state(key: Int) -> ScriptedState {
  get_scripted_state(
    key,
    ScriptedState(
      [],
      0,
      0,
      0,
      0,
      Absent,
      Absent,
      Absent,
      AttachAllowed,
      DetachSucceeds,
    ),
  )
}

fn write_state(key: Int, state: ScriptedState) -> Nil {
  put_scripted_state(key, state)
}

fn contains_name(names: List(List(String)), expected: List(String)) -> Bool {
  case names {
    [] -> False
    [name, ..rest] -> name == expected || contains_name(rest, expected)
  }
}

fn event() -> sinal.Event(Int, String) {
  sinal.event(
    ["scope", "sample"],
    fields.field("duration", blueprint.int()),
    fields.field("actor", blueprint.text()),
  )
}
