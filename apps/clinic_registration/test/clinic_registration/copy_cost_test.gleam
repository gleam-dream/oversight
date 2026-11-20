//// A BEAM copy does not keep sharing, so a value costs its flat size every
//// time it crosses a process. Grind copies each worker's closure, with the
//// desk and its decision point, into the processes that run each job. These
//// bounds hold the codecs that travel that way; a nested combinator codec
//// that multiplies its size, or a child codec captured by a later field,
//// fails them. See the codec practice guide:
//// https://github.com/lostbean/json_blueprint/blob/main/docs/CODEC-PRACTICE.md

import clinic_registration/desk
import clinic_registration/domain
import gleam/list

@external(erlang, "copy_cost_ffi", "flat_size_bytes")
fn flat_size_bytes(term: a) -> Int

/// Each value handed over: its name, its copied size in bytes and its
/// budget in bytes.
pub fn handed_off() -> List(#(String, Int, Int)) {
  [
    #("registration point", flat_size_bytes(domain.point()), 32_768),
    #("extraction codec", flat_size_bytes(domain.extraction_codec()), 4096),
    #("context codec", flat_size_bytes(domain.context_codec()), 8192),
    // Most of this is `decisions/view.codec`, which binds the output codec
    // and its schema above the record so that every later field captures
    // them; that is the decisions library's to change.
    #("card codec", flat_size_bytes(desk.card_codec()), 589_824),
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
