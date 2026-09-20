// THROWAWAY: Reject invalid local durable composition.
import lab/grind
import lab/saga
import lab/saga_grind

pub fn invalid(
  queue: grind.Queue,
  plan: saga.LocalPlan(Int, String, Nil, Nil),
) {
  saga_grind.submit(queue, plan, 42)
}
