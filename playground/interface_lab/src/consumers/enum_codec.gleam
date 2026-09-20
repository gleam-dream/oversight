// THROWAWAY: Can one closed string table tie native values to codec and schema?
import lab/blueprint
import lab/blueprint_codegen as codegen
import lab/blueprint_document
import lab/blueprint_requirements as requirements
import lab/blueprint_runtime as runtime
import lab/relay
import lab/value

pub type Priority {
  Low
  Normal
  Urgent
}

pub type PriorityRequest {
  PriorityRequest(
    priority: Priority,
    note: blueprint.Optional(blueprint.Nullable(String)),
  )
}

pub type DecorativeLabel {
  EmptyLabel
  QuotedUnicodeLabel
}

type ExpandedPriority {
  ListedPriority
  OmittedPriority
}

pub fn priority_codec() -> Result(
  blueprint.Codec(Priority),
  blueprint.EnumError,
) {
  blueprint.string_enum([
    #("low", Low),
    #("normal", Normal),
    #("urgent", Urgent),
  ])
}

pub fn priority_request_codec() -> Result(
  blueprint.Codec(PriorityRequest),
  blueprint.EnumError,
) {
  case priority_codec() {
    Error(error) -> Error(error)
    Ok(priority) -> {
      let assert Ok(properties) =
        blueprint.combine(
          blueprint.required("priority", priority),
          blueprint.optional("note", blueprint.nullable(blueprint.text())),
        )
      Ok(
        blueprint.imap(
          blueprint.object(properties),
          fn(raw) { PriorityRequest(raw.0, raw.1) },
          fn(request) { #(request.priority, request.note) },
        ),
      )
    }
  }
}

pub fn decorative_label_codec() -> Result(
  blueprint.Codec(DecorativeLabel),
  blueprint.EnumError,
) {
  blueprint.string_enum([
    #("", EmptyLabel),
    #("quoted \"雪猫", QuotedUnicodeLabel),
  ])
}

pub fn probe() -> Nil {
  let assert Ok(priority) = priority_codec()
  let assert Ok(value.Text("low")) = blueprint.encode(priority, Low)
  let assert Ok(value.Text("normal")) = blueprint.encode(priority, Normal)
  let assert Ok(value.Text("urgent")) = blueprint.encode(priority, Urgent)
  let assert Ok(Low) = blueprint.decode(priority, value.Text("low"))
  let assert Ok(Normal) = blueprint.decode(priority, value.Text("normal"))
  let assert Ok(Urgent) = blueprint.decode(priority, value.Text("urgent"))
  let assert Error(blueprint.CannotDecode("Unknown string enum label")) =
    blueprint.decode(priority, value.Text("critical"))
  let assert Error(blueprint.CannotDecode("Expected a string enum label")) =
    blueprint.decode(priority, value.Int(1))
  let assert Error(blueprint.CannotDecode("Expected a string enum label")) =
    blueprint.decode(priority, value.Null)

  let empty_enum: Result(blueprint.Codec(Priority), blueprint.EnumError) =
    blueprint.string_enum([])
  let assert Error(blueprint.EmptyEnum) = empty_enum
  let assert Error(blueprint.DuplicateEnumLabel("same")) =
    blueprint.string_enum([#("same", Low), #("same", Normal)])
  let assert Error(blueprint.DuplicateEnumValue(0, 2)) =
    blueprint.string_enum([
      #("low", Low),
      #("normal", Normal),
      #("also-low", Low),
    ])
  let assert Ok(partial_priority) =
    blueprint.string_enum([#("listed", ListedPriority)])
  let assert Error(blueprint.CannotEncode("Value is not in the string enum")) =
    blueprint.encode(partial_priority, OmittedPriority)

  let assert Ok(decorative) = decorative_label_codec()
  let assert Ok(value.Text("")) = blueprint.encode(decorative, EmptyLabel)
  let assert Ok(EmptyLabel) = blueprint.decode(decorative, value.Text(""))
  let assert Ok(value.Text("quoted \"雪猫")) =
    blueprint.encode(decorative, QuotedUnicodeLabel)
  let assert Ok(QuotedUnicodeLabel) =
    blueprint.decode(decorative, value.Text("quoted \"雪猫"))

  let assert Ok(request_codec) = priority_request_codec()
  let assert Ok(PriorityRequest(Urgent, blueprint.Missing)) =
    blueprint.decode(
      request_codec,
      value.Object([#("priority", value.Text("urgent"))]),
    )
  let assert Ok(PriorityRequest(Normal, blueprint.Present(blueprint.Null))) =
    blueprint.decode(
      request_codec,
      value.Object([
        #("priority", value.Text("normal")),
        #("note", value.Null),
      ]),
    )
  let request =
    PriorityRequest(Urgent, blueprint.Present(blueprint.NonNull("follow up")))
  let assert Ok(value.Object([
    #("priority", value.Text("urgent")),
    #("note", value.Text("follow up")),
  ])) = blueprint.encode(request_codec, request)
  let assert Ok(decoded_request) =
    blueprint.decode(
      request_codec,
      value.Object([
        #("priority", value.Text("urgent")),
        #("note", value.Text("follow up")),
      ]),
    )
  let assert True = decoded_request == request

  let priorities = blueprint.list(priority)
  let assert Ok([Low, Urgent]) =
    blueprint.decode(
      priorities,
      value.Array([value.Text("low"), value.Text("urgent")]),
    )
  let assert Error(blueprint.DecodeAtIndex(1, _)) =
    blueprint.decode(
      priorities,
      value.Array([value.Text("low"), value.Text("critical")]),
    )

  let assert Ok(priority_schema) = blueprint.schema(priority)
  let assert blueprint.StringEnumSchema(["low", "normal", "urgent"]) =
    priority_schema
  let assert value.Object([
    #("type", value.Text("string")),
    #(
      "enum",
      value.Array([
        value.Text("low"),
        value.Text("normal"),
        value.Text("urgent"),
      ]),
    ),
  ]) = blueprint.schema_value(priority_schema)

  let assert Ok(contract) = runtime.from_codec(priority)
  let assert blueprint.StringEnumSchema(["low", "normal", "urgent"]) =
    runtime.schema(contract)
  let assert Ok(reordered_contract) =
    runtime.from_schema(blueprint.StringEnumSchema(["urgent", "low", "normal"]))
  let assert True = runtime.same_schema(contract, reordered_contract)
  let canonical_document = blueprint.schema_document(runtime.schema(contract))
  let assert Ok(loaded_contract) = blueprint_document.load(canonical_document)
  let assert True = runtime.same_schema(contract, loaded_contract)
  let assert Error(runtime.EmptyStringEnum) =
    runtime.from_schema(blueprint.StringEnumSchema([]))
  let assert Error(runtime.DuplicateSchemaEnumLabel("low")) =
    runtime.from_schema(blueprint.StringEnumSchema(["low", "normal", "low"]))
  let assert Error(blueprint_document.SchemaInvariant(
    [blueprint_document.Property("enum")],
    runtime.EmptyStringEnum,
  )) =
    blueprint_document.load(
      blueprint.schema_document(blueprint.StringEnumSchema([])),
    )
  let assert Error(blueprint_document.SchemaInvariant(
    [blueprint_document.Property("enum"), blueprint_document.Index(2)],
    runtime.DuplicateSchemaEnumLabel("low"),
  )) =
    blueprint_document.load(
      blueprint.schema_document(
        blueprint.StringEnumSchema(["low", "normal", "low"]),
      ),
    )
  let assert Error(blueprint_document.MalformedDocument(
    [blueprint_document.Property("enum"), blueprint_document.Index(1)],
    blueprint_document.ExpectedText,
  )) =
    blueprint_document.load(
      enum_document([
        value.Text("low"),
        value.Int(1),
      ]),
    )
  let assert Error(blueprint_document.MalformedDocument(
    [blueprint_document.Property("enum")],
    blueprint_document.ExpectedArray,
  )) = blueprint_document.load(enum_document_value(value.Text("low")))
  let assert Error(blueprint_document.UnsupportedDocument(
    [blueprint_document.Property("description")],
    blueprint_document.UnsupportedKeyword("description"),
  )) =
    blueprint_document.load(
      value.Object([
        #("$schema", value.Text("https://json-schema.org/draft/2020-12/schema")),
        #("type", value.Text("string")),
        #("enum", value.Array([value.Text("low")])),
        #("description", value.Text("opaque metadata remains unsupported")),
      ]),
    )

  let assert Error(runtime.ValidationError(
    [runtime.Property("priority")],
    runtime.UnknownEnumLabel("critical"),
  )) =
    runtime.validate(
      must_contract(request_codec),
      value.Object([#("priority", value.Text("critical"))]),
    )
  let assert Error(runtime.ValidationError(
    [runtime.Index(1)],
    runtime.UnknownEnumLabel("critical"),
  )) =
    runtime.validate(
      must_contract(priorities),
      value.Array([value.Text("low"), value.Text("critical")]),
    )

  let assert [
    requirements.Requirement(
      [],
      requirements.StringEnumValues(["low", "normal", "urgent"]),
    ),
  ] = requirements.requirements(priority_schema)
  let assert [
    requirements.Requirement([], requirements.ArrayValues),
    requirements.Requirement(
      [requirements.Element],
      requirements.StringEnumValues(["low", "normal", "urgent"]),
    ),
  ] = requirements.requirements(blueprint.ListSchema(priority_schema))
  let assert [
    requirements.Requirement([], requirements.ClosedObject),
    requirements.Requirement(
      [requirements.Property("priority")],
      requirements.StringEnumValues(["low", "normal", "urgent"]),
    ),
    requirements.Requirement(
      [requirements.Property("note")],
      requirements.OptionalProperty,
    ),
    requirements.Requirement(
      [requirements.Property("note")],
      requirements.NullableValues,
    ),
    requirements.Requirement(
      [requirements.Property("note"), requirements.NonNullCase],
      requirements.TextValues,
    ),
  ] = requirements.requirements(must_schema(request_codec))

  let assert Ok(request_contract) = runtime.from_codec(request_codec)
  let assert Error(codegen.UnsupportedGeneration(
    [codegen.Property("priority")],
    codegen.StringEnumSchema,
  )) = codegen.generate(request_contract)

  let service =
    relay.context_tool(
      "set_priority",
      request_codec,
      blueprint.text(),
      blueprint.text(),
      fn(prefix: String, input: PriorityRequest) {
        Ok(prefix <> ":" <> priority_name(input.priority))
      },
    )
  let assert Ok(declaration) = relay.context_declaration(service)
  let assert relay.Declaration("set_priority", input_schema) = declaration
  let assert True = input_schema == must_schema(request_codec)
  let assert Ok(registry) = relay.registry([service])
  let assert [registry_declaration] = relay.declarations(registry)
  let assert True = registry_declaration == declaration
  let assert Ok(value.Text("ops:urgent")) =
    relay.dispatch(
      registry,
      "ops",
      "set_priority",
      value.Object([#("priority", value.Text("urgent"))]),
    )
  Nil
}

fn enum_document(labels: List(value.Value)) -> value.Value {
  value.Object([
    #("$schema", value.Text("https://json-schema.org/draft/2020-12/schema")),
    #("type", value.Text("string")),
    #("enum", value.Array(labels)),
  ])
}

fn enum_document_value(enum_value: value.Value) -> value.Value {
  value.Object([
    #("$schema", value.Text("https://json-schema.org/draft/2020-12/schema")),
    #("type", value.Text("string")),
    #("enum", enum_value),
  ])
}

fn must_contract(codec: blueprint.Codec(a)) -> runtime.RuntimeContract {
  case runtime.from_codec(codec) {
    Ok(contract) -> contract
    Error(_) -> panic as "enum consumer codec must retain a valid schema"
  }
}

fn must_schema(codec: blueprint.Codec(a)) -> blueprint.Schema {
  case blueprint.schema(codec) {
    Ok(schema) -> schema
    Error(_) -> panic as "enum consumer codec must retain its schema"
  }
}

fn priority_name(priority: Priority) -> String {
  case priority {
    Low -> "low"
    Normal -> "normal"
    Urgent -> "urgent"
  }
}
