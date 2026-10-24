import consumers/structured_adapter_alpha as alpha
import consumers/structured_adapter_beta as beta
import lab/blueprint
import lab/llm
import lab/llm_structured as structured
import lab/llm_turn

pub fn invalid(
  wrong_start: fn(
    beta.NativeConfig,
    llm.Request,
    blueprint.Schema,
    List(llm_turn.ToolDeclaration),
  ) -> Result(structured.Reply(llm.Request), llm.CallError),
  correct_resume: fn(alpha.NativeConfig, llm.Request, List(llm_turn.ToolResult)) ->
    Result(structured.Reply(llm.Request), llm.CallError),
) {
  alpha.select("alpha-json-compact", wrong_start, correct_resume)
}
