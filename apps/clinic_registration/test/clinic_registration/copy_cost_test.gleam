//// A BEAM copy does not keep sharing, so a term costs its flat size every
//// time it crosses a process. See the codec practice guide:
//// https://github.com/lostbean/json_blueprint/blob/main/docs/CODEC-PRACTICE.md

import clinic_registration/desk
import clinic_registration/domain
import clinic_registration/jobs
import gleam/list
import support

@external(erlang, "copy_cost_ffi", "flat_size_bytes")
fn flat_size_bytes(term: a) -> Int

/// The terms Grind copies into the processes that run each job: both workers
/// capture the whole job `Env`, with the desk, the model configuration and
/// the HTTP client. Each entry: its name, its copied size in bytes and its
/// budget in bytes.
pub fn crossing() -> List(#(String, Int, Int)) {
  use env <- support.with_app(fn(config) { config })
  [
    #("register worker", flat_size_bytes(env.app.register), 45_056),
    #(
      "confirm worker",
      flat_size_bytes(jobs.confirm_worker(env.app.env)),
      45_056,
    ),
  ]
}

/// Codec-size guards. These codecs are built where they are used and never
/// cross a process; each bound fails if a child codec is bound with `let`
/// above the record again and captured by a later field.
pub fn codec_guards() -> List(#(String, Int, Int)) {
  [
    #("extraction codec", flat_size_bytes(domain.extraction_codec()), 3072),
    // Most of this is `decisions/view.codec`, whose later fields capture the
    // output codec: https://github.com/lostbean/json_blueprint/blob/main/issues/record-copy-cost/issues/01-hold-a-record-continuation-once.md
    // The bound sits between the current size and the size with the
    // `exchange` codec captured again.
    #("card codec", flat_size_bytes(desk.card_codec()), 286_720),
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

pub fn codecs_capture_no_child_codec_test() {
  assert over(codec_guards()) == []
}
