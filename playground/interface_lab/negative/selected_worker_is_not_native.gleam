// THROWAWAY: An erased registry selection cannot regain an invented native type.
import lab/grind
import lab/grind_registry

pub fn invalid(selected: grind_registry.SelectedWorker) -> Result(Int, Nil) {
  grind.invoke(selected, "input")
}
