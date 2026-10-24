// THROWAWAY: Can a retained output type be confused after child reattachment?
import lab/saga_grind

pub fn attach_wrong_output_type(
  child: saga_grind.DurableChild(Int, String, String),
) -> Nil {
  requires_string_output(child)
}

fn requires_string_output(
  _child: saga_grind.DurableChild(String, String, String),
) -> Nil {
  Nil
}
