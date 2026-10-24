// THROWAWAY: Reject invalid running freeze composition.
import lab/saga_checkpoint as checkpoint

pub fn invalid(running: checkpoint.Execution(String, Nil, Nil)) {
  checkpoint.freeze(running)
}
