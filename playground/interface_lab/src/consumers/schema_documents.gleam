// THROWAWAY: Can renderer-shaped schema Values load as exact runtime contracts?
import lab/blueprint
import lab/blueprint_document as document
import lab/blueprint_runtime as runtime
import lab/value

const draft = "https://json-schema.org/draft/2020-12/schema"

pub fn probe() -> Nil {
  let schema = representative_schema()
  let assert Ok(static_contract) = runtime.from_schema(schema)
  let rendered = blueprint.schema_document(schema)
  let assert Ok(loaded) = document.load(rendered)
  let assert True = runtime.same_schema(static_contract, loaded)

  // Object member order and required-name order do not alter the loaded schema.
  let reordered = reverse_document(rendered)
  let assert Ok(reordered_contract) = document.load(reordered)
  let assert True = runtime.same_schema(loaded, reordered_contract)
  let assert True = runtime.schema(loaded) == runtime.schema(reordered_contract)

  let assert Error(document.MalformedDocument(
    [document.Property("type")],
    document.DuplicateKey("type"),
  )) =
    document.load(
      value.Object([
        #("$schema", value.Text(draft)),
        #("type", value.Text("string")),
        #("type", value.Text("integer")),
      ]),
    )
  let assert Error(document.UnsupportedDialect(
    [document.Property("$schema")],
    "https://example.test/dialect",
  )) =
    document.load(
      value.Object([
        #("$schema", value.Text("https://example.test/dialect")),
        #("type", value.Text("string")),
      ]),
    )

  let assert Error(document.UnsupportedDocument(
    [document.Property("$ref")],
    document.UnsupportedKeyword("$ref"),
  )) =
    document.load(
      value.Object([
        #("$schema", value.Text(draft)),
        #("$ref", value.Text("#/definitions/x")),
      ]),
    )
  let assert Error(document.UnsupportedDocument(
    [document.Property("default")],
    document.UnsupportedKeyword("default"),
  )) =
    document.load(
      value.Object([
        #("$schema", value.Text(draft)),
        #("type", value.Text("string")),
        #("default", value.Text("fallback")),
      ]),
    )
  let assert Error(document.UnsupportedDocument(
    [
      document.Property("properties"),
      document.Property("inner"),
      document.Property("$schema"),
    ],
    document.NestedDialect,
  )) =
    document.load(
      value.Object([
        #("$schema", value.Text(draft)),
        #("type", value.Text("object")),
        #(
          "properties",
          value.Object([
            #(
              "inner",
              value.Object([
                #("$schema", value.Text(draft)),
                #("type", value.Text("string")),
              ]),
            ),
          ]),
        ),
        #("required", value.Array([])),
        #("additionalProperties", value.Bool(False)),
      ]),
    )

  let open_object =
    replace_root_field(
      blueprint.schema_document(blueprint.ObjectSchema([])),
      "additionalProperties",
      value.Bool(True),
    )
  let assert Error(document.UnsupportedDocument(
    [document.Property("additionalProperties")],
    document.OpenObject,
  )) = document.load(open_object)
  let assert Error(document.MalformedDocument(
    [document.Property("required"), document.Index(0)],
    document.UndeclaredRequiredName("ghost"),
  )) =
    document.load(
      value.Object([
        #("$schema", value.Text(draft)),
        #("type", value.Text("object")),
        #(
          "properties",
          value.Object([
            #(
              "known",
              value.Object([
                #("type", value.Text("string")),
              ]),
            ),
          ]),
        ),
        #("required", value.Array([value.Text("ghost")])),
        #("additionalProperties", value.Bool(False)),
      ]),
    )

  let assert Error(document.MalformedDocument(
    [document.Property("properties"), document.Property("x")],
    document.DuplicateKey("x"),
  )) =
    document.load(
      value.Object([
        #("$schema", value.Text(draft)),
        #("type", value.Text("object")),
        #(
          "properties",
          value.Object([
            #("x", value.Object([#("type", value.Text("string"))])),
            #("x", value.Object([#("type", value.Text("integer"))])),
          ]),
        ),
        #("required", value.Array([])),
        #("additionalProperties", value.Bool(False)),
      ]),
    )
  let assert Error(document.MalformedDocument(
    [
      document.Property("properties"),
      document.Property("child"),
      document.Property("type"),
    ],
    document.DuplicateKey("type"),
  )) =
    document.load(
      value.Object([
        #("$schema", value.Text(draft)),
        #("type", value.Text("object")),
        #(
          "properties",
          value.Object([
            #(
              "child",
              value.Object([
                #("type", value.Text("string")),
                #("type", value.Text("integer")),
              ]),
            ),
          ]),
        ),
        #("required", value.Array([])),
        #("additionalProperties", value.Bool(False)),
      ]),
    )

  let reversed_range =
    blueprint.schema_document(blueprint.IntegerRangeSchema(9, 1))
  let assert Error(document.SchemaInvariant(
    [document.Property("minimum")],
    runtime.ReversedIntegerRange(9, 1),
  )) = document.load(reversed_range)
  let nested_duplicate_tag =
    blueprint.schema_document(blueprint.TaggedSchema(
      "same",
      blueprint.TaggedSchema(
        "same",
        blueprint.TextSchema,
        "same",
        blueprint.BoolSchema,
      ),
      "same",
      blueprint.IntSchema,
    ))
  let assert Error(document.SchemaInvariant(
    [
      document.Property("oneOf"),
      document.Index(1),
      document.Property("properties"),
      document.Property("tag"),
      document.Property("const"),
    ],
    runtime.DuplicateSchemaTag("same"),
  )) = document.load(nested_duplicate_tag)

  let malformed_nullable =
    replace_root_field(
      blueprint.schema_document(blueprint.NullableSchema(blueprint.TextSchema)),
      "anyOf",
      value.Text("not-an-array"),
    )
  let assert Error(document.MalformedDocument(
    [document.Property("anyOf")],
    document.ExpectedArray,
  )) = document.load(malformed_nullable)
  let malformed_tagged =
    replace_root_field(
      blueprint.schema_document(blueprint.TaggedSchema(
        "left",
        blueprint.TextSchema,
        "right",
        blueprint.BoolSchema,
      )),
      "oneOf",
      value.Text("not-an-array"),
    )
  let assert Error(document.MalformedDocument(
    [document.Property("oneOf")],
    document.ExpectedArray,
  )) = document.load(malformed_tagged)
  let malformed_tuple =
    replace_root_field(
      blueprint.schema_document(blueprint.PairSchema(
        blueprint.TextSchema,
        blueprint.IntSchema,
      )),
      "prefixItems",
      value.Text("not-an-array"),
    )
  let assert Error(document.MalformedDocument(
    [document.Property("prefixItems")],
    document.ExpectedArray,
  )) = document.load(malformed_tuple)

  // Empty property and tag names are retained because the static constructors
  // allow them; the loader adds no unrelated naming policy.
  let empty_names =
    blueprint.ObjectSchema([
      blueprint.PropertySchema(
        "",
        True,
        blueprint.TaggedSchema(
          "",
          blueprint.TextSchema,
          "other",
          blueprint.BoolSchema,
        ),
      ),
    ])
  let assert Ok(empty_loaded) =
    document.load(blueprint.schema_document(empty_names))
  let assert Ok(empty_static) = runtime.from_schema(empty_names)
  let assert True = runtime.same_schema(empty_loaded, empty_static)
  Nil
}

