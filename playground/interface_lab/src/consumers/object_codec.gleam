// THROWAWAY: Ordinary records compose without a custom raw codec.
import lab/blueprint as b
import lab/relay
import lab/value as v

pub type Update {
  Update(name: String, note: b.Optional(b.Nullable(String)))
}

pub fn update_codec() -> b.Codec(Update) {
  let assert Ok(properties) =
    b.combine(
      b.required("name", b.text()),
      b.optional("note", b.nullable(b.text())),
    )
  b.imap(
    b.object(properties),
    fn(fields) { Update(fields.0, fields.1) },
    fn(update) { #(update.name, update.note) },
  )
}

pub fn probe() -> Nil {
  let codec = update_codec()
  let assert Ok(Update("Ada", b.Missing)) =
    b.decode(codec, v.Object([#("name", v.Text("Ada"))]))
  let assert Ok(Update("Ada", b.Present(b.Null))) =
    b.decode(codec, v.Object([#("note", v.Null), #("name", v.Text("Ada"))]))
  let assert Ok(Update("Ada", b.Present(b.NonNull("hello")))) =
    b.decode(
      codec,
      v.Object([#("note", v.Text("hello")), #("name", v.Text("Ada"))]),
    )
  let assert Ok(v.Object([#("name", v.Text("Ada"))])) =
    b.encode(codec, Update("Ada", b.Missing))
  let assert Ok(v.Object([#("name", v.Text("Ada")), #("note", v.Null)])) =
    b.encode(codec, Update("Ada", b.Present(b.Null)))
  let assert Error(b.DecodeAtField("name", _)) = b.decode(codec, v.Object([]))
  let assert Error(b.DecodeAtField("extra", _)) =
    b.decode(codec, v.Object([#("name", v.Text("Ada")), #("extra", v.Int(3))]))
  let assert Error(b.DecodeAtField("name", _)) =
    b.decode(
      codec,
      v.Object([#("name", v.Text("Ada")), #("name", v.Text("Bea"))]),
    )
  let assert Error(b.DuplicateProperty("name")) =
    b.combine(b.required("name", b.text()), b.optional("name", b.int()))
  let assert Error(b.DecodeAtField("note", _)) =
    b.decode(
      b.object(b.optional("note", b.text())),
      v.Object([#("note", v.Null)]),
    )
  let assert Ok(Nil) = b.decode(b.object(b.empty()), v.Object([]))
  let assert Error(_) =
    b.decode(b.object(b.empty()), v.Object([#("unexpected", v.Bool(True))]))
  let tool =
    relay.tool("update", codec, b.text(), b.text(), fn(update) {
      Ok(update.name)
    })
  let assert Ok(declaration) = relay.declaration(tool)
  let assert True =
    declaration.input_schema
    == b.ObjectSchema([
      b.PropertySchema("name", True, b.TextSchema),
      b.PropertySchema("note", False, b.NullableSchema(b.TextSchema)),
    ])
  let assert Ok(v.Text("Ada")) =
    relay.invoke(tool, v.Object([#("name", v.Text("Ada"))]))
  let custom = b.new(fn(item: Int) { Ok(v.Int(item)) }, fn(_) { Ok(0) })
  let assert Ok(properties) =
    b.combine(b.required("name", b.text()), b.optional("custom", custom))
  let assert Error(b.UnknownSchema) = b.schema(b.object(properties))
  let assert Ok(empty_schema) = b.schema(b.object(b.empty()))
  let assert True =
    b.schema_value(empty_schema)
    == v.Object([
      #("type", v.Text("object")),
      #("properties", v.Object([])),
      #("required", v.Array([])),
      #("additionalProperties", v.Bool(False)),
    ])
  Nil
}
