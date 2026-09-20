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

// Queue admission is a typed seam. A real queue supplies the implementation;
// this playground does not claim leasing, retries, or durable delivery.
pub opaque type Queue {
  Queue(admit: fn(String, Int, Value) -> Result(JobId, AdmissionError))
}

pub fn queue(
  admit: fn(String, Int, Value) -> Result(JobId, AdmissionError),
) -> Queue {
  Queue(admit)
}

pub fn admit(
  queue: Queue,
  worker_id: String,
  worker_version: Int,
  payload: Value,
) -> Result(JobId, AdmissionError) {
  let Queue(admit) = queue
  admit(worker_id, worker_version, payload)
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
  case blueprint.encode(worker.input_codec, input) {
    Error(error) -> Error(InputCouldNotEncode(error))
    Ok(payload) -> {
      let WorkerId(id) = worker.id
      let WorkerVersion(version) = worker.version
      case admit(queue, id, version, payload) {
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
  JobQueued
  JobRunning
  JobSuspended(Value)
  JobFinished(JobOutcome(o, e))
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
