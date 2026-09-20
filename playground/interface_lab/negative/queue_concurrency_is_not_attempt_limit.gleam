import lab/grind_execution
import lab/grind_queue

pub fn invalid(limit: grind_queue.LocalConcurrency) {
  grind_execution.attempt_accounting(1, limit, 0)
}
