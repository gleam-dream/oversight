//// A BEAM copy does not keep sharing, so a value costs its flat size every
//// time it crosses a process. Fabric copies the agent with its tool codecs
//// into each run, Relay copies desk tool definitions into the processes that
//// serve each request, and a decision point's codec travels with its work.
//// These bounds hold what this application hands over; a nested combinator
//// codec that multiplies its size, or a child codec captured by a later
//// field, fails them. See the codec practice guide:
//// https://github.com/lostbean/json_blueprint/blob/main/docs/CODEC-PRACTICE.md

import gleam/list
import gleam/time/duration
import payout_desk/agent
import payout_desk/desk_tools
import payout_desk/domain

@external(erlang, "copy_cost_ffi", "flat_size_bytes")
fn flat_size_bytes(term: a) -> Int

/// Each value handed over: its name, its copied size in bytes and its
/// budget in bytes.
pub fn handed_off() -> List(#(String, Int, Int)) {
  let assert Ok(payout_agent) = agent.build(agent.Careful, fn() { False })
  [
    #("propose definition", flat_size_bytes(agent.propose_definition()), 16_384),
    #("fabric agent", flat_size_bytes(payout_agent), 81_920),
    #(
      "queue definition",
      flat_size_bytes(desk_tools.queue_definition()),
      32_768,
    ),
    // Most of this is `decisions/view.codec`, which binds the output codec
    // and its schema above the record so that every later field captures
    // them; that is the decisions library's to change.
    #("open definition", flat_size_bytes(desk_tools.open_definition()), 393_216),
    #(
      "decide definition",
      flat_size_bytes(desk_tools.decide_definition()),
      24_576,
    ),
    #(
      "payout point",
      flat_size_bytes(domain.payout_point(validity: duration.hours(24))),
      24_576,
    ),
    #("risk point", flat_size_bytes(domain.risk_point()), 16_384),
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
