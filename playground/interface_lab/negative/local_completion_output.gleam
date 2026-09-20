import lab/saga

pub fn invalid(
  completion: saga.LocalCompletion(String, Nil, Nil),
) -> saga.LocalControl(Int, Nil, Nil) {
  saga.CompleteLocal(completion)
}
