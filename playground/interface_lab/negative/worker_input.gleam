// THROWAWAY: Reject input that disagrees with the registered worker.
import lab/grind

pub fn invalid(queue: grind.Queue, worker: grind.Worker(Int, String, Nil)) {
  grind.submit(queue, worker, "not an integer")
}
