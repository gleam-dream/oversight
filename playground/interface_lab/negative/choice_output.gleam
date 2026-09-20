// THROWAWAY: Reject branches that do not share one native output type.
import lab/blueprint
import lab/saga
import lab/saga_graph as graph

pub fn invalid(
  builder: graph.Builder(Int, Nil, Nil),
  selected: graph.Port(graph.Choice(Int, String)),
  id: graph.NodeId,
  left: saga.Definition(Int, Int, Nil, Nil),
  right: saga.Definition(String, String, Nil, Nil),
  output: blueprint.Codec(Int),
) -> Result(#(graph.Builder(Int, Nil, Nil), graph.Port(Int)), graph.BuildError) {
  graph.choose_children(builder, selected, id, left, right, output)
}
