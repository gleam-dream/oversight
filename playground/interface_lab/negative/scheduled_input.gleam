// THROWAWAY: Reject input whose type disagrees with the scheduled worker.
import lab/blueprint
import lab/grind

pub fn invalid(
  queue: grind.Queue,
  available: grind.AvailableAt,
) -> Result(grind.JobHandle(String, String), grind.SubmitError) {
  let assert Ok(id) = grind.worker_id("refresh-count")
  let assert Ok(version) = grind.worker_version(1)
  let worker =
    grind.worker(
      id,
      version,
      blueprint.int(),
      blueprint.text(),
      blueprint.text(),
      fn(_value) { Ok("done") },
    )
  grind.submit_at(queue, worker, "not an integer", available)
}
