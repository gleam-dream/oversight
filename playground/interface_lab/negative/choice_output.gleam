// THROWAWAY: Reject branches that do not share one native output type.
import lab/blueprint
import lab/saga

pub fn invalid(
  builder: saga.Builder(Int, Nil, Nil),
  selected: saga.Port(saga.Choice(Int, String)),
  id: saga.NodeId,
  left: saga.Definition(Int, Int, Nil, Nil),
  right: saga.Definition(String, String, Nil, Nil),
  output: blueprint.Codec(Int),
) -> Result(#(saga.Builder(Int, Nil, Nil), saga.Port(Int)), saga.BuildError) {
  saga.choose_children(builder, selected, id, left, right, output)
}
