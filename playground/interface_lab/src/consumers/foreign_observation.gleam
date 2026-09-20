// THROWAWAY: Exercise field decoding and callback classification, not telemetry.
import consumers/observation
import lab/blueprint
import lab/sinal
import lab/sinal_fields as fields
import lab/value

pub type Failure {
  StorageUnavailable
}

pub fn probe() -> Nil {
  let measurements =
    fields.FieldMap([#("duration", value.Int(17)), #("unrelated", value.Null)])
  let metadata = fields.FieldMap([#("run", value.Text("import"))])
  let descriptor = observation.event()
  let application_config = "import-worker"
  let callback =
    sinal.handler(
      fn(event: sinal.Event(Int, String), duration: Int, run: String) {
        let assert ["application", "completed"] = sinal.event_name(event)
        let assert "import-worker" = application_config
        let assert 17 = duration
        let assert "import" = run
        Ok(Nil)
      },
    )
  let assert Ok(Nil) =
    sinal.deliver_foreign(descriptor, callback, measurements, metadata)
  let forbidden =
    sinal.handler(fn(_event: sinal.Event(Int, String), _: Int, _: String) {
      panic as "Malformed data must not invoke typed handler"
    })
  let bad = fields.FieldMap([#("duration", value.Text("bad"))])
  let assert Error(measurement_failure) =
    sinal.deliver_foreign(descriptor, forbidden, bad, metadata)
  let assert sinal.MalformedMeasurements(fields.InvalidField("duration", _)) =
    measurement_failure
  let assert Error(metadata_failure) =
    sinal.deliver_foreign(
      descriptor,
      forbidden,
      measurements,
      fields.FieldMap([]),
    )
  let on_failure = fn(
    event: sinal.Event(Int, String),
    failure: sinal.HandlerFailure(Failure),
  ) {
    let assert ["application", "completed"] = sinal.event_name(event)
    case failure {
      sinal.MalformedMeasurements(fields.InvalidField("duration", _)) -> Nil
      sinal.MalformedMetadata(fields.MissingField("run")) -> Nil
      sinal.HandlerReturned(StorageUnavailable) -> Nil
      _ -> panic as "the failure callback received a different event failure"
    }
  }
  let assert sinal.MalformedMetadata(fields.MissingField("run")) =
    metadata_failure
  on_failure(descriptor, measurement_failure)
  on_failure(descriptor, metadata_failure)
  let failing =
    sinal.handler(fn(_event: sinal.Event(Int, String), _: Int, _: String) {
      Error(StorageUnavailable)
    })
  let assert Error(handler_failure) =
    sinal.deliver_foreign(descriptor, failing, measurements, metadata)
  let assert sinal.HandlerReturned(StorageUnavailable) = handler_failure
  on_failure(descriptor, handler_failure)
  let duration = fields.field("duration", blueprint.int())
  let assert Error(fields.DuplicateField("duration")) =
    fields.pair(duration, duration)
  let assert Ok(composed) =
    fields.pair(duration, fields.field("count", blueprint.int()))
  let assert Ok(raw) = fields.encode(composed, #(17, 4))
  let assert Ok(#(17, 4)) = fields.decode(composed, raw)
  let duplicate =
    fields.FieldMap([#("duration", value.Int(1)), #("duration", value.Int(2))])
  let assert Error(fields.DuplicateField("duration")) =
    fields.decode(duration, duplicate)
  Nil
}
