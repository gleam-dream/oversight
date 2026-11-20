//// A BEAM copy does not keep sharing, so a term costs its flat size every
//// time it crosses a process. Grind copies the research worker, with the
//// `Deps` it captures, into the processes that run each job, and Fabric
//// copies the agent into each run. These bounds hold those terms. See the
//// codec practice guide:
//// https://github.com/lostbean/json_blueprint/blob/main/docs/CODEC-PRACTICE.md

import envoy
import gleam/list
import gleam/option.{None}
import gleam/time/duration
import research_agent/app
import research_agent/services

@external(erlang, "copy_cost_ffi", "flat_size_bytes")
fn flat_size_bytes(term: a) -> Int

/// Each term handed to another process: its name, its copied size in bytes
/// and its budget in bytes.
pub fn crossing() -> List(#(String, Int, Int)) {
  let assert Ok(database_url) = envoy.get("DATABASE_URL")
    as "run the tests with ../scripts/with-postgres.sh gleam test"
  let assert Ok(world) = services.start()
  let assert Ok(node) =
    app.start(app.Settings(
      database_url:,
      node: "copy-cost-node",
      schema: "t_copy_cost",
      services: services.base_url(world),
      fabric_lease: duration.seconds(1),
      telemetry: None,
    ))
  let measured = [
    #("fabric agent", flat_size_bytes(node.deps.agent), 36_864),
    #("research worker", flat_size_bytes(node.worker), 61_440),
  ]
  app.stop(node)
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
