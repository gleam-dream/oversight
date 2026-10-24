// THROWAWAY: Reject a Saga node whose input differs from the source port.
import lab/saga

pub fn invalid(
  builder: saga.Builder(String, Nil, Nil),
  source: saga.Port(String),
  id: saga.NodeId,
  definition: saga.Definition(Int, Int, Nil, Nil),
) -> Result(#(saga.Builder(String, Nil, Nil), saga.Port(Int)), saga.BuildError) {
  saga.add_child(builder, source, id, definition)
}
