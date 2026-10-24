// THROWAWAY: Can a finite runtime object produce deterministic typed Gleam source?
import lab/blueprint
import lab/blueprint_codegen as codegen
import lab/blueprint_runtime as runtime

pub fn probe() -> Nil {
  let schema =
    blueprint.ObjectSchema([
      blueprint.PropertySchema(
        "quantity",
        True,
        blueprint.IntegerRangeSchema(1, 10),
      ),
      blueprint.PropertySchema(
        "note",
        False,
        blueprint.NullableSchema(blueprint.TextSchema),
      ),
      blueprint.PropertySchema("name", True, blueprint.TextSchema),
    ])
  let reordered_schema =
    blueprint.ObjectSchema([
      blueprint.PropertySchema("name", True, blueprint.TextSchema),
      blueprint.PropertySchema(
        "note",
        False,
        blueprint.NullableSchema(blueprint.TextSchema),
      ),
      blueprint.PropertySchema(
        "quantity",
        True,
        blueprint.IntegerRangeSchema(1, 10),
      ),
    ])
  let assert Ok(contract) = runtime.from_schema(schema)
  let assert Ok(reordered_contract) = runtime.from_schema(reordered_schema)
  let assert Ok(generated) = codegen.generate(contract)
  let assert Ok(reordered_generated) = codegen.generate(reordered_contract)
  let generated_source = codegen.source(generated)
  let assert True = generated_source == codegen.source(reordered_generated)
  let assert True = generated_source == main_source()

  let assert Ok(empty_contract) =
    runtime.from_schema(blueprint.ObjectSchema([]))
  let assert Ok(empty_generated) = codegen.generate(empty_contract)
  let assert True = codegen.source(empty_generated) == empty_source()

  let assert Ok(primitives_contract) =
    runtime.from_schema(
      blueprint.ObjectSchema([
        blueprint.PropertySchema(
          "deep",
          True,
          blueprint.NullableSchema(blueprint.NullableSchema(
            blueprint.TextSchema,
          )),
        ),
        blueprint.PropertySchema("count", True, blueprint.IntSchema),
        blueprint.PropertySchema("active", True, blueprint.BoolSchema),
      ]),
    )
  let assert Ok(primitives) = codegen.generate(primitives_contract)
  let assert True = codegen.source(primitives) == primitive_source()

  let enum_schema =
    blueprint.ObjectSchema([
      blueprint.PropertySchema(
        "gamma",
        False,
        blueprint.StringEnumSchema([
          "é漢字😀",
          "quote\"label",
          "case",
          "",
          "line\nbreak",
          "back\\slash",
        ]),
      ),
      blueprint.PropertySchema(
        "beta",
        True,
        blueprint.NullableSchema(
          blueprint.StringEnumSchema([
            "case",
            "back\\slash",
            "",
            "quote\"label",
            "line\nbreak",
            "é漢字😀",
          ]),
        ),
      ),
      blueprint.PropertySchema(
        "alpha",
        True,
        blueprint.StringEnumSchema([
          "line\nbreak",
          "é漢字😀",
          "",
          "case",
          "back\\slash",
          "quote\"label",
        ]),
      ),
    ])
  let reordered_enum_schema =
    blueprint.ObjectSchema([
      blueprint.PropertySchema(
        "alpha",
        True,
        blueprint.StringEnumSchema([
          "case",
          "quote\"label",
          "back\\slash",
          "é漢字😀",
          "line\nbreak",
          "",
        ]),
      ),
      blueprint.PropertySchema(
        "beta",
        True,
        blueprint.NullableSchema(
          blueprint.StringEnumSchema([
            "quote\"label",
            "case",
            "line\nbreak",
            "back\\slash",
            "é漢字😀",
            "",
          ]),
        ),
      ),
      blueprint.PropertySchema(
        "gamma",
        False,
        blueprint.StringEnumSchema([
          "back\\slash",
          "line\nbreak",
          "case",
          "quote\"label",
          "",
          "é漢字😀",
        ]),
      ),
    ])
  let assert Ok(enum_contract) = runtime.from_schema(enum_schema)
  let assert Ok(reordered_enum_contract) =
    runtime.from_schema(reordered_enum_schema)
  let assert Ok(generated_enums) = codegen.generate(enum_contract)
  let assert Ok(reordered_enums) = codegen.generate(reordered_enum_contract)
  let enum_source = codegen.source(generated_enums)
  let assert True = enum_source == codegen.source(reordered_enums)
  let assert True = enum_source == enum_record_source()

  let assert Ok(single_empty_enum_contract) =
    runtime.from_schema(
      blueprint.ObjectSchema([
        blueprint.PropertySchema("only", True, blueprint.StringEnumSchema([""])),
      ]),
    )
  let assert Ok(single_empty_enum) =
    codegen.generate(single_empty_enum_contract)
  let assert True =
    codegen.source(single_empty_enum) == single_empty_enum_source()

  escaping_case("case", "\"case\"")
  escaping_case("quote\"name", "\"quote\\\"name\"")
  escaping_case("back\\slash", "\"back\\\\slash\"")
  escaping_case("line\nbreak", "\"line\\nbreak\"")
  escaping_case("tab\tname", "\"tab\\tname\"")
  escaping_case("return\rname", "\"return\\rname\"")
  escaping_case("nul\u{0}name", "\"nul\\u{0}name\"")
  escaping_case("\u{1}\u{7f}", "\"\\u{1}\\u{7F}\"")
  escaping_case("é漢字😀", "\"\\u{E9}\\u{6F22}\\u{5B57}\\u{1F600}\"")
  escaping_case(
    "quote\" } pub fn injected() { \"",
    "\"quote\\\" } pub fn injected() { \\\"\"",
  )

  let assert Ok(root_list) =
    runtime.from_schema(blueprint.ListSchema(blueprint.TextSchema))
  let assert Error(codegen.UnsupportedGeneration([], codegen.RootMustBeObject)) =
    codegen.generate(root_list)
  let assert Error(codegen.UnsupportedGeneration(
    [codegen.Property("rows")],
    codegen.ListSchema,
  )) =
    generate_schema(
      blueprint.ObjectSchema([
        blueprint.PropertySchema(
          "rows",
          True,
          blueprint.ListSchema(blueprint.IntSchema),
        ),
      ]),
    )
  let assert Error(codegen.UnsupportedGeneration(
    [codegen.Property("child")],
    codegen.NestedObject,
  )) =
    generate_schema(
      blueprint.ObjectSchema([
        blueprint.PropertySchema("child", True, blueprint.ObjectSchema([])),
      ]),
    )
  let assert Error(codegen.UnsupportedGeneration(
    [codegen.Property("point")],
    codegen.PairSchema,
  )) =
    generate_schema(
      blueprint.ObjectSchema([
        blueprint.PropertySchema(
          "point",
          True,
          blueprint.PairSchema(blueprint.IntSchema, blueprint.IntSchema),
        ),
      ]),
    )
  let assert Error(codegen.UnsupportedGeneration(
    [codegen.Property("choice")],
    codegen.TaggedSchema,
  )) =
    generate_schema(
      blueprint.ObjectSchema([
        blueprint.PropertySchema(
          "choice",
          True,
          blueprint.TaggedSchema(
            "left",
            blueprint.TextSchema,
            "right",
            blueprint.BoolSchema,
          ),
        ),
      ]),
    )
  let assert Error(codegen.UnsupportedGeneration(
    [codegen.Property("maybe"), codegen.NullableValue],
    codegen.ListSchema,
  )) =
    generate_schema(
      blueprint.ObjectSchema([
        blueprint.PropertySchema(
          "maybe",
          True,
          blueprint.NullableSchema(blueprint.ListSchema(blueprint.TextSchema)),
        ),
      ]),
    )
  Nil
}

