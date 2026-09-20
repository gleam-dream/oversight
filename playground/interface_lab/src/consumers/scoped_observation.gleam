// THROWAWAY: Can one typed handler safely identify each selected event?
import lab/blueprint
import lab/sinal
import lab/sinal_fields as fields
import lab/value

pub type RunMetadata {
  RunMetadata(actor: String)
}

pub type ApplicationConfig {
  ApplicationConfig(service: String, tenant: String)
}

pub type HandlerProblem {
  StorageUnavailable
}

pub type AppFailure {
  ObservationRejected
}

pub fn probe() -> Nil {
  let imported = descriptor(["service", "imported"], "duration", "actor")
  let indexed = descriptor(["service", "indexed"], "count", "source")
  let config = ApplicationConfig("catalog-observer", "tenant-7")
  let observations =
    sinal.handler(
      fn(
        selected: sinal.Event(Int, RunMetadata),
        measurement: Int,
        metadata: RunMetadata,
      ) {
        let ApplicationConfig(service, tenant) = config
        let RunMetadata(actor) = metadata
        let assert True = service == "catalog-observer"
        let assert True = tenant == "tenant-7"
        case sinal.event_name(selected) {
          ["service", "imported"] -> {
            let assert 17 = measurement
            let assert "import-job" = actor
            Ok(Nil)
          }
          ["service", "indexed"] -> {
            let assert 4 = measurement
            let assert "indexer" = actor
            Ok(Nil)
          }
          _ -> panic as "the handler received an unknown event descriptor"
        }
      },
    )
  let imported_measurements = fields.FieldMap([#("duration", value.Int(17))])
  let imported_metadata =
    fields.FieldMap([
      #("actor", value.Text("import-job")),
      #("extra", value.Int(1)),
    ])
  let indexed_measurements = fields.FieldMap([#("count", value.Int(4))])
  let indexed_metadata = fields.FieldMap([#("source", value.Text("indexer"))])
  let assert ["service", "imported"] = sinal.event_name(imported)
  let assert ["service", "indexed"] = sinal.event_name(indexed)
  let assert Ok(Nil) = sinal.validate_event_names(imported, [indexed])
  let assert Error(sinal.DuplicateEventName(["service", "indexed"])) =
    sinal.validate_event_names(imported, [indexed, indexed])
  let assert Ok(Nil) =
    sinal.deliver_foreign(
      imported,
      observations,
      imported_measurements,
      imported_metadata,
    )
  let assert Ok(Nil) =
    sinal.deliver_foreign(
      indexed,
      observations,
      indexed_measurements,
      indexed_metadata,
    )

  // Decoding fails before the typed handler; the selected event and classified
  // failure are then passed together to the application's failure callback.
  let forbidden =
    sinal.handler(
      fn(
        _selected: sinal.Event(Int, RunMetadata),
        _measurement: Int,
        _metadata: RunMetadata,
      ) {
        panic as "malformed data must not invoke the typed handler"
      },
    )
  let assert Error(measurement_failure) =
    sinal.deliver_foreign(
      imported,
      forbidden,
      fields.FieldMap([#("duration", value.Text("bad"))]),
      imported_metadata,
    )
  let assert Error(metadata_failure) =
    sinal.deliver_foreign(
      indexed,
      forbidden,
      indexed_measurements,
      fields.FieldMap([]),
    )
  let fail_on_handler =
    sinal.handler(
      fn(
        _selected: sinal.Event(Int, RunMetadata),
        _measurement: Int,
        _metadata: RunMetadata,
      ) {
        Error(StorageUnavailable)
      },
    )
  let assert Error(handler_failure) =
    sinal.deliver_foreign(
      imported,
      fail_on_handler,
      imported_measurements,
      imported_metadata,
    )
  let on_failure = fn(
    selected: sinal.Event(Int, RunMetadata),
    failure: sinal.HandlerFailure(HandlerProblem),
  ) {
    let ApplicationConfig(service, tenant) = config
    let assert True = service == "catalog-observer"
    let assert True = tenant == "tenant-7"
    case sinal.event_name(selected), failure {
      ["service", "imported"],
        sinal.MalformedMeasurements(fields.InvalidField("duration", _))
      -> Nil
      ["service", "indexed"],
        sinal.MalformedMetadata(fields.MissingField("source"))
      -> Nil
      ["service", "imported"], sinal.HandlerReturned(StorageUnavailable) -> Nil
      _, _ ->
        panic as "the callback lost its descriptor or failure classification"
    }
  }
  on_failure(imported, measurement_failure)
  on_failure(indexed, metadata_failure)
  on_failure(imported, handler_failure)

  // These same-shaped descriptors have different field codecs, so duplicate
  // logical names are rejected before either runtime attachment boundary.
  let duplicate_first =
    descriptor(["service", "duplicate"], "first_count", "first_actor")
  let duplicate_second =
    descriptor(["service", "duplicate"], "second_count", "second_actor")
  let assert Error(sinal.DuplicateEventName(duplicate_name)) =
    sinal.validate_event_names(duplicate_first, [duplicate_second])
  let assert ["service", "duplicate"] = duplicate_name
  let assert Ok(handler_id) = sinal.handler_id("scoped-observation")
  let duplicate_handler =
    sinal.handler(
      fn(
        _selected: sinal.Event(Int, RunMetadata),
        _measurement: Int,
        _metadata: RunMetadata,
      ) {
        Ok(Nil)
      },
    )
  let empty_failure = fn(
    _selected: sinal.Event(Int, RunMetadata),
    _failure: sinal.HandlerFailure(Nil),
  ) {
    Nil
  }
  let admission_backend =
    sinal.backend(fn(_, _, _) { Error(sinal.BackendRejected) }, fn(_, _, _) {
      panic as "duplicate admission must not call the backend"
    })
  let assert Error(sinal.DuplicateEventName(duplicate_again)) =
    sinal.attach_many(
      admission_backend,
      handler_id,
      duplicate_first,
      [duplicate_second],
      duplicate_handler,
      empty_failure,
    )
  let assert ["service", "duplicate"] = duplicate_again
  let assert Error(sinal.DuplicateEventName(scoped_duplicate)) =
    sinal.with_attachments(
      admission_backend,
      duplicate_first,
      [duplicate_second],
      duplicate_handler,
      empty_failure,
      fn(_) { Nil },
      fn() { panic as "invalid admission must not execute scoped work" },
    )
  let assert ["service", "duplicate"] = scoped_duplicate
  Nil
}

// These wrappers prove only that the shared handler and nonempty event set
// agree at compile time. The probe never executes their runtime TODO boundary.
pub fn attach_many_shape(
  backend: sinal.Backend,
  id: sinal.HandlerId,
  first: sinal.Event(Int, RunMetadata),
  rest: List(sinal.Event(Int, RunMetadata)),
  handler: sinal.Handler(Int, RunMetadata, HandlerProblem),
  on_failure: fn(
    sinal.Event(Int, RunMetadata),
    sinal.HandlerFailure(HandlerProblem),
  ) -> Nil,
) -> Result(sinal.Attachment, sinal.AttachError) {
  sinal.attach_many(backend, id, first, rest, handler, on_failure)
}

pub fn with_attachments_shape(
  backend: sinal.Backend,
  first: sinal.Event(Int, RunMetadata),
  rest: List(sinal.Event(Int, RunMetadata)),
  handler: sinal.Handler(Int, RunMetadata, HandlerProblem),
  on_failure: fn(
    sinal.Event(Int, RunMetadata),
    sinal.HandlerFailure(HandlerProblem),
  ) -> Nil,
  on_exception_cleanup_failure: fn(sinal.ScopeCleanupFailure) -> Nil,
  run: fn() -> Result(String, AppFailure),
) -> Result(
  sinal.ScopedCompletion(Result(String, AppFailure)),
  sinal.AttachError,
) {
  sinal.with_attachments(
    backend,
    first,
    rest,
    handler,
    on_failure,
    on_exception_cleanup_failure,
    run,
  )
}

fn descriptor(
  name: List(String),
  measurement_name: String,
  metadata_name: String,
) -> sinal.Event(Int, RunMetadata) {
  let metadata =
    fields.imap(
      fields.field(metadata_name, blueprint.text()),
      RunMetadata,
      fn(value) { value.actor },
    )
  sinal.event(name, fields.field(measurement_name, blueprint.int()), metadata)
}
