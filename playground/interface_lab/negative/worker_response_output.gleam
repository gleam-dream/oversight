import lab/grind_execution

pub fn invalid(
  response: grind_execution.WorkerResponse(String, Nil),
) -> grind_execution.WorkerResponse(Int, Nil) {
  response
}
