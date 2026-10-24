// THROWAWAY: Reject invalid local durable composition.
import lab/grind
import lab/saga
import lab/saga_grind

pub fn invalid(
  queue: grind.Queue,
  execution: saga.LocalExecution(String, Nil, Nil),
) {
  saga_grind.submit(queue, execution, 42)
}
