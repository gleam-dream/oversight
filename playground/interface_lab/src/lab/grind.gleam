// THROWAWAY: Can Grind package typed handlers separately from workflow execution?
import lab/blueprint.{type Codec, type DecodeError, type EncodeError}
import lab/value.{type Value}

pub type WorkerIdentityError {
  WorkerIdMustNotBeEmpty
  WorkerVersionMustBePositive
}

pub opaque type WorkerId {
  WorkerId(String)
}

pub fn worker_id(value: String) -> Result(WorkerId, WorkerIdentityError) {
  case value {
    "" -> Error(WorkerIdMustNotBeEmpty)
    _ -> Ok(WorkerId(value))
  }
}

pub opaque type WorkerVersion {
  WorkerVersion(Int)
}

pub fn worker_version(
  value: Int,
) -> Result(WorkerVersion, WorkerIdentityError) {
  case value {
    n if n > 0 -> Ok(WorkerVersion(n))
    _ -> Error(WorkerVersionMustBePositive)
  }
}

pub type WorkerFailure {
  WorkerInputDidNotDecode(DecodeError)
  WorkerOutputDidNotEncode(EncodeError)
  WorkerErrorDidNotEncode(EncodeError)
  WorkerActionFailed(Value)
}

pub opaque type Worker(i, o, e) {
  Worker(
    id: WorkerId,
    version: WorkerVersion,
    input_codec: Codec(i),
    output_codec: Codec(o),
    error_codec: Codec(e),
    handler: fn(i) -> Result(o, e),
    invoke: fn(Value) -> Result(Value, WorkerFailure),
  )
}

// Worker packaging is constructive: the stable identity, codecs, typed handler,
// and codec-backed heterogeneous invocation are all retained together.
pub fn worker(
  id: WorkerId,
  version: WorkerVersion,
  input: Codec(i),
  output: Codec(o),
  error: Codec(e),
  handler: fn(i) -> Result(o, e),
) -> Worker(i, o, e) {
  Worker(id, version, input, output, error, handler, fn(raw) {
    case blueprint.decode(input, raw) {
      Error(decode_error) -> Error(WorkerInputDidNotDecode(decode_error))
      Ok(typed_input) ->
        case handler(typed_input) {
          Ok(typed_output) ->
            case blueprint.encode(output, typed_output) {
              Ok(encoded_output) -> Ok(encoded_output)
              Error(encode_error) ->
                Error(WorkerOutputDidNotEncode(encode_error))
            }
          Error(handler_error) ->
            case blueprint.encode(error, handler_error) {
              Ok(encoded_error) -> Error(WorkerActionFailed(encoded_error))
              Error(encode_error) ->
                Error(WorkerErrorDidNotEncode(encode_error))
            }
        }
    }
  })
}

pub fn invoke(worker: Worker(i, o, e), input: i) -> Result(o, e) {
  worker.handler(input)
}

pub fn invoke_value(
  worker: Worker(i, o, e),
  input: Value,
) -> Result(Value, WorkerFailure) {
  worker.invoke(input)
}

pub opaque type JobId {
  JobId(String)
}

pub fn job_id(value: String) -> JobId {
  JobId(value)
}

pub fn job_id_value(id: JobId) -> String {
  let JobId(value) = id
  value
}

pub type AdmissionError {
  CapacityUnavailable
  QueueStorageUnavailable
  AdmissionRejected(Value)
}

pub opaque type AvailableAt {
  AvailableAt(unix_milliseconds: Int)
}

pub type ScheduleError {
  AvailableAtMustNotBeNegative
}

// Absolute Unix milliseconds are explicit; this value is not a relative delay.
pub fn available_at(
  unix_milliseconds: Int,
) -> Result(AvailableAt, ScheduleError) {
  case unix_milliseconds >= 0 {
    True -> Ok(AvailableAt(unix_milliseconds))
    False -> Error(AvailableAtMustNotBeNegative)
  }
}

pub fn available_at_milliseconds(available_at: AvailableAt) -> Int {
  let AvailableAt(unix_milliseconds) = available_at
  unix_milliseconds
}

pub type Availability {
  Immediate
  At(AvailableAt)
}

// Queue admission receives the same worker identity and encoded payload for
// immediate and scheduled jobs. A real queue owns timing and durability.
pub type Admission {
  Admission(
    worker_id: String,
    worker_version: Int,
    payload: Value,
    availability: Availability,
  )
}

pub opaque type Queue {
  Queue(admit: fn(Admission) -> Result(JobId, AdmissionError))
}

pub fn queue(admit: fn(Admission) -> Result(JobId, AdmissionError)) -> Queue {
  Queue(admit)
}

