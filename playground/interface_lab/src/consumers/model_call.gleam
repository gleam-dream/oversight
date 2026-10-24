// THROWAWAY: Can a typed model call be used without Fabric or Saga?
import lab/blueprint
import lab/llm

pub fn classify(
  provider: llm.Provider,
  text: String,
) -> Result(Bool, llm.CallError) {
  llm.structured(provider, llm.Request([llm.User(text)], 32), blueprint.bool())
}
