// THROWAWAY: Reject a Saga node whose input differs from the source port.
import lab/saga
import lab/saga_graph as graph

pub fn invalid(
  builder: graph.Builder(String, Nil, Nil),
  source: graph.Port(String),
  id: graph.NodeId,
  definition: saga.Definition(Int, Int, Nil, Nil),
) -> Result(
  #(graph.Builder(String, Nil, Nil), graph.Port(Int)),
  graph.BuildError,
) {
  graph.add(builder, source, id, definition)
}