pub fn admit(
  queue: Queue,
  worker_id: String,
  worker_version: Int,
  payload: Value,
) -> Result(JobId, AdmissionError) {
  admit_with_availability(queue, worker_id, worker_version, payload, Immediate)
}

pub fn admit_at(
  queue: Queue,
  worker_id: String,
  worker_version: Int,
  payload: Value,
  available_at: AvailableAt,
) -> Result(JobId, AdmissionError) {
  admit_with_availability(
    queue,
    worker_id,
    worker_version,
    payload,
    At(available_at),
  )
}

fn admit_with_availability(
  queue: Queue,
  worker_id: String,
  worker_version: Int,
  payload: Value,
  availability: Availability,
) -> Result(JobId, AdmissionError) {
  let Queue(admit) = queue
  admit(Admission(worker_id, worker_version, payload, availability))
}

pub opaque type JobHandle(o, e) {
  JobHandle(id: JobId, output_codec: Codec(o), error_codec: Codec(e))
}

pub type SubmitError {
  InputCouldNotEncode(EncodeError)
  JobCouldNotBeAdmitted(AdmissionError)
}

// Submission returns a typed handle. It never returns the worker's final output.
pub fn submit(
  queue: Queue,
  worker: Worker(i, o, e),
  input: i,
) -> Result(JobHandle(o, e), SubmitError) {
  submit_with_availability(queue, worker, input, Immediate)
}

pub fn submit_at(
  queue: Queue,
  worker: Worker(i, o, e),
  input: i,
  available_at: AvailableAt,
) -> Result(JobHandle(o, e), SubmitError) {
  submit_with_availability(queue, worker, input, At(available_at))
}

fn submit_with_availability(
  queue: Queue,
  worker: Worker(i, o, e),
  input: i,
  availability: Availability,
) -> Result(JobHandle(o, e), SubmitError) {
  case blueprint.encode(worker.input_codec, input) {
    Error(error) -> Error(InputCouldNotEncode(error))
    Ok(payload) -> {
      let WorkerId(id) = worker.id
      let WorkerVersion(version) = worker.version
      case admit_with_availability(queue, id, version, payload, availability) {
        Error(error) -> Error(JobCouldNotBeAdmitted(error))
        Ok(job_id) ->
          Ok(JobHandle(job_id, worker.output_codec, worker.error_codec))
      }
    }
  }
}

pub type JobOutcome(o, e) {
  JobSucceeded(o)
  JobFailed(e)
  JobCancelled
}

pub type JobState(o, e) {
  JobScheduled(AvailableAt)
  JobQueued
  JobRunning(CancelIntent)
  JobSuspended(Value)
  JobFinished(JobOutcome(o, e))
}

pub type CancelIntent {
  NoRequest
  Requested
}

pub type CancellationTransition(o, e) {
  CancelledWhileInactive
  CancellationRequested
  AlreadyCancelled
  AlreadyFinished(JobOutcome(o, e))
}

// This pure rule makes no claim that an inactive job has had no effects in an
// earlier attempt. Storage adapters must load and atomically persist this step.
pub fn cancellation_transition(
  state: JobState(o, e),
) -> #(JobState(o, e), CancellationTransition(o, e)) {
  case state {
    JobScheduled(_) -> #(JobFinished(JobCancelled), CancelledWhileInactive)
    JobQueued -> #(JobFinished(JobCancelled), CancelledWhileInactive)
    JobSuspended(_) -> #(JobFinished(JobCancelled), CancelledWhileInactive)
    JobRunning(NoRequest) -> #(JobRunning(Requested), CancellationRequested)
    JobRunning(Requested) -> #(JobRunning(Requested), CancellationRequested)
    JobFinished(JobCancelled) -> #(JobFinished(JobCancelled), AlreadyCancelled)
    JobFinished(outcome) -> #(JobFinished(outcome), AlreadyFinished(outcome))
  }
}

pub type CancelError {
  CancelJobNotFound
  CancellationStorageUnavailable
}

// A concrete queue adapter must load the latest state and atomically persist
// the pure transition above; this prototype does neither operation.
pub fn cancel(
  _queue: Queue,
  _handle: JobHandle(o, e),
) -> Result(CancellationTransition(o, e), CancelError) {
  todo as "load and persist the cancellation transition through queue storage"
}

pub type PollError {
  JobNotFound
  JobStateCouldNotBeDecoded(String)
}

pub fn job_id_of(handle: JobHandle(o, e)) -> JobId {
  handle.id
}

pub fn poll(
  _queue: Queue,
  _handle: JobHandle(o, e),
) -> Result(JobState(o, e), PollError) {
  todo as "read a committed job state and decode its typed outcome"
}
