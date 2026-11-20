//// A BEAM copy does not keep sharing, so a term costs its flat size every
//// time it crosses a process. See the codec practice guide:
//// https://github.com/lostbean/json_blueprint/blob/main/docs/CODEC-PRACTICE.md

import extractor/clients
import extractor/document
import extractor/invoice
import extractor/jobs
import extractor/llm
import gleam/list
import gleam/option.{None}

@external(erlang, "copy_cost_ffi", "flat_size_bytes")
fn flat_size_bytes(term: a) -> Int

/// The term Grind copies into the processes that run each job: the worker,
/// with its codecs and the `Env` its handler captures. Its name, its copied
/// size in bytes and its budget in bytes. The bound fails with the job input
/// codec built from combinators instead of generated (16,552 bytes).
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
  [#("worker", flat_size_bytes(worker), 15_360)]
}

/// A codec-size guard. The invoice codec is built where it is used and never
/// crosses a process; the bound fails if a child codec is bound with `let`
/// above the record again and captured by a later field (163,400 bytes).
pub fn codec_guards() -> List(#(String, Int, Int)) {
  [#("invoice codec", flat_size_bytes(invoice.codec()), 4096)]
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

pub fn invoice_codec_captures_no_child_codec_test() {
  assert over(codec_guards()) == []
}
