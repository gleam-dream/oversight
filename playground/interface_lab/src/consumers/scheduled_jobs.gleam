// THROWAWAY: Can delayed admission and cancellation be expressed without a scheduler?
import lab/blueprint
import lab/grind
import lab/value

pub fn probe() -> Nil {
  let available = must_time(grind.available_at(1_800_000_000_000))
  let assert 1_800_000_000_000 = grind.available_at_milliseconds(available)
  let scheduled_route = route_fixture("scheduled-jobs")
  let scheduled_queue =
    grind.queue(scheduled_route, fn(admission) {
      case admission {
        grind.Admission(
          actual_route,
          "rebuild-index",
          3,
          value.Int(41),
          grind.At(actual_time),
        ) ->
          case
            actual_time == available
            && grind.same_queue_route(actual_route, scheduled_route)
          {
            True -> Ok(grind.job_id("scheduled-41"))
            False ->
              Error(grind.AdmissionRejected(value.Text("wrong route or time")))
          }
        _ -> Error(grind.AdmissionRejected(value.Text("unexpected admission")))
      }
    })
  let worker = worker_fixture()
  let scheduled: Result(grind.JobHandle(String, String), grind.SubmitError) =
    grind.submit_at(scheduled_queue, worker, 41, available)
  let assert Ok(scheduled_handle) = scheduled
  let assert "scheduled-41" =
    grind.job_id_value(grind.job_id_of(scheduled_handle))

  let immediate_route = route_fixture("immediate-jobs")
  let immediate_queue =
    grind.queue(immediate_route, fn(admission) {
      case admission {
        grind.Admission(
          actual_route,
          "rebuild-index",
          3,
          value.Int(7),
          grind.Immediate,
        ) ->
          case grind.same_queue_route(actual_route, immediate_route) {
            True -> Ok(grind.job_id("immediate-7"))
            False -> Error(grind.AdmissionRejected(value.Text("wrong route")))
          }
        _ -> Error(grind.AdmissionRejected(value.Text("unexpected admission")))
      }
    })
  let immediate: Result(grind.JobHandle(String, String), grind.SubmitError) =
    grind.submit(immediate_queue, worker, 7)
  let assert Ok(immediate_handle) = immediate
  let assert "immediate-7" =
    grind.job_id_value(grind.job_id_of(immediate_handle))
  let assert Error(grind.AvailableAtMustNotBeNegative) = grind.available_at(-1)

  let assert #(
    grind.JobFinished(grind.JobCancelled),
    grind.CancelledWhileInactive,
  ) = grind.cancellation_transition(grind.JobScheduled(available))
  let assert #(
    grind.JobFinished(grind.JobCancelled),
    grind.CancelledWhileInactive,
  ) = grind.cancellation_transition(grind.JobQueued)
  let assert #(
    grind.JobFinished(grind.JobCancelled),
    grind.CancelledWhileInactive,
  ) = grind.cancellation_transition(grind.JobSuspended(value.Null))
  let assert #(grind.JobRunning(grind.Requested), grind.CancellationRequested) =
    grind.cancellation_transition(grind.JobRunning(grind.NoRequest))
  let assert #(grind.JobRunning(grind.Requested), grind.CancellationRequested) =
    grind.cancellation_transition(grind.JobRunning(grind.Requested))
  let assert #(grind.JobFinished(grind.JobCancelled), grind.AlreadyCancelled) =
    grind.cancellation_transition(grind.JobFinished(grind.JobCancelled))
  let assert #(
    grind.JobFinished(grind.JobSucceeded("done")),
    grind.AlreadyFinished(grind.JobSucceeded("done")),
  ) =
    grind.cancellation_transition(grind.JobFinished(grind.JobSucceeded("done")))
  let assert #(
    grind.JobFinished(grind.JobFailed("reason")),
    grind.AlreadyFinished(grind.JobFailed("reason")),
  ) =
    grind.cancellation_transition(grind.JobFinished(grind.JobFailed("reason")))
  Nil
}

fn worker_fixture() -> grind.Worker(Int, String, String) {
  let assert Ok(id) = grind.worker_id("rebuild-index")
  let assert Ok(version) = grind.worker_version(3)
  grind.worker(
    id,
    version,
    blueprint.int(),
    blueprint.text(),
    blueprint.text(),
    fn(_input) { todo as "admission must not execute the worker" },
  )
}

fn must_time(
  value: Result(grind.AvailableAt, grind.ScheduleError),
) -> grind.AvailableAt {
  let assert Ok(available) = value
  available
}

fn route_fixture(name: String) -> grind.QueueRoute {
  let assert Ok(owner) = grind.queue_owner("scheduled-jobs-storage")
  let assert Ok(queue_name) = grind.queue_name(name)
  grind.queue_route(owner, queue_name)
}
