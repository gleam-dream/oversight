// THROWAWAY: Scoped completion retains cleanup outcome beside the work result.
import lab/sinal

pub fn invalid(
  completion: sinal.ScopedCompletion(Result(Int, String)),
) -> Result(Int, String) {
  completion
}
