// THROWAWAY: Export actual server output for the frozen upstream schema oracle.
import consumers/modern_relay
import lab/value

@external(erlang, "schema_corpus_ffi", "emit")
fn emit(item: value.Value) -> Nil

pub fn main() -> Nil {
  emit_cases(modern_relay.wire_examples())
}

fn emit_cases(cases: List(#(String, String, value.Value))) -> Nil {
  case cases {
    [] -> Nil
    [#(label, definition, instance), ..rest] -> {
      emit(
        value.Object([
          #("label", value.Text(label)),
          #("definition", value.Text(definition)),
          #("instance", instance),
        ]),
      )
      emit_cases(rest)
    }
  }
}
