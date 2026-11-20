//// A BEAM copy does not keep sharing, so a term costs its flat size every
//// time it crosses a process. Fabric copies the agent, with its tool codecs,
//// into each run, and Relay holds the inventory tool list that serves each
//// request. These bounds hold those terms. See the codec practice guide:
//// https://github.com/lostbean/json_blueprint/blob/main/docs/CODEC-PRACTICE.md

import gleam/list
import http_gun
import llm_wire/testing
import tool_hub
import tool_hub/assistant
import tool_hub/inventory

@external(erlang, "copy_cost_ffi", "flat_size_bytes")
fn flat_size_bytes(term: a) -> Int

/// Each term handed to another process: its name, its copied size in bytes
/// and its budget in bytes.
pub fn crossing() -> List(#(String, Int, Int)) {
  let peer = fn(context: assistant.Context) { context.inventory }
  let assert Ok(http) = tool_hub.provider_client("tool_hub_copy_cost")
  let assert Ok(agent) =
    assistant.build_agent(
      http,
      testing.config(),
      "scripted-1",
      tool_hub.typed_tools(peer),
      read_only: ["search_products", "get_stock"],
      approvers: assistant.operator_approvers("copy-cost"),
    )
  let relay_tools = inventory.tools(inventory.demo_catalog())
  let measured = [
    #("fabric agent", flat_size_bytes(agent), 81_920),
    #("relay inventory tools", flat_size_bytes(relay_tools), 36_864),
  ]
  http_gun.stop(http)
  measured
}

pub fn terms_handed_to_other_processes_stay_within_their_copy_budget_test() {
  let over =
    list.filter(crossing(), fn(entry) {
      let #(_, bytes, budget) = entry
      bytes > budget
    })
  assert over == []
}
