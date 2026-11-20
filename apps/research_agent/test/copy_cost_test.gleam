//// A BEAM copy does not keep sharing, so a value costs its flat size every
//// time it crosses a process. Fabric copies the agent with its tool codecs
//// into each run, and Grind copies a worker's codecs into the processes that
//// run each job. These bounds hold what this application hands to Fabric and
//// Grind; a nested combinator codec that multiplies its size, or a child
//// codec captured by a later field, fails them. See the codec practice guide:
//// https://github.com/lostbean/json_blueprint/blob/main/docs/CODEC-PRACTICE.md

import gleam/list
import http_gun
import http_gun/config as http_config
import research_agent/domain
import research_agent/researcher
import research_agent/wire

@external(erlang, "copy_cost_ffi", "flat_size_bytes")
fn flat_size_bytes(term: a) -> Int

/// Each value handed to Fabric or Grind: its name, its copied size in bytes
/// and its budget in bytes.
pub fn handed_off() -> List(#(String, Int, Int)) {
  let assert Ok(http) = http_gun.start(http_config.default())
  let endpoints =
    researcher.Endpoints(
      search: "http://127.0.0.1:9/search",
      pages: "http://127.0.0.1:9/pages",
      llm: "http://127.0.0.1:9/v1",
    )
  let assert Ok(agent) = researcher.build(http, endpoints)
  http_gun.stop(http)
  [
    #("answer codec", flat_size_bytes(domain.answer_codec()), 8192),
    #(
      "search definition",
      flat_size_bytes(researcher.search_definition()),
      16_384,
    ),
    #("read definition", flat_size_bytes(researcher.read_definition()), 8192),
    #("fabric agent", flat_size_bytes(agent), 65_536),
    #(
      "job input codec",
      flat_size_bytes(wire.grind("research-1", domain.research_codec())),
      8192,
    ),
    #(
      "job output codec",
      flat_size_bytes(wire.grind("published-1", domain.published_codec())),
      8192,
    ),
  ]
}

pub fn values_handed_to_fabric_and_grind_stay_within_their_copy_budget_test() {
  let over =
    list.filter(handed_off(), fn(entry) {
      let #(_, bytes, budget) = entry
      bytes > budget
    })
  assert over == []
}