fn representative_schema() -> blueprint.Schema {
  blueprint.ObjectSchema([
    blueprint.PropertySchema(
      "account",
      True,
      blueprint.FieldSchema("id", blueprint.TextSchema),
    ),
    blueprint.PropertySchema("active", False, blueprint.BoolSchema),
    blueprint.PropertySchema("count", True, blueprint.IntegerRangeSchema(1, 10)),
    blueprint.PropertySchema(
      "events",
      True,
      blueprint.ListSchema(blueprint.NullableSchema(blueprint.TextSchema)),
    ),
    blueprint.PropertySchema(
      "mode",
      True,
      blueprint.TaggedSchema(
        "credit",
        blueprint.PairSchema(blueprint.IntSchema, blueprint.TextSchema),
        "manual",
        blueprint.ObjectSchema([
          blueprint.PropertySchema("memo", False, blueprint.TextSchema),
        ]),
      ),
    ),
    blueprint.PropertySchema(
      "point",
      True,
      blueprint.PairSchema(blueprint.TextSchema, blueprint.BoolSchema),
    ),
  ])
}

fn reverse_document(item: value.Value) -> value.Value {
  case item {
    value.Object(fields) -> value.Object(reverse_fields(fields))
    value.Array(items) -> value.Array(map_values(items))
    _ -> item
  }
}

fn reverse_fields(
  fields: List(#(String, value.Value)),
) -> List(#(String, value.Value)) {
  reverse_pairs(transform_fields(fields))
}

fn transform_fields(
  fields: List(#(String, value.Value)),
) -> List(#(String, value.Value)) {
  case fields {
    [] -> []
    [#(name, item), ..rest] -> {
      let transformed = case name, item {
        "required", value.Array(items) -> value.Array(reverse_values(items))
        "oneOf", value.Array(items) -> value.Array(reverse_values(items))
        "anyOf", value.Array(items) -> value.Array(reverse_values(items))
        _, _ -> reverse_document(item)
      }
      [#(name, transformed), ..transform_fields(rest)]
    }
  }
}

fn reverse_values(items: List(value.Value)) -> List(value.Value) {
  case items {
    [] -> []
    [head, ..rest] -> reverse_append(rest, [reverse_document(head)])
  }
}

fn map_values(items: List(value.Value)) -> List(value.Value) {
  case items {
    [] -> []
    [head, ..rest] -> [reverse_document(head), ..map_values(rest)]
  }
}

fn reverse_append(
  items: List(value.Value),
  reversed: List(value.Value),
) -> List(value.Value) {
  case items {
    [] -> reversed
    [head, ..rest] -> reverse_append(rest, [reverse_document(head), ..reversed])
  }
}

fn reverse_pairs(
  items: List(#(String, value.Value)),
) -> List(#(String, value.Value)) {
  reverse_pairs_into(items, [])
}

fn reverse_pairs_into(
  items: List(#(String, value.Value)),
  reversed: List(#(String, value.Value)),
) -> List(#(String, value.Value)) {
  case items {
    [] -> reversed
    [head, ..rest] -> reverse_pairs_into(rest, [head, ..reversed])
  }
}

fn replace_root_field(
  document: value.Value,
  name: String,
  replacement: value.Value,
) -> value.Value {
  let assert value.Object(fields) = document
  value.Object(replace_field(fields, name, replacement))
}

fn replace_field(
  fields: List(#(String, value.Value)),
  name: String,
  replacement: value.Value,
) -> List(#(String, value.Value)) {
  case fields {
    [] -> [#(name, replacement)]
    [#(key, _), ..rest] if key == name -> [#(key, replacement), ..rest]
    [head, ..rest] -> [head, ..replace_field(rest, name, replacement)]
  }
}
