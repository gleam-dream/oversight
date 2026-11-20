//// A BEAM copy does not keep sharing, so a value costs its flat size every
//// time it crosses a process. Grind copies the report worker and its codecs
//// into the processes that run each job, and Relay copies tool definitions
//// into the processes that serve each request. These bounds hold what this
//// application hands over; a nested combinator codec that multiplies its
//// size, or a child codec captured by a later field, fails them. See the
//// codec practice guide:
//// https://github.com/lostbean/json_blueprint/blob/main/docs/CODEC-PRACTICE.md

import gleam/list
import secure_mcp/tools

@external(erlang, "copy_cost_ffi", "flat_size_bytes")
fn flat_size_bytes(term: a) -> Int

/// Each value handed over: its name, its copied size in bytes and its
/// budget in bytes.
pub fn handed_off() -> List(#(String, Int, Int)) {
  [
    #("report worker", flat_size_bytes(tools.report_worker()), 16_384),
    #(
      "generate definition",
      flat_size_bytes(tools.generate_definition()),
      16_384,
    ),
    #("status definition", flat_size_bytes(tools.status_definition()), 24_576),
  ]
}

pub fn values_handed_over_stay_within_their_copy_budget_test() {
  let over =
    list.filter(handed_off(), fn(entry) {
      let #(_, bytes, budget) = entry
      bytes > budget
    })
  assert over == []
}
