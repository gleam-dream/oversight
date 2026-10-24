// THROWAWAY: Can a retained undo-error type be substituted after reattachment?
import lab/saga_grind

pub fn attach_wrong_undo_type(
  child: saga_grind.DurableChild(String, String, Int),
) -> Nil {
  requires_string_undo(child)
}

fn requires_string_undo(
  _child: saga_grind.DurableChild(String, String, String),
) -> Nil {
  Nil
}