fn generate_schema(
  schema: blueprint.Schema,
) -> Result(codegen.GeneratedSource, codegen.GenerationError) {
  case runtime.from_schema(schema) {
    Error(_) ->
      panic as "valid generation probe schema must form a runtime contract"
    Ok(contract) -> codegen.generate(contract)
  }
}

fn escaping_case(name: String, literal: String) -> Nil {
  let assert Ok(contract) =
    runtime.from_schema(
      blueprint.ObjectSchema([
        blueprint.PropertySchema(name, True, blueprint.TextSchema),
      ]),
    )
  let assert Ok(generated) = codegen.generate(contract)
  let assert True =
    codegen.source(generated) == one_text_property_source(literal)
  Nil
}

fn one_text_property_source(literal: String) -> String {
  "import lab/blueprint\n\n"
  <> "pub type Document {\n  Document(\n    field_0: String\n  )\n}"
  <> "\n\npub fn codec() -> blueprint.Codec(Document) {\n"
  <> "  let property_0 = blueprint.required("
  <> literal
  <> ", blueprint.text())\n"
  <> "  blueprint.imap(\n"
  <> "    blueprint.object(property_0),\n"
  <> "    fn(raw) { Document(field_0: raw) },\n"
  <> "    fn(document) { document.field_0 },\n"
  <> "  )\n}\n"
}

