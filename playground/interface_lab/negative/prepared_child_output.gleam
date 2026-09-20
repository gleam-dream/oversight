// THROWAWAY: Can preparing a child erase its retained native output codec?
import lab/saga_grind

pub fn cannot_change_output(
  prepared: saga_grind.PreparedChild(Int, String, String),
) -> saga_grind.PreparedChild(String, String, String) {
  prepared
}
