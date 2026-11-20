//// A BEAM copy does not keep sharing, so a value costs its flat size every
//// time it crosses a process. Fabric copies the agent with its tool codecs
//// into each run, and Relay copies tool definitions into the processes that
//// serve each request. These bounds hold what this application hands to
//// Fabric and Relay; a nested combinator codec that multiplies its size, or a
//// child codec captured by a later field, fails them. See the codec practice
//// guide: https://github.com/lostbean/json_blueprint/blob/main/docs/CODEC-PRACTICE.md

import gleam/list
import llm_wire/testing
import tool_hub
import tool_hub/assistant
import tool_hub/inventory

@external(erlang, "copy_cost_ffi", "flat_size_bytes")
fn flat_size_bytes(term: a) -> Int

/// Each value handed to Fabric or Relay: its name, its copied size in bytes
/// and its budget in bytes.
pub fn handed_off() -> List(#(String, Int, Int)) {
  let peer = fn(context: assistant.Context) { context.inventory }
  let fabric_tools = tool_hub.typed_tools(peer)
  let assert Ok(http) = tool_hub.provider_client("tool_hub_copy_cost")
  let assert Ok(agent) =
    assistant.build_agent(
      http,
      testing.config(),
      "scripted-1",
      fabric_tools,
      read_only: ["search_products", "get_stock"],
      approvers: assistant.operator_approvers("copy-cost"),
    )
  let catalog = inventory.demo_catalog()
  let relay_tools = inventory.tools(catalog)
  [
    #(
      "search_products definition",
      flat_size_bytes(inventory.search_products()),
      24_576,
    ),
    #(
      "reserve_stock definition",
      flat_size_bytes(inventory.reserve_stock()),
      16_384,
    ),
    #(
      "ask_assistant definition",
      flat_size_bytes(assistant.ask_assistant()),
      16_384,
    ),
    #("relay inventory tools", flat_size_bytes(relay_tools), 65_536),
    #("fabric tools", flat_size_bytes(fabric_tools), 131_072),
    #("fabric agent", flat_size_bytes(agent), 131_072),
  ]
}

pub fn values_handed_to_fabric_and_relay_stay_within_their_copy_budget_test() {
  let over =
    list.filter(handed_off(), fn(entry) {
      let #(_, bytes, budget) = entry
      bytes > budget
    })
  assert over == []
}