fn main_source() -> String {
  "import lab/blueprint\n\n"
  <> "pub type Document {\n"
  <> "  Document(\n"
  <> "    field_0: String,\n"
  <> "    field_1: blueprint.Optional(blueprint.Nullable(String)),\n"
  <> "    field_2: Int\n"
  <> "  )\n}\n\n"
  <> "pub fn codec() -> blueprint.Codec(Document) {\n"
  <> "  let assert Ok(bounded_2) = blueprint.integer_between(1, 10)\n"
  <> "  let property_0 = blueprint.required(\"name\", blueprint.text())\n"
  <> "  let property_1 = blueprint.optional(\"note\", blueprint.nullable(blueprint.text()))\n"
  <> "  let property_2 = blueprint.required(\"quantity\", bounded_2)\n"
  <> "  let assert Ok(properties_1) = blueprint.combine(property_0, property_1)\n"
  <> "  let assert Ok(properties_2) = blueprint.combine(properties_1, property_2)\n"
  <> "  blueprint.imap(\n"
  <> "    blueprint.object(properties_2),\n"
  <> "    fn(raw) { Document(field_0: raw.0.0, field_1: raw.0.1, field_2: raw.1) },\n"
  <> "    fn(document) { #(#(document.field_0, document.field_1), document.field_2) },\n"
  <> "  )\n}\n"
}

fn empty_source() -> String {
  "import lab/blueprint\n\n"
  <> "pub type Document {\n  Document\n}\n\n"
  <> "pub fn codec() -> blueprint.Codec(Document) {\n"
  <> "  blueprint.imap(\n"
  <> "    blueprint.object(blueprint.empty()),\n"
  <> "    fn(raw) { Document },\n"
  <> "    fn(document) { Nil },\n"
  <> "  )\n}\n"
}

fn primitive_source() -> String {
  "import lab/blueprint\n\n"
  <> "pub type Document {\n"
  <> "  Document(\n"
  <> "    field_0: Bool,\n"
  <> "    field_1: Int,\n"
  <> "    field_2: blueprint.Nullable(blueprint.Nullable(String))\n"
  <> "  )\n}\n\n"
  <> "pub fn codec() -> blueprint.Codec(Document) {\n"
  <> "  let property_0 = blueprint.required(\"active\", blueprint.bool())\n"
  <> "  let property_1 = blueprint.required(\"count\", blueprint.int())\n"
  <> "  let property_2 = blueprint.required(\"deep\", blueprint.nullable(blueprint.nullable(blueprint.text())))\n"
  <> "  let assert Ok(properties_1) = blueprint.combine(property_0, property_1)\n"
  <> "  let assert Ok(properties_2) = blueprint.combine(properties_1, property_2)\n"
  <> "  blueprint.imap(\n"
  <> "    blueprint.object(properties_2),\n"
  <> "    fn(raw) { Document(field_0: raw.0.0, field_1: raw.0.1, field_2: raw.1) },\n"
  <> "    fn(document) { #(#(document.field_0, document.field_1), document.field_2) },\n"
  <> "  )\n}\n"
}

