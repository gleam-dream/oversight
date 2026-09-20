// THROWAWAY: Actual emitted schemas and actual decoder outcomes, not hand-copied schemas.
import consumers/object_codec
import consumers/tagged_codec
import lab/blueprint as b
import lab/blueprint_document as document
import lab/blueprint_runtime as runtime
import lab/value as v

@external(erlang, "schema_corpus_ffi", "emit")
fn emit(item: v.Value) -> Nil

fn check(label: String, codec: b.Codec(a), instances: List(v.Value)) -> Nil {
  let assert Ok(schema) = b.schema(codec)
  let assert Ok(contract) = runtime.from_codec(codec)
  let assert Ok(loaded) = document.load(b.schema_document(schema))
  let assert True = runtime.same_schema(contract, loaded)
  cases(label, codec, contract, b.schema_document(schema), instances)
}

fn cases(
  label: String,
  codec: b.Codec(a),
  contract: runtime.RuntimeContract,
  schema: v.Value,
  instances: List(v.Value),
) -> Nil {
  case instances {
    [] -> Nil
    [instance, ..rest] -> {
      let accepted = case b.decode(codec, instance) {
        Ok(_) -> True
        Error(_) -> False
      }
      let runtime_accepted = case runtime.validate(contract, instance) {
        Ok(_) -> True
        Error(_) -> False
      }
      emit(
        v.Object([
          #("label", v.Text(label)),
          #("schema", schema),
          #("instance", instance),
          #("accepted", v.Bool(accepted)),
          #("runtime_accepted", v.Bool(runtime_accepted)),
          #("normalized_schema", b.schema_document(runtime.schema(contract))),
        ]),
      )
      cases(label, codec, contract, schema, rest)
    }
  }
}

pub fn main() -> Nil {
  check("text", b.text(), [v.Text("hello"), v.Int(1), v.Null])
  check("integer", b.int(), [v.Int(0), v.Text("1"), v.Bool(True)])
  check("boolean", b.bool(), [v.Bool(False), v.Int(0)])
  check("pair", b.pair(b.text(), b.int()), [
    v.Array([v.Text("a"), v.Int(1)]),
    v.Array([]),
    v.Array([v.Text("a")]),
    v.Array([v.Text("a"), v.Int(1), v.Int(2)]),
    v.Array([v.Int(1), v.Text("a")]),
  ])
  check("list-nullable", b.list(b.nullable(b.int())), [
    v.Array([]),
    v.Array([v.Null, v.Int(2)]),
    v.Array([v.Text("bad")]),
    v.Null,
  ])
  check("empty-object", b.object(b.empty()), [
    v.Object([]),
    v.Object([#("x", v.Int(1))]),
    v.Null,
  ])
  check("optional-nullable-record", object_codec.update_codec(), [
    v.Object([#("name", v.Text("Ada"))]),
    v.Object([#("name", v.Text("Ada")), #("note", v.Null)]),
    v.Object([#("name", v.Text("Ada")), #("note", v.Text("hello"))]),
    v.Object([#("name", v.Text("Ada")), #("note", v.Int(1))]),
    v.Object([#("name", v.Text("Ada")), #("unknown", v.Null)]),
    v.Object([]),
  ])
  let assert Ok(range) = b.integer_between(-2, 2)
  check("inclusive-bounds", range, [
    v.Int(-3),
    v.Int(-2),
    v.Int(0),
    v.Int(2),
    v.Int(3),
    v.Text("2"),
  ])
  check("tagged-decision", tagged_codec.decision_codec(), [
    v.Object([
      #("tag", v.Text("approve")),
      #("value", v.Object([#("quantity", v.Int(1))])),
    ]),
    v.Object([
      #("tag", v.Text("approve")),
      #("value", v.Object([#("quantity", v.Int(0))])),
    ]),
    v.Object([
      #("tag", v.Text("decline")),
      #("value", v.Object([#("reason", v.Text("stock"))])),
    ]),
    v.Object([#("tag", v.Text("unknown")), #("value", v.Null)]),
    v.Object([#("tag", v.Text("approve"))]),
    v.Object([
      #("tag", v.Text("decline")),
      #(
        "value",
        v.Object([#("reason", v.Text("stock")), #("extra", v.Bool(True))]),
      ),
    ]),
  ])
  Nil
}
