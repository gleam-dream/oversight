// THROWAWAY: Can a previous-response provider accept a transcript continuation?
import consumers/tool_turns as examples
import lab/llm
import lab/llm_turn as model

pub fn continue_wrong_provider(
  provider: model.Provider(examples.PreviousResponseId),
  continuation: examples.Transcript,
  results: List(model.ToolResult),
) -> Result(model.Reply(examples.PreviousResponseId), llm.CallError) {
  model.continue(provider, continuation, results)
}
