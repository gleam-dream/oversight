import lab/saga
import lab/saga_graph as graph

pub fn invalid(
  builder: graph.Builder(Int, Nil, Nil),
  input: graph.Port(Int),
  id: graph.NodeId,
  child: saga.Child(Int, Int, Nil, Nil),
) {
  graph.add_activity(builder, input, id, child)
}
