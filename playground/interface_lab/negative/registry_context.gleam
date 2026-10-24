import lab/fabric
import lab/value

pub fn invalid(registry: fabric.Registry(Int)) {
  fabric.dispatch(registry, "tenant", "lookup", value.Int(1))
}
