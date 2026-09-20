// THROWAWAY: Generated source leaves this package and must compile with native consumers.
import lab/blueprint as b
import lab/blueprint_codegen as codegen
import lab/blueprint_document as document
import lab/blueprint_runtime as runtime
import lab/value as v

@external(erlang, "schema_corpus_ffi", "emit")
fn emit(item: v.Value) -> Nil

fn fixture(label: String, schema: b.Schema, name: String) -> Nil {
  let rendered = b.schema_document(schema)
  let assert Ok(contract) = document.load(rendered)
  let assert Ok(generated) = codegen.generate(contract)
  emit(
    v.Object([
      #("label", v.Text(label)),
      #("source", v.Text(codegen.source(generated))),
      #("schema", b.schema_document(runtime.schema(contract))),
      #("name", v.Text(name)),
    ]),
  )
}

pub fn main() -> Nil {
  fixture(
    "record",
    b.ObjectSchema([
      b.PropertySchema("quantity", True, b.IntegerRangeSchema(1, 10)),
      b.PropertySchema("note", False, b.NullableSchema(b.TextSchema)),
      b.PropertySchema("name", True, b.TextSchema),
    ]),
    "",
  )
  fixture("empty", b.ObjectSchema([]), "")
  fixture(
    "primitives",
    b.ObjectSchema([
      b.PropertySchema(
        "deep",
        True,
        b.NullableSchema(b.NullableSchema(b.TextSchema)),
      ),
      b.PropertySchema("count", True, b.IntSchema),
      b.PropertySchema("active", True, b.BoolSchema),
    ]),
    "",
  )
  fixture(
    "enum_record",
    b.ObjectSchema([
      b.PropertySchema(
        "gamma",
        False,
        b.StringEnumSchema([
          "case",
          "",
          "é漢字😀",
          "line\nbreak",
          "quote\"label",
          "back\\slash",
        ]),
      ),
      b.PropertySchema(
        "beta",
        True,
        b.NullableSchema(
          b.StringEnumSchema([
            "case",
            "",
            "é漢字😀",
            "line\nbreak",
            "quote\"label",
            "back\\slash",
          ]),
        ),
      ),
      b.PropertySchema(
        "alpha",
        True,
        b.StringEnumSchema([
          "case",
          "",
          "é漢字😀",
          "line\nbreak",
          "quote\"label",
          "back\\slash",
        ]),
      ),
    ]),
    "",
  )
  fixture(
    "enum_single",
    b.ObjectSchema([
      b.PropertySchema("only", True, b.StringEnumSchema([""])),
    ]),
    "",
  )
  escape_fixtures([
    "",
    "case",
    "quote\"name",
    "back\\slash",
    "line\nbreak",
    "tab\tname",
    "return\rname",
    "nul\u{0}name",
    "é漢字😀",
    "\u{1}\u{7f}",
    "quote\" } pub fn injected() { \"",
  ])
}

fn escape_fixtures(names: List(String)) -> Nil {
  case names {
    [] -> Nil
    [name, ..rest] -> {
      fixture(
        "escape",
        b.ObjectSchema([
          b.PropertySchema(name, True, b.TextSchema),
        ]),
        name,
      )
      escape_fixtures(rest)
    }
  }
}
