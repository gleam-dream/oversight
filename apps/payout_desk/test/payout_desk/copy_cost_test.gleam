//// A BEAM copy does not keep sharing, so a term costs its flat size every
//// time it crosses a process. Grind copies each worker, with the `Deps` it
//// captures, into the processes that run each job; Relay holds the desk's
//// tool list and Fabric copies the agent into each run. These bounds hold
//// those terms. See the codec practice guide:
//// https://github.com/lostbean/json_blueprint/blob/main/docs/CODEC-PRACTICE.md

import gleam/list
import payout_desk/desk_tools
import payout_desk/jobs
import support

@external(erlang, "copy_cost_ffi", "flat_size_bytes")
fn flat_size_bytes(term: a) -> Int

/// Each term handed to another process: its name, its copied size in bytes
/// and its budget in bytes.
pub fn crossing() -> List(#(String, Int, Int)) {
  use running <- support.with_app("copy_cost", fn(settings) { settings })
  let deps = running.deps
  [
    #("fabric agent", flat_size_bytes(deps.agent), 49_152),
    #("agent worker", flat_size_bytes(jobs.agent_worker(deps)), 57_344),
    #("pay worker", flat_size_bytes(jobs.pay_worker(deps)), 57_344),
    #("reconcile worker", flat_size_bytes(jobs.reconcile_worker(deps)), 57_344),
    #("tell worker", flat_size_bytes(jobs.tell_worker(deps)), 57_344),
    // Most of this is the `open_payout` definition's output codec,
    // `decisions/view.codec`, whose later fields capture the payout codec.
    // Relay copies it with the tool list. Owned upstream:
    // https://github.com/lostbean/json_blueprint/blob/main/issues/record-copy-cost/issues/01-hold-a-record-continuation-once.md
    // and decisions' copy-cost issue 31:
    // https://github.com/gleam-dream/decisions/blob/main/issues/first-applications-findings/issues/31-an-isolated-model-is-copied-into-every-call.md
    #(
      "relay desk tools",
      flat_size_bytes(desk_tools.tools(running.tools)),
      229_376,
    ),
  ]
}

pub fn terms_handed_to_other_processes_stay_within_their_copy_budget_test() {
  let over =
    list.filter(crossing(), fn(entry) {
      let #(_, bytes, budget) = entry
      bytes > budget
    })
  assert over == []
}
