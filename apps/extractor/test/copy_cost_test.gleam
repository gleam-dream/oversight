//// A BEAM copy does not keep sharing, so a value costs its flat size every
//// time it crosses a process. Grind copies a worker and its codecs into the
//// processes that run each job. These bounds hold what this application
//// hands to Grind; a nested combinator codec that multiplies its size, or a
//// child codec captured by a later field, fails them. See the codec practice
//// guide: https://github.com/lostbean/json_blueprint/blob/main/docs/CODEC-PRACTICE.md

import extractor/clients
import extractor/document
import extractor/invoice
import extractor/jobs
import extractor/llm
import gleam/list
import gleam/option.{None}

@external(erlang, "copy_cost_ffi", "flat_size_bytes")
fn flat_size_bytes(term: a) -> Int

/// Each value handed to Grind: its name, its copied size in bytes and its
/// budget in bytes.
pub fn handed_off() -> List(#(String, Int, Int)) {
  let assert Ok(http) = clients.start(clients.Loopback([], 9), None)
  let env =
    jobs.Env(
      clients: http,
      model: llm.model(_, "http://127.0.0.1:9", "sk-scripted"),
      limits: document.default_limits(),
    )
  let worker = jobs.define(env, "extract_copy_cost")
  clients.stop(http)
  [
    #("invoice codec", flat_size_bytes(invoice.codec()), 4096),
    #("job input codec", flat_size_bytes(jobs.input_codec()), 4096),
    #("job output codec", flat_size_bytes(jobs.output_codec()), 8192),
    #("job error codec", flat_size_bytes(jobs.error_codec()), 16_384),
    #("worker", flat_size_bytes(worker), 32_768),
  ]
}

pub fn values_handed_to_grind_stay_within_their_copy_budget_test() {
  let over =
    list.filter(handed_off(), fn(entry) {
      let #(_, bytes, budget) = entry
      bytes > budget
    })
  assert over == []
}
