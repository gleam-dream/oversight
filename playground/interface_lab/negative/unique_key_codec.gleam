// THROWAWAY: Can a projection use a codec for another native key type?
import lab/blueprint
import lab/grind

pub fn invalid(
  identity: grind.UniqueKeyIdentity,
  period: grind.UniquePeriod,
  codec: blueprint.Codec(Int),
) {
  grind.selected_input(
    grind.WithinQueue,
    period,
    grind.Incomplete,
    identity,
    fn(_input: Int) { "projected text" },
    codec,
  )
}
