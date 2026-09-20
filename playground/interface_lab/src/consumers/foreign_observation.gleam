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
  let callback =
    sinal.handler(fn(duration: Int, run: String) {
      let assert 17 = duration
      let assert "import" = run
      Ok(Nil)
    })
  let assert Ok(Nil) =
    sinal.deliver_foreign(observation.event(), callback, measurements, metadata)
  let forbidden =
    sinal.handler(fn(_: Int, _: String) {
      panic as "Malformed data must not invoke typed handler"
    })
  let bad = fields.FieldMap([#("duration", value.Text("bad"))])
  let assert Error(sinal.MalformedMeasurements(fields.InvalidField(
    "duration",
    _,
  ))) = sinal.deliver_foreign(observation.event(), forbidden, bad, metadata)
  let assert Error(sinal.MalformedMetadata(fields.MissingField("run"))) =
    sinal.deliver_foreign(
      observation.event(),
      forbidden,
      measurements,
      fields.FieldMap([]),
    )
  let failing =
    sinal.handler(fn(_: Int, _: String) { Error(StorageUnavailable) })
  let assert Error(sinal.HandlerReturned(StorageUnavailable)) =
    sinal.deliver_foreign(observation.event(), failing, measurements, metadata)
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
