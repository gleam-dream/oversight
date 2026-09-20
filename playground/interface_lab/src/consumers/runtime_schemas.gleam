// THROWAWAY: Can an opaque runtime schema validate Values without creating native types?
import lab/blueprint
import lab/blueprint_runtime as runtime
import lab/value

pub fn probe() -> Nil {
  let canonical = must_contract(full_schema(False))
  let reordered = must_contract(full_schema(True))
  let accepted = full_value()
  let assert Ok(witness) = runtime.validate(canonical, accepted)
  let assert True = runtime.encoded(witness) == accepted
  let assert True = runtime.matches(reordered, witness)
  let assert True = runtime.same_schema(canonical, reordered)
  let assert True = runtime.schema(canonical) == full_schema_normalized()

  let field_contract =
    must_contract(blueprint.FieldSchema("name", blueprint.TextSchema))
  let singleton_object =
    must_contract(
      blueprint.ObjectSchema([
        blueprint.PropertySchema("name", True, blueprint.TextSchema),
      ]),
    )
  let assert Ok(name_witness) =
    runtime.validate(
      field_contract,
      value.Object([#("name", value.Text("Ada"))]),
    )
  let assert True = runtime.matches(singleton_object, name_witness)
  let assert True = runtime.same_schema(field_contract, singleton_object)

  let optional_changed =
    must_contract(full_schema_with(
      False,
      True,
      #(1, 10),
      "small",
      blueprint.PairSchema(blueprint.TextSchema, blueprint.IntSchema),
    ))
  let bound_changed =
    must_contract(full_schema_with(
      False,
      False,
      #(1, 9),
      "small",
      blueprint.PairSchema(blueprint.TextSchema, blueprint.IntSchema),
    ))
  let tag_changed =
    must_contract(full_schema_with(
      False,
      False,
      #(1, 10),
      "tiny",
      blueprint.PairSchema(blueprint.TextSchema, blueprint.IntSchema),
    ))
  let tuple_reversed =
    must_contract(blueprint.PairSchema(
      blueprint.IntSchema,
      blueprint.TextSchema,
    ))
  let tuple_ordered =
    must_contract(blueprint.PairSchema(
      blueprint.TextSchema,
      blueprint.IntSchema,
    ))
  let assert False = runtime.matches(optional_changed, witness)
  let assert False = runtime.matches(bound_changed, witness)
  let assert False = runtime.matches(tag_changed, witness)
  let assert False = runtime.same_schema(tuple_ordered, tuple_reversed)

  // Canonicalization is bytewise UTF-8 ordering, not locale collation, and
  // each tagged payload moves with its tag.
  let unicode_left =
    must_contract(blueprint.TaggedSchema(
      "猫",
      blueprint.TextSchema,
      "é",
      blueprint.IntSchema,
    ))
  let unicode_right =
    must_contract(blueprint.TaggedSchema(
      "é",
      blueprint.IntSchema,
      "猫",
      blueprint.TextSchema,
    ))
  let assert True = runtime.same_schema(unicode_left, unicode_right)
  let assert blueprint.TaggedSchema(
    "é",
    blueprint.IntSchema,
    "猫",
    blueprint.TextSchema,
  ) = runtime.schema(unicode_left)

  let assert Error(runtime.DuplicateSchemaProperty("x")) =
    runtime.from_schema(
      blueprint.ObjectSchema([
        blueprint.PropertySchema("x", True, blueprint.TextSchema),
        blueprint.PropertySchema("x", False, blueprint.BoolSchema),
      ]),
    )
  let assert Error(runtime.DuplicateSchemaTag("same")) =
    runtime.from_schema(blueprint.TaggedSchema(
      "same",
      blueprint.TextSchema,
      "same",
      blueprint.IntSchema,
    ))
  let assert Error(runtime.ReversedIntegerRange(4, 2)) =
    runtime.from_schema(blueprint.IntegerRangeSchema(4, 2))

  let optional_nullable =
    must_contract(
      blueprint.ObjectSchema([
        blueprint.PropertySchema(
          "maybe",
          False,
          blueprint.NullableSchema(blueprint.IntSchema),
        ),
      ]),
    )
  let assert Ok(_) = runtime.validate(optional_nullable, value.Object([]))
  let assert Ok(_) =
    runtime.validate(optional_nullable, value.Object([#("maybe", value.Null)]))
  let assert Ok(_) =
    runtime.validate(
      optional_nullable,
      value.Object([#("maybe", value.Int(7))]),
    )
  let required_nullable =
    must_contract(
      blueprint.ObjectSchema([
        blueprint.PropertySchema(
          "maybe",
          True,
          blueprint.NullableSchema(blueprint.IntSchema),
        ),
      ]),
    )
  let assert Error(runtime.ValidationError(
    [runtime.Property("maybe")],
    runtime.MissingProperty("maybe"),
  )) = runtime.validate(required_nullable, value.Object([]))

  let profile_contract =
    must_contract(
      blueprint.ObjectSchema([
        blueprint.PropertySchema(
          "profile",
          True,
          blueprint.ObjectSchema([
            blueprint.PropertySchema("name", True, blueprint.TextSchema),
          ]),
        ),
      ]),
    )
  let assert Error(runtime.ValidationError(
    [runtime.Property("profile"), runtime.Property("name")],
    runtime.ExpectedText,
  )) =
    runtime.validate(
      profile_contract,
      value.Object([
        #("profile", value.Object([#("name", value.Bool(True))])),
      ]),
    )
  let assert Error(runtime.ValidationError(
    [runtime.Property("profile"), runtime.Property("name")],
    runtime.MissingProperty("name"),
  )) =
    runtime.validate(
      profile_contract,
      value.Object([
        #("profile", value.Object([])),
      ]),
    )
  let assert Error(runtime.ValidationError(
    [runtime.Property("profile"), runtime.Property("extra")],
    runtime.UnknownProperty("extra"),
  )) =
    runtime.validate(
      profile_contract,
      value.Object([
        #(
          "profile",
          value.Object([
            #("name", value.Text("Ada")),
            #("extra", value.Null),
          ]),
        ),
      ]),
    )
  let assert Error(runtime.ValidationError(
    [runtime.Property("profile")],
    runtime.DuplicateProperty("profile"),
  )) =
    runtime.validate(
      profile_contract,
      value.Object([
        #("profile", value.Object([#("name", value.Text("Ada"))])),
        #("profile", value.Object([#("name", value.Text("Grace"))])),
      ]),
    )

  let tuple_contract =
    must_contract(blueprint.PairSchema(
      blueprint.TextSchema,
      blueprint.IntSchema,
    ))
  let assert Error(runtime.ValidationError([], runtime.WrongTupleLength(2, 1))) =
    runtime.validate(tuple_contract, value.Array([value.Text("short")]))
  let range_contract = must_contract(blueprint.IntegerRangeSchema(1, 10))
  let assert Error(runtime.ValidationError(
    [],
    runtime.IntegerOutsideRange(1, 10, 11),
  )) = runtime.validate(range_contract, value.Int(11))

  let tagged_contract =
    must_contract(blueprint.TaggedSchema(
      "small",
      blueprint.IntSchema,
      "text",
      blueprint.TextSchema,
    ))
  let assert Error(runtime.ValidationError(
    [runtime.Property("tag")],
    runtime.MissingTag,
  )) =
    runtime.validate(tagged_contract, value.Object([#("value", value.Int(1))]))
  let assert Error(runtime.ValidationError(
    [runtime.Property("tag")],
    runtime.NonTextTag,
  )) =
    runtime.validate(
      tagged_contract,
      value.Object([
        #("tag", value.Int(1)),
        #("value", value.Int(1)),
      ]),
    )
  let assert Error(runtime.ValidationError(
    [runtime.Property("tag")],
    runtime.UnknownTag("other"),
  )) =
    runtime.validate(
      tagged_contract,
      value.Object([
        #("tag", value.Text("other")),
        #("value", value.Int(1)),
      ]),
    )
  let assert Error(runtime.ValidationError(
    [runtime.Property("tag")],
    runtime.DuplicateProperty("tag"),
  )) =
    runtime.validate(
      tagged_contract,
      value.Object([
        #("tag", value.Text("other")),
        #("tag", value.Text("small")),
        #("unexpected", value.Null),
      ]),
    )
  let assert Error(runtime.ValidationError(
    [runtime.Property("value"), runtime.TaggedBranch("small")],
    runtime.ExpectedInteger,
  )) =
    runtime.validate(
      tagged_contract,
      value.Object([
        #("tag", value.Text("small")),
        #("value", value.Text("not-an-integer")),
      ]),
    )

  let assert Ok(static_contract) =
    runtime.from_codec(blueprint.field("name", blueprint.text()))
  let assert True = runtime.same_schema(static_contract, field_contract)
  let custom_codec =
    blueprint.new(fn(item: Int) { Ok(value.Int(item)) }, fn(_) { Ok(1) })
  let assert Error(runtime.UnknownSchema) = runtime.from_codec(custom_codec)
  let assert Error(runtime.UnknownSchema) =
    runtime.from_codec(blueprint.list(custom_codec))
  Nil
}

fn full_schema(reverse: Bool) -> blueprint.Schema {
  full_schema_with(
    reverse,
    False,
    #(1, 10),
    "small",
    blueprint.PairSchema(blueprint.TextSchema, blueprint.IntSchema),
  )
}

fn full_schema_with(
  reverse: Bool,
  enabled_required: Bool,
  count_bounds: #(Int, Int),
  small_tag: String,
  tuple: blueprint.Schema,
) -> blueprint.Schema {
  let tagged =
    blueprint.TaggedSchema(
      small_tag,
      blueprint.IntegerRangeSchema(1, 3),
      "text",
      blueprint.TextSchema,
    )
  let normal = [
    blueprint.PropertySchema("name", True, blueprint.TextSchema),
    blueprint.PropertySchema(
      "count",
      True,
      blueprint.IntegerRangeSchema(count_bounds.0, count_bounds.1),
    ),
    blueprint.PropertySchema("enabled", enabled_required, blueprint.BoolSchema),
    blueprint.PropertySchema("selection", True, tagged),
    blueprint.PropertySchema("tuple", True, tuple),
  ]
  case reverse {
    False -> blueprint.ObjectSchema(normal)
    True ->
      blueprint.ObjectSchema([
        blueprint.PropertySchema("tuple", True, tuple),
        blueprint.PropertySchema(
          "selection",
          True,
          blueprint.TaggedSchema(
            "text",
            blueprint.TextSchema,
            small_tag,
            blueprint.IntegerRangeSchema(1, 3),
          ),
        ),
        blueprint.PropertySchema(
          "enabled",
          enabled_required,
          blueprint.BoolSchema,
        ),
        blueprint.PropertySchema(
          "count",
          True,
          blueprint.IntegerRangeSchema(count_bounds.0, count_bounds.1),
        ),
        blueprint.PropertySchema("name", True, blueprint.TextSchema),
      ])
  }
}

fn full_schema_normalized() -> blueprint.Schema {
  blueprint.ObjectSchema([
    blueprint.PropertySchema("count", True, blueprint.IntegerRangeSchema(1, 10)),
    blueprint.PropertySchema("enabled", False, blueprint.BoolSchema),
    blueprint.PropertySchema("name", True, blueprint.TextSchema),
    blueprint.PropertySchema(
      "selection",
      True,
      blueprint.TaggedSchema(
        "small",
        blueprint.IntegerRangeSchema(1, 3),
        "text",
        blueprint.TextSchema,
      ),
    ),
    blueprint.PropertySchema(
      "tuple",
      True,
      blueprint.PairSchema(blueprint.TextSchema, blueprint.IntSchema),
    ),
  ])
}

fn full_value() -> value.Value {
  value.Object([
    #("tuple", value.Array([value.Text("first"), value.Int(2)])),
    #(
      "selection",
      value.Object([
        #("tag", value.Text("text")),
        #("value", value.Text("chosen")),
      ]),
    ),
    #("enabled", value.Bool(True)),
    #("count", value.Int(4)),
    #("name", value.Text("Ada")),
  ])
}

fn must_contract(schema: blueprint.Schema) -> runtime.RuntimeContract {
  let assert Ok(contract) = runtime.from_schema(schema)
  contract
}
