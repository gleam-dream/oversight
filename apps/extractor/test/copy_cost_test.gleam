//// A BEAM copy does not keep sharing, so a term costs its flat size every
//// time it crosses a process. This bound holds the term the application
//// hands to Grind; it is set from a json_blueprint 2.2.0 measurement and
//// fails on 2.1.1. See the codec practice guide, rule 4:
//// https://github.com/lostbean/json_blueprint/blob/main/docs/CODEC-PRACTICE.md#4-test-the-copy-size

import extractor/clients
import extractor/document
import extractor/jobs
import extractor/llm
import gleam/list
import gleam/option.{None}

@external(erlang, "copy_cost_ffi", "flat_size_bytes")
fn flat_size_bytes(term: a) -> Int

/// The term Grind copies into the processes that run each job: the worker,
/// with its codecs and the `Env` its handler captures. Its name, its copied
/// size in bytes and its budget in bytes.
pub fn crossing() -> List(#(String, Int, Int)) {
  let assert Ok(http) = clients.start(clients.Loopback([], 9), None)
  let env =
    jobs.Env(
      clients: http,
      model: llm.model(_, "http://127.0.0.1:9", "sk-scripted"),
      limits: document.default_limits(),
    )
  let worker = jobs.define(env, "extract_copy_cost")
  clients.stop(http)
  [#("worker", flat_size_bytes(worker), 5120)]
}

fn over(entries: List(#(String, Int, Int))) -> List(#(String, Int, Int)) {
  list.filter(entries, fn(entry) {
    let #(_, bytes, budget) = entry
    bytes > budget
  })
}

pub fn worker_handed_to_grind_stays_within_its_copy_budget_test() {
  assert over(crossing()) == []
}
