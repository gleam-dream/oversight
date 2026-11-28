//// A BEAM copy does not keep sharing, so a term costs its flat size every
//// time it crosses a process. Grind copies each worker, with the `Deps` it
//// captures, into the processes that run each job; Relay holds the desk's
//// tool list and Fabric copies the agent into each run. These bounds hold
//// those terms; the workers' and the tools' are set from json_blueprint
//// 2.2.0 measurements and fail on 2.1.1. Fabric 0.6 copies the agent's
//// builder, 232 bytes here, instead of the built agent with its tool codecs. See the codec practice guide, rule 4:
//// https://github.com/gleam-dream/json_blueprint/blob/main/docs/CODEC-PRACTICE.md#4-test-the-copy-size

import gleam/list
import payout_desk/desk_tools
import payout_desk/jobs
import support

@external(erlang, "payout_desk_copy_cost_ffi", "flat_size_bytes")
fn flat_size_bytes(term: a) -> Int

/// Each term handed to another process: its name, its copied size in bytes
/// and its budget in bytes.
pub fn crossing() -> List(#(String, Int, Int)) {
  use running <- support.with_app("copy_cost", fn(settings) { settings })
  let deps = running.deps
  [
    #("fabric agent", flat_size_bytes(deps.agent), 1024),
    #("agent worker", flat_size_bytes(jobs.agent_worker(deps)), 24_576),
    #("pay worker", flat_size_bytes(jobs.pay_worker(deps)), 24_576),
    #("reconcile worker", flat_size_bytes(jobs.reconcile_worker(deps)), 24_576),
    #("tell worker", flat_size_bytes(jobs.tell_worker(deps)), 24_576),
    // About 66 kB of this is the `open_payout` definition, whose output codec
    // is `decisions/view.codec`: it holds the payout schema parsed into a
    // JSON value. Relay holds the tool list for every request.
    #(
      "relay desk tools",
      flat_size_bytes(desk_tools.tools(running.tools)),
      106_496,
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
