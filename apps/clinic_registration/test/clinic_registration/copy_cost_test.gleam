//// A BEAM copy does not keep sharing, so a term costs its flat size every
//// time it crosses a process. These bounds hold the terms the application
//// hands to Grind; they are set from json_blueprint 2.2.0 measurements and
//// fail on 2.1.1. See the codec practice guide, rule 4:
//// https://github.com/gleam-dream/json_blueprint/blob/main/docs/CODEC-PRACTICE.md#4-test-the-copy-size

import clinic_registration/jobs
import gleam/list
import support

@external(erlang, "clinic_registration_copy_cost_ffi", "flat_size_bytes")
fn flat_size_bytes(term: a) -> Int

/// The terms Grind copies into the processes that run each job: both workers
/// capture the whole job `Env`, with the desk, the model configuration and
/// the HTTP client. Each entry: its name, its copied size in bytes and its
/// budget in bytes.
pub fn crossing() -> List(#(String, Int, Int)) {
  use env <- support.with_app(fn(config) { config })
  [
    #("register worker", flat_size_bytes(env.app.register), 28_672),
    #(
      "confirm worker",
      flat_size_bytes(jobs.confirm_worker(env.app.env)),
      28_672,
    ),
  ]
}

fn over(entries: List(#(String, Int, Int))) -> List(#(String, Int, Int)) {
  list.filter(entries, fn(entry) {
    let #(_, bytes, budget) = entry
    bytes > budget
  })
}

pub fn workers_handed_to_grind_stay_within_their_copy_budget_test() {
  assert over(crossing()) == []
}
