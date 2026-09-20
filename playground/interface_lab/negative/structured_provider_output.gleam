import lab/llm
import lab/llm_structured as structured

pub fn invalid(
  prepared: structured.PreparedTurn(String, llm.Request, Nil),
) -> Result(structured.StartedTurn(Int, llm.Request, Nil), structured.TurnError) {
  structured.start(prepared)
}
