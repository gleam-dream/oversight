// THROWAWAY: Can a read context invoke a context tool requiring write context?
import consumers/tool_turns as examples
import lab/fabric
import lab/value

pub fn invoke_sensitive_write(
  tool: fabric.ContextTool(examples.WriteContext),
  context: examples.ReadContext,
) -> Result(value.Value, fabric.ToolError) {
  fabric.invoke_context(tool, context, value.Text("checkout"))
}
