// THROWAWAY: Standalone and Fabric tools retain exact schemas through policy.
import lab/blueprint as b
import lab/blueprint_requirements as r
import lab/fabric
import lab/fabric_llm
import lab/llm_catalog as catalog
import lab/llm_turn as turn
import lab/value as v

pub type Issue {
  Unsupported(r.Requirement)
  RootMustBeObject
}

fn reject(
  requirements: List(r.Requirement),
  feature: r.Feature,
) -> List(Issue) {
  case requirements {
    [] -> []
    [requirement, ..rest] ->
      case requirement.feature == feature {
        True -> [Unsupported(requirement), ..reject(rest, feature)]
        False -> reject(rest, feature)
      }
  }
}

fn object_root(entry: catalog.Entry) -> List(Issue) {
  case entry.input_schema {
    b.FieldSchema(_, _) | b.ObjectSchema(_) | b.TaggedSchema(_, _, _, _) -> []
    _ -> [RootMustBeObject]
  }
}

pub fn probe() -> Nil {
  let assert Ok(quantity) = b.integer_between(1, 10)
  let assert Ok(properties) =
    b.combine(
      b.required("id", quantity),
      b.optional("labels", b.list(b.nullable(b.text()))),
    )
  let input = b.field("request", b.object(properties))
  let assert Ok(choice) = b.tagged("number", b.int(), "text", b.text())
  let lookup =
    fabric.context_tool(
      "lookup",
      input,
      b.int(),
      b.text(),
      fn(offset: Int, request) { Ok(offset + request.0) },
    )
  let choose =
    fabric.context_tool("choose", choice, b.int(), b.text(), fn(_: Int, item) {
      case item {
        b.Left(number) -> Ok(number)
        b.Right(_) -> Ok(0)
      }
    })
  let assert Ok(registry) = fabric.registry([lookup, choose])
  let assert Ok(tools) = fabric_llm.catalog(registry)
  let assert [lookup_entry, choice_entry] = catalog.entries(tools)
  let assert Ok(standalone) =
    catalog.entry_from_codec(turn.ToolName("lookup"), "", input)
  let assert True = standalone == lookup_entry
  let assert Error(catalog.DuplicateName(turn.ToolName("lookup"))) =
    catalog.catalog([standalone, standalone])
  let assert Error([
    catalog.Rejection(
      turn.ToolName("lookup"),
      Unsupported(r.Requirement(
        [r.Property("request"), r.Property("labels")],
        r.OptionalProperty,
      )),
    ),
  ]) =
    catalog.admit(tools, fn(entry) {
      reject(r.requirements(entry.input_schema), r.OptionalProperty)
    })
  let assert Error([
    catalog.Rejection(
      turn.ToolName("choose"),
      Unsupported(r.Requirement([], r.TaggedAlternatives)),
    ),
  ]) =
    catalog.admit(tools, fn(entry) {
      reject(r.requirements(entry.input_schema), r.TaggedAlternatives)
    })
  let assert Ok(admitted) = catalog.admit(tools, object_root)
  let assert True =
    catalog.render(admitted) == fabric_llm.declarations(registry)
  let assert True =
    choice_entry.input_schema
    == b.TaggedSchema("number", b.IntSchema, "text", b.TextSchema)
  // Admission does not alter the registered decoder or application behavior.
  let raw = v.Object([#("request", v.Object([#("id", v.Int(3))]))])
  let assert Ok(v.Int(10)) = fabric.dispatch(registry, 7, "lookup", raw)
  let assert Error(_) =
    fabric.dispatch(
      registry,
      7,
      "lookup",
      v.Object([#("request", v.Object([#("id", v.Int(11))]))]),
    )
  let custom = b.new(fn(item: Int) { Ok(v.Int(item)) }, fn(_) { Ok(1) })
  let assert Error(b.UnknownSchema) =
    catalog.entry_from_codec(turn.ToolName("custom"), "", custom)
  let assert Ok(scalar) =
    catalog.entry_from_codec(turn.ToolName("scalar"), "", b.int())
  let assert Ok(scalars) = catalog.catalog([scalar])
  let assert Error([
    catalog.Rejection(turn.ToolName("scalar"), RootMustBeObject),
  ]) = catalog.admit(scalars, object_root)
  let assert [
    r.Requirement([], r.ArrayValues),
    r.Requirement([], r.FixedTuple),
    r.Requirement([r.TupleIndex(0)], r.BooleanValues),
    r.Requirement([r.TupleIndex(1)], r.IntegerValues),
  ] = r.requirements(b.PairSchema(b.BoolSchema, b.IntSchema))
  let assert [
    r.Requirement([], r.NullableValues),
    r.Requirement([r.NonNullCase], r.IntegerValues),
    r.Requirement([r.NonNullCase], r.IntegerBounds(1, 10)),
  ] = r.requirements(b.NullableSchema(b.IntegerRangeSchema(1, 10)))
  let assert [
    r.Requirement([], r.ClosedObject),
    r.Requirement([], r.TaggedAlternatives),
    r.Requirement([r.TaggedCase("small"), r.Property("value")], r.IntegerValues),
    r.Requirement(
      [r.TaggedCase("small"), r.Property("value")],
      r.IntegerBounds(1, 2),
    ),
    r.Requirement([r.TaggedCase("many"), r.Property("value")], r.ArrayValues),
    r.Requirement(
      [r.TaggedCase("many"), r.Property("value"), r.Element],
      r.TextValues,
    ),
  ] =
    r.requirements(b.TaggedSchema(
      "small",
      b.IntegerRangeSchema(1, 2),
      "many",
      b.ListSchema(b.TextSchema),
    ))
  Nil
}
