// Direct historical-release behavior only; this project intentionally uses no adapter.
import gleam/io
import json/blueprint as legacy

pub type Record {
  Record(name: String)
}

pub type Message {
  Named(String)
  Empty
}

pub fn main() {
  let record = legacy.decode1(Record, legacy.field("name", legacy.string()))
  let assert Ok(Record("Ada")) =
    legacy.decode(using: record, from: "{\"name\":\"Ada\"}")
  let assert Ok(Record("Ada")) =
    legacy.decode(using: record, from: "{\"name\":\"Ada\",\"extra\":true}")
  let assert Error(_) = legacy.decode(using: record, from: "{}")
  let assert Error(_) = legacy.decode(using: record, from: "{\"name\":7}")

  let message =
    legacy.union_type_decoder([
      #("named", legacy.decode1(Named, legacy.field("name", legacy.string()))),
      #("empty", legacy.decode0(Empty)),
    ])
  let assert Ok(Named("Ada")) =
    legacy.decode(
      using: message,
      from: "{\"type\":\"named\",\"data\":{\"name\":\"Ada\"}}",
    )
  let assert Error(_) =
    legacy.decode(using: message, from: "{\"type\":\"missing\",\"data\":{}}")
  let assert Error(_) =
    legacy.decode(using: message, from: "{\"type\":\"named\"}")

  let empty = legacy.decode0(Empty)
  let assert Ok(Empty) = legacy.decode(using: empty, from: "{}")
  let assert Error(_) = legacy.decode(using: empty, from: "{\"ignored\":true}")
  let assert Error(_) = legacy.decode(using: empty, from: "5")
  let assert Error(_) = legacy.decode(using: empty, from: "null")
  io.println("json_blueprint 1.1.0 direct decoder probes passed")
  Nil
}