fn enum_record_source() -> String {
  "import lab/blueprint\n\n"
  <> "pub type Field0Enum {\n"
  <> "  Field0Value0\n  Field0Value1\n  Field0Value2\n  Field0Value3\n  Field0Value4\n  Field0Value5\n}\n\n"
  <> "pub type Field1Enum {\n"
  <> "  Field1Value0\n  Field1Value1\n  Field1Value2\n  Field1Value3\n  Field1Value4\n  Field1Value5\n}\n\n"
  <> "pub type Field2Enum {\n"
  <> "  Field2Value0\n  Field2Value1\n  Field2Value2\n  Field2Value3\n  Field2Value4\n  Field2Value5\n}\n\n"
  <> "pub type Document {\n"
  <> "  Document(\n"
  <> "    field_0: Field0Enum,\n"
  <> "    field_1: blueprint.Nullable(Field1Enum),\n"
  <> "    field_2: blueprint.Optional(Field2Enum)\n"
  <> "  )\n}\n\n"
  <> "pub fn codec() -> blueprint.Codec(Document) {\n"
  <> "  let assert Ok(enum_codec_0) = blueprint.string_enum([#(\"\", Field0Value0), #(\"back\\\\slash\", Field0Value1), #(\"case\", Field0Value2), #(\"line\\nbreak\", Field0Value3), #(\"quote\\\"label\", Field0Value4), #(\"\\u{E9}\\u{6F22}\\u{5B57}\\u{1F600}\", Field0Value5)])\n"
  <> "  let assert Ok(enum_codec_1) = blueprint.string_enum([#(\"\", Field1Value0), #(\"back\\\\slash\", Field1Value1), #(\"case\", Field1Value2), #(\"line\\nbreak\", Field1Value3), #(\"quote\\\"label\", Field1Value4), #(\"\\u{E9}\\u{6F22}\\u{5B57}\\u{1F600}\", Field1Value5)])\n"
  <> "  let assert Ok(enum_codec_2) = blueprint.string_enum([#(\"\", Field2Value0), #(\"back\\\\slash\", Field2Value1), #(\"case\", Field2Value2), #(\"line\\nbreak\", Field2Value3), #(\"quote\\\"label\", Field2Value4), #(\"\\u{E9}\\u{6F22}\\u{5B57}\\u{1F600}\", Field2Value5)])\n"
  <> "  let property_0 = blueprint.required(\"alpha\", enum_codec_0)\n"
  <> "  let property_1 = blueprint.required(\"beta\", blueprint.nullable(enum_codec_1))\n"
  <> "  let property_2 = blueprint.optional(\"gamma\", enum_codec_2)\n"
  <> "  let assert Ok(properties_1) = blueprint.combine(property_0, property_1)\n"
  <> "  let assert Ok(properties_2) = blueprint.combine(properties_1, property_2)\n"
  <> "  blueprint.imap(\n"
  <> "    blueprint.object(properties_2),\n"
  <> "    fn(raw) { Document(field_0: raw.0.0, field_1: raw.0.1, field_2: raw.1) },\n"
  <> "    fn(document) { #(#(document.field_0, document.field_1), document.field_2) },\n"
  <> "  )\n}\n"
}

fn single_empty_enum_source() -> String {
  "import lab/blueprint\n\n"
  <> "pub type Field0Enum {\n  Field0Value0\n}\n\n"
  <> "pub type Document {\n  Document(\n    field_0: Field0Enum\n  )\n}\n\n"
  <> "pub fn codec() -> blueprint.Codec(Document) {\n"
  <> "  let assert Ok(enum_codec_0) = blueprint.string_enum([#(\"\", Field0Value0)])\n"
  <> "  let property_0 = blueprint.required(\"only\", enum_codec_0)\n"
  <> "  blueprint.imap(\n"
  <> "    blueprint.object(property_0),\n"
  <> "    fn(raw) { Document(field_0: raw) },\n"
  <> "    fn(document) { document.field_0 },\n"
  <> "  )\n}\n"
}
