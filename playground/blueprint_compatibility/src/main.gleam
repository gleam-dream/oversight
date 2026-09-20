// THROWAWAY: What compatibility survives an explicit adapter over the real
// json_blueprint 1.7.1 decoder, and where do its schema claims diverge?
import adapter
import gleam/io
import gleam/json
import json/blueprint as legacy
import lab/blueprint
import lab/blueprint_document
import lab/blueprint_runtime
import lab/relay
import lab/value

pub type Record {
  Record(name: String)
}

pub type Message {
  Named(String)
  Empty
}

pub fn main() {
  let record_decoder =
    legacy.decode1(Record, legacy.field("name", legacy.string()))
  let record_codec = adapter.adapt(record_decoder, encode_record)
  let assert Ok(Record("Ada")) =
    legacy.decode(using: record_decoder, from: "{\"name\":\"Ada\"}")
  let assert Ok(Record("Ada")) =
    blueprint.decode(record_codec, value.Object([#("name", value.Text("Ada"))]))
  let assert Ok(Record("Ada")) =
    legacy.decode(
      using: record_decoder,
      from: "{\"name\":\"Ada\",\"extra\":true}",
    )
  let assert Ok(Record("Ada")) =
    blueprint.decode(
      record_codec,
      value.Object([#("name", value.Text("Ada")), #("extra", value.Bool(True))]),
    )
  let assert Error(_) = legacy.decode(using: record_decoder, from: "{}")
  let assert Error(_) = blueprint.decode(record_codec, value.Object([]))
  let assert Error(_) =
    legacy.decode(using: record_decoder, from: "{\"name\":7}")
  let assert Error(_) =
    blueprint.decode(record_codec, value.Object([#("name", value.Int(7))]))
  let assert Error(blueprint.CannotDecode("Duplicate object key")) =
    blueprint.decode(
      record_codec,
      value.Object([#("name", value.Text("Ada")), #("name", value.Text("Eve"))]),
    )
  let assert Error("Duplicate object key") =
    adapter.value_to_json(
      value.Array([
        value.Object([
          #("nested", value.Bool(True)),
          #("nested", value.Bool(False)),
        ]),
      ]),
    )

  let message_decoder = message_decoder()
  let message_codec = adapter.adapt(message_decoder, encode_message)
  let named_wire = "{\"type\":\"named\",\"data\":{\"name\":\"Ada\"}}"
  let assert Ok(Named("Ada")) =
    legacy.decode(using: message_decoder, from: named_wire)
  let assert Ok(Named("Ada")) =
    blueprint.decode(
      message_codec,
      value.Object([
        #("type", value.Text("named")),
        #("data", value.Object([#("name", value.Text("Ada"))])),
      ]),
    )
  let assert Error(_) =
    legacy.decode(
      using: message_decoder,
      from: "{\"type\":\"unknown\",\"data\":{}}",
    )
  let assert Error(_) =
    legacy.decode(using: message_decoder, from: "{\"type\":\"named\"}")
  let assert Error(_) =
    legacy.decode(
      using: message_decoder,
      from: "{\"type\":\"named\",\"value\":{\"name\":\"Ada\"}}",
    )
  let assert Error(_) =
    blueprint.decode(
      message_codec,
      value.Object([
        #("type", value.Text("named")),
        #("value", value.Object([#("name", value.Text("Ada"))])),
      ]),
    )
  let assert Error(_) =
    legacy.decode(using: message_decoder, from: "{\"type\":7,\"data\":{}}")
  let assert Error(_) =
    legacy.decode(
      using: message_decoder,
      from: "{\"type\":\"named\",\"data\":{\"name\":null}}",
    )

  let empty_decoder = legacy.decode0(Empty)
  let empty_codec = adapter.adapt(empty_decoder, encode_empty)
  let assert Ok(value.Object([])) = blueprint.encode(empty_codec, Empty)
  let assert Error(blueprint.CannotEncode("Expected Empty")) =
    blueprint.encode(empty_codec, Named("must-not-collapse"))
  let assert Ok(Empty) = legacy.decode(using: empty_decoder, from: "{}")
  let assert Ok(Empty) =
    legacy.decode(using: empty_decoder, from: "{\"ignored\":true}")
  let assert Ok(Empty) = legacy.decode(using: empty_decoder, from: "5")
  let assert Ok(Empty) = legacy.decode(using: empty_decoder, from: "null")
  let assert Ok(Empty) = blueprint.decode(empty_codec, value.Object([]))
  let assert Ok(Empty) =
    blueprint.decode(
      empty_codec,
      value.Object([#("ignored", value.Bool(True))]),
    )
  let assert Ok(Empty) = blueprint.decode(empty_codec, value.Int(5))
  let assert Ok(Empty) = blueprint.decode(empty_codec, value.Null)
  let assert Ok(Empty) =
    legacy.decode(
      using: message_decoder,
      from: "{\"type\":\"empty\",\"data\":5}",
    )
  let assert Ok(Empty) =
    blueprint.decode(
      message_codec,
      value.Object([#("type", value.Text("empty")), #("data", value.Null)]),
    )

  let assert Ok(named_json) = adapter.encode_json(message_codec, Named("Ada"))
  let assert Ok(Named("Ada")) =
    legacy.decode(using: message_decoder, from: named_json)
  let assert Ok(empty_json) = adapter.encode_json(message_codec, Empty)
  let assert Ok(Empty) = legacy.decode(using: message_decoder, from: empty_json)

  let assert Error(blueprint.UnknownSchema) = blueprint.schema(record_codec)
  let assert Error(blueprint_runtime.UnknownSchema) =
    blueprint_runtime.from_codec(record_codec)
  let unregistered =
    relay.context_tool(
      "legacy_record",
      record_codec,
      blueprint.text(),
      blueprint.text(),
      fn(_context: Nil, _input) { Ok("unused") },
    )
  let assert Error(relay.SchemaUnavailable(blueprint.UnknownSchema)) =
    relay.context_declaration(unregistered)
  let assert Error(relay.InvalidDeclaration(
    "legacy_record",
    relay.SchemaUnavailable(blueprint.UnknownSchema),
  )) = relay.registry([unregistered])

  let failing_codec = adapter.adapt(record_decoder, fail_record_encode)
  let assert Error(blueprint.CannotEncode("encoder sentinel")) =
    blueprint.encode(failing_codec, Record("Ada"))
  let duplicate_codec = adapter.adapt(record_decoder, duplicate_record_encode)
  let assert Error(blueprint.CannotEncode("Duplicate object key")) =
    blueprint.encode(duplicate_codec, Record("Ada"))
  let assert Error(blueprint.CannotEncode("Duplicate object key")) =
    adapter.encode_json(duplicate_codec, Record("Ada"))
  let assert Ok(upstream_schema) = adapter.upstream_schema_value(record_decoder)
  let assert Error(blueprint_document.UnsupportedDialect(
    [blueprint_document.Property("$schema")],
    "http://json-schema.org/draft-07/schema#",
  )) = blueprint_document.load(upstream_schema)

  let tuple_decoder = legacy.tuple2(legacy.int(), legacy.string())
  let assert Ok(#(1, "one")) =
    legacy.decode(using: tuple_decoder, from: "[1,\"one\"]")
  let assert Error(_) = legacy.decode(using: tuple_decoder, from: "[\"one\",1]")
  let empty_schema = legacy.generate_json_schema(empty_decoder)
  let tuple_schema = legacy.generate_json_schema(tuple_decoder)
  io.println("SCHEMA_EMPTY:" <> json.to_string(empty_schema))
  io.println("SCHEMA_TUPLE:" <> json.to_string(tuple_schema))
  io.println("all json_blueprint adapter probes passed")
  Nil
}

pub fn message_decoder() -> legacy.Decoder(Message) {
  legacy.union_type_decoder([
    #("named", legacy.decode1(Named, legacy.field("name", legacy.string()))),
    #("empty", legacy.decode0(Empty)),
  ])
}

pub fn encode_record(
  item: Record,
) -> Result(value.Value, blueprint.EncodeError) {
  case item {
    Record(name) -> Ok(value.Object([#("name", value.Text(name))]))
  }
}

fn fail_record_encode(
  _item: Record,
) -> Result(value.Value, blueprint.EncodeError) {
  Error(blueprint.CannotEncode("encoder sentinel"))
}

fn duplicate_record_encode(
  _item: Record,
) -> Result(value.Value, blueprint.EncodeError) {
  Ok(
    value.Object([
      #("name", value.Text("first")),
      #("name", value.Text("second")),
    ]),
  )
}

fn encode_empty(item: Message) -> Result(value.Value, blueprint.EncodeError) {
  case item {
    Empty -> Ok(value.Object([]))
    Named(_) -> Error(blueprint.CannotEncode("Expected Empty"))
  }
}

pub fn encode_message(
  item: Message,
) -> Result(value.Value, blueprint.EncodeError) {
  case item {
    Named(name) ->
      Ok(
        value.Object([
          #("type", value.Text("named")),
          #("data", value.Object([#("name", value.Text(name))])),
        ]),
      )
    Empty ->
      Ok(
        value.Object([
          #("type", value.Text("empty")),
          #("data", value.Object([])),
        ]),
      )
  }
}
