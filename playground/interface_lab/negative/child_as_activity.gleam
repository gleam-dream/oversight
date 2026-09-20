import lab/saga

pub fn invalid(
  builder: saga.Builder(Int, Nil, Nil),
  input: saga.Port(Int),
  id: saga.NodeId,
  child: saga.Child(Int, Int, Nil, Nil),
) {
  saga.add_activity(builder, input, id, child)
}
