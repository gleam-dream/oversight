// THROWAWAY: One registration supplies declaration and typed invocation.
import lab/blueprint
import lab/fabric
import lab/fabric_llm
import lab/llm_turn
import lab/relay
import lab/value

pub fn probe() -> Nil {
  let input = blueprint.field("id", blueprint.int())
  let r =
    relay.context_tool(
      "lookup",
      input,
      blueprint.int(),
      blueprint.text(),
      fn(offset: Int, id) { Ok(id + offset) },
    )
  let f =
    fabric.context_tool(
      "lookup",
      input,
      blueprint.int(),
      blueprint.text(),
      fn(offset: Int, id) { Ok(id + offset) },
    )
  let assert Ok(rr) = relay.registry([r])
  let assert Ok(fr) = fabric.registry([f])
  let assert [relay.Declaration("lookup", rs)] = relay.declarations(rr)
  let assert [fabric.Declaration("lookup", fs)] = fabric.declarations(fr)
  let assert True = rs == fs
  let assert [
    llm_turn.ToolDeclaration(llm_turn.ToolName("lookup"), _, raw_schema),
  ] = fabric_llm.declarations(fr)
  let assert True = raw_schema == blueprint.schema_value(fs)
  let raw = value.Object([#("id", value.Int(7))])
  let assert Ok(value.Int(17)) = relay.dispatch(rr, 10, "lookup", raw)
  let assert Ok(value.Int(27)) = fabric.dispatch(fr, 20, "lookup", raw)
  let assert Error(relay.UnknownTool("absent")) =
    relay.dispatch(rr, 10, "absent", raw)
  let assert Error(relay.DuplicateName("lookup")) = relay.registry([r, r])
  let assert Error(fabric.DuplicateName("lookup")) = fabric.registry([f, f])
  let assert Error(_) =
    blueprint.decode(
      input,
      value.Object([#("id", value.Int(7)), #("extra", value.Null)]),
    )
  let assert Error(_) =
    blueprint.decode(
      input,
      value.Object([#("id", value.Int(7)), #("id", value.Int(8))]),
    )
  let assert Error(blueprint.DecodeAtField("id", _)) =
    blueprint.decode(input, value.Object([#("id", value.Bool(True))]))
  let primitive =
    relay.tool("bad", blueprint.int(), blueprint.int(), blueprint.text(), fn(i) {
      Ok(i)
    })
  let assert Error(relay.InputMustBeObject) = relay.declaration(primitive)
  let custom = blueprint.new(fn(i: Int) { Ok(value.Int(i)) }, fn(_) { Ok(0) })
  let assert Error(blueprint.UnknownSchema) = blueprint.schema(custom)
  let unknown =
    fabric.context_tool(
      "custom",
      custom,
      blueprint.int(),
      blueprint.text(),
      fn(_: Nil, i) { Ok(i) },
    )
  let assert Error(fabric.InvalidDeclaration("custom", blueprint.UnknownSchema)) =
    fabric.registry([unknown])
  let assert Ok(blueprint.PairSchema(blueprint.TextSchema, blueprint.IntSchema)) =
    blueprint.schema(blueprint.pair(blueprint.text(), blueprint.int()))
  Nil
}
