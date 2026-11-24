//// A BEAM copy does not keep sharing, so a term costs its flat size every
//// time it crosses a process. Grind copies the report worker into the
//// processes that run each job, and Relay holds the tool list that serves
//// each request. These bounds hold those terms; they are set from
//// json_blueprint 2.2.0 measurements and fail on 2.1.1. See the codec
//// practice guide, rule 4:
//// https://github.com/gleam-dream/json_blueprint/blob/main/docs/CODEC-PRACTICE.md#4-test-the-copy-size

import envoy
import gleam/list
import secure_mcp/app
import secure_mcp/tools

@external(erlang, "copy_cost_ffi", "flat_size_bytes")
fn flat_size_bytes(term: a) -> Int

/// Each term handed to another process: its name, its copied size in bytes
/// and its budget in bytes.
pub fn crossing() -> List(#(String, Int, Int)) {
  let assert Ok(url) = envoy.get("DATABASE_URL")
  let assert Ok(running) = app.start(app.options(url))
  let measured = [
    #("report worker", flat_size_bytes(running.report_worker), 2560),
    #(
      "relay tools",
      flat_size_bytes(tools.tools(running.jobs, running.report_worker)),
      19_456,
    ),
  ]
  app.stop(running)
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
