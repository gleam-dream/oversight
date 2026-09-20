// THROWAWAY: Can a runtime-selected contract replace a compiled codec?
import lab/blueprint
import lab/blueprint_runtime
import lab/value

pub fn invalid(contract: blueprint_runtime.RuntimeContract) {
  blueprint.decode(contract, value.Text("order-1"))
}
