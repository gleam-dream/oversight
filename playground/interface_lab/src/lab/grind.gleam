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

// Registry adapters can inspect identity without gaining access to a worker's
// native handler or codecs.
pub fn worker_identity(worker: Worker(i, o, e)) -> #(WorkerId, WorkerVersion) {
  #(worker.id, worker.version)
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

pub type QueueIdentityError {
  QueueOwnerMustNotBeEmpty
  QueueNameMustNotBeEmpty
}

pub opaque type QueueOwner {
  QueueOwner(String)
}

pub fn queue_owner(value: String) -> Result(QueueOwner, QueueIdentityError) {
  case value {
    "" -> Error(QueueOwnerMustNotBeEmpty)
    _ -> Ok(QueueOwner(value))
  }
}

pub opaque type QueueName {
  QueueName(String)
}

pub fn queue_name(value: String) -> Result(QueueName, QueueIdentityError) {
  case value {
    "" -> Error(QueueNameMustNotBeEmpty)
    _ -> Ok(QueueName(value))
  }
}

// The owner names one storage namespace; the queue names one queue inside it.
// Recovery checks both before a port callback can run.
pub opaque type QueueRoute {
  QueueRoute(QueueOwner, QueueName)
}

pub fn queue_route(owner: QueueOwner, name: QueueName) -> QueueRoute {
  QueueRoute(owner, name)
}

pub fn queue_owner_value(route: QueueRoute) -> String {
  let QueueRoute(QueueOwner(owner), _) = route
  owner
}

pub fn queue_name_value(route: QueueRoute) -> String {
  let QueueRoute(_, QueueName(name)) = route
  name
}

pub fn same_queue_route(left: QueueRoute, right: QueueRoute) -> Bool {
  left == right
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
    route: QueueRoute,
    worker_id: String,
    worker_version: Int,
    payload: Value,
    availability: Availability,
  )
}

type UniquePort {
  NoUniquePort
  HasUniquePort(fn(UniqueRequest) -> UniquePortResponse)
}

pub opaque type Queue {
  Queue(
    route: QueueRoute,
    admit: fn(Admission) -> Result(JobId, AdmissionError),
    unique_port: UniquePort,
  )
}

pub fn queue(
  route: QueueRoute,
  admit: fn(Admission) -> Result(JobId, AdmissionError),
) -> Queue {
  Queue(route, admit, NoUniquePort)
}

pub fn with_unique_admission_port(
  queue: Queue,
  port: fn(UniqueRequest) -> UniquePortResponse,
) -> Queue {
  let Queue(route, admit, _) = queue
  Queue(route, admit, HasUniquePort(port))
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
  let Queue(route, admit, _) = queue
  admit(Admission(route, worker_id, worker_version, payload, availability))
}

pub opaque type JobHandle(o, e) {
  JobHandle(
    id: JobId,
    route: QueueRoute,
    output_codec: Codec(o),
    error_codec: Codec(e),
  )
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
        Ok(job_id) -> {
          let Queue(route, _, _) = queue
          Ok(JobHandle(job_id, route, worker.output_codec, worker.error_codec))
        }
      }
    }
  }
}

pub type UniqueConfigurationError {
  UniquePeriodMustBePositive
  UniqueKeyPolicyIdMustNotBeEmpty
  UniqueKeyPolicyVersionMustBePositive
  SubmissionIdMustNotBeEmpty
}

pub opaque type PositiveDuration {
  PositiveDuration(milliseconds: Int)
}

pub fn positive_duration(
  milliseconds: Int,
) -> Result(PositiveDuration, UniqueConfigurationError) {
  case milliseconds > 0 {
    True -> Ok(PositiveDuration(milliseconds))
    False -> Error(UniquePeriodMustBePositive)
  }
}

pub fn positive_duration_milliseconds(duration: PositiveDuration) -> Int {
  let PositiveDuration(milliseconds) = duration
  milliseconds
}

pub type UniqueTimestamp {
  FromInsertion
  FromSchedule
}

pub type UniquePeriod {
  For(PositiveDuration, UniqueTimestamp)
  WhileRetained
}

pub type QueueScope {
  WithinQueue
  AcrossQueues
}

pub type UniqueStates {
  Incomplete
  ScheduledOnly
  NotCancelledOrDiscarded
  AllRetained
}

pub type UniqueJobState {
  Suspended
  Available
  Scheduled
  Executing
  Retryable
  Completed
  Cancelled
  Discarded
}

pub type ConflictAction {
  KeepExisting
  RescheduleScheduled
}

pub opaque type SubmissionId {
  SubmissionId(String)
}

pub fn submission_id(
  value: String,
) -> Result(SubmissionId, UniqueConfigurationError) {
  case value {
    "" -> Error(SubmissionIdMustNotBeEmpty)
    _ -> Ok(SubmissionId(value))
  }
}

pub fn submission_id_value(id: SubmissionId) -> String {
  let SubmissionId(value) = id
  value
}

pub opaque type UniqueKeyIdentity {
  UniqueKeyIdentity(String, Int)
}

pub fn unique_key_identity(
  name: String,
  version: Int,
) -> Result(UniqueKeyIdentity, UniqueConfigurationError) {
  case name, version > 0 {
    "", _ -> Error(UniqueKeyPolicyIdMustNotBeEmpty)
    _, False -> Error(UniqueKeyPolicyVersionMustBePositive)
    _, True -> Ok(UniqueKeyIdentity(name, version))
  }
}

pub type UniqueKeyPolicy {
  FullInputKey
  SelectedInputKey(name: String, version: Int)
  NoUniqueKeyMaterial
}

// A stable policy identity distinguishes two typed projections which happen
// to encode the same value. The identity is persisted with the encoded key.
pub opaque type Uniqueness(input) {
  Uniqueness(
    scope: QueueScope,
    period: UniquePeriod,
    states: UniqueStates,
    key_policy: UniqueKeyPolicy,
    encode_key: fn(input, Value) -> Result(Value, EncodeError),
  )
}

pub fn full_input(
  scope: QueueScope,
  period: UniquePeriod,
  states: UniqueStates,
) -> Uniqueness(input) {
  Uniqueness(scope, period, states, FullInputKey, fn(_input, payload) {
    Ok(payload)
  })
}

pub fn selected_input(
  scope: QueueScope,
  period: UniquePeriod,
  states: UniqueStates,
  identity: UniqueKeyIdentity,
  select: fn(input) -> key,
  key_codec: Codec(key),
) -> Uniqueness(input) {
  let UniqueKeyIdentity(name, version) = identity
  Uniqueness(
    scope,
    period,
    states,
    SelectedInputKey(name, version),
    fn(input, _payload) { blueprint.encode(key_codec, select(input)) },
  )
}

pub opaque type UniqueRequest {
  UniqueRequest(
    submission_id: SubmissionId,
    route: QueueRoute,
    worker_id: String,
    worker_version: Int,
    payload: Value,
    key: Value,
    key_policy: UniqueKeyPolicy,
    scope: QueueScope,
    period: UniquePeriod,
    states: UniqueStates,
    availability: Availability,
    conflict_action: ConflictAction,
  )
}

pub fn unique_request_submission_id(request: UniqueRequest) -> SubmissionId {
  request.submission_id
}

pub fn unique_request_route(request: UniqueRequest) -> QueueRoute {
  request.route
}

pub fn unique_request_worker_id(request: UniqueRequest) -> String {
  request.worker_id
}

pub fn unique_request_worker_version(request: UniqueRequest) -> Int {
  request.worker_version
}

pub fn unique_request_payload(request: UniqueRequest) -> Value {
  request.payload
}

pub fn unique_request_key(request: UniqueRequest) -> Value {
  request.key
}

pub fn unique_request_key_policy(request: UniqueRequest) -> UniqueKeyPolicy {
  request.key_policy
}

pub fn unique_request_scope(request: UniqueRequest) -> QueueScope {
  request.scope
}

pub fn unique_request_period(request: UniqueRequest) -> UniquePeriod {
  request.period
}

pub fn unique_request_states(request: UniqueRequest) -> UniqueStates {
  request.states
}

pub fn unique_request_availability(request: UniqueRequest) -> Availability {
  request.availability
}

pub fn unique_request_conflict_action(
  request: UniqueRequest,
) -> ConflictAction {
  request.conflict_action
}

pub type UniqueRecord {
  UniqueRecord(
    id: JobId,
    route: QueueRoute,
    worker_id: String,
    worker_version: Int,
    payload: Value,
    key: Value,
    key_policy: UniqueKeyPolicy,
    availability: Availability,
    state: UniqueJobState,
    inserted_at: Int,
  )
}

pub type UniquePortOutcome {
  PortInserted(UniqueRecord)
  PortExisting(UniqueRecord)
  PortRescheduled(before: UniqueRecord, after: UniqueRecord)
  PortContended
  PortCommitUnknown
  PortRejected(AdmissionError)
}

// evaluated_at is owned by the atomic admission adapter. It models one clock
// sample shared by matching and admission; this lab does not claim DB timing.
pub type UniquePortResponse {
  UniquePortResponse(
    accepted: UniqueRequest,
    evaluated_at: Int,
    outcome: UniquePortOutcome,
  )
}

pub opaque type Conflict {
  Conflict(record: UniqueRecord)
}

pub fn conflict_job_id(conflict: Conflict) -> JobId {
  let Conflict(record) = conflict
  record.id
}

pub fn conflict_route(conflict: Conflict) -> QueueRoute {
  let Conflict(record) = conflict
  record.route
}

pub fn conflict_worker_id(conflict: Conflict) -> String {
  let Conflict(record) = conflict
  record.worker_id
}

pub fn conflict_worker_version(conflict: Conflict) -> Int {
  let Conflict(record) = conflict
  record.worker_version
}

pub fn conflict_state(conflict: Conflict) -> UniqueJobState {
  let Conflict(record) = conflict
  record.state
}

pub type UniqueAdmission(output, error) {
  Inserted(JobHandle(output, error))
  Existing(Conflict)
  Rescheduled(Conflict)
}

pub opaque type UniqueRecovery(output, error) {
  UniqueRecovery(
    request: UniqueRequest,
    output_codec: Codec(output),
    error_codec: Codec(error),
  )
}

pub fn recovery_submission_id(
  recovery: UniqueRecovery(output, error),
) -> SubmissionId {
  recovery.request.submission_id
}

pub fn recovery_route(recovery: UniqueRecovery(output, error)) -> QueueRoute {
  recovery.request.route
}

pub fn recovery_request(
  recovery: UniqueRecovery(output, error),
) -> UniqueRequest {
  recovery.request
}

pub type UniqueSubmitError(output, error) {
  UniqueInputCouldNotEncode(EncodeError)
  UniqueInputContainsDuplicateObjectNames
  UniqueKeyCouldNotEncode(EncodeError)
  UniqueKeyContainsDuplicateObjectNames
  UniqueAdmissionFailed(AdmissionError)
  UniqueAdmissionContended
  RescheduleRequiresAvailabilityTime
  UniqueCommitUnknown(UniqueRecovery(output, error))
  UniqueBackendContractViolated(UniqueRecovery(output, error))
}

pub type UniqueRecoveryError(output, error) {
  RecoveryWrongRoute(UniqueRecovery(output, error))
  RecoveryPortUnavailable(UniqueRecovery(output, error))
  RecoveryAdmissionFailed(AdmissionError, UniqueRecovery(output, error))
  RecoveryContended(UniqueRecovery(output, error))
  RecoveryStillUnknown(UniqueRecovery(output, error))
  RecoveryBackendContractViolated(UniqueRecovery(output, error))
}

pub type ConflictContractError {
  ConflictWorkerIdMismatch
  ConflictWorkerVersionMismatch
}

// The port owns the clock, current rows and stable-command ledger, and must
// make its decision atomically. This pure wrapper validates the returned
// contract before it can construct a typed handle.
pub fn submit_unique(
  queue: Queue,
  command: SubmissionId,
  worker: Worker(input, output, error),
  input: input,
  availability: Availability,
  uniqueness: Uniqueness(input),
  on_conflict: ConflictAction,
) -> Result(UniqueAdmission(output, error), UniqueSubmitError(output, error)) {
  case on_conflict, availability {
    RescheduleScheduled, Immediate -> Error(RescheduleRequiresAvailabilityTime)
    _, _ ->
      case blueprint.encode(worker.input_codec, input) {
        Error(error) -> Error(UniqueInputCouldNotEncode(error))
        Ok(payload) ->
          case valid_profile_value(payload) {
            False -> Error(UniqueInputContainsDuplicateObjectNames)
            True -> {
              let Uniqueness(scope, period, states, key_policy, encode_key) =
                uniqueness
              case encode_key(input, payload) {
                Error(error) -> Error(UniqueKeyCouldNotEncode(error))
                Ok(key) ->
                  case valid_profile_value(key) {
                    False -> Error(UniqueKeyContainsDuplicateObjectNames)
                    True -> {
                      let Queue(route, _, _) = queue
                      let WorkerId(id) = worker.id
                      let WorkerVersion(version) = worker.version
                      let request =
                        UniqueRequest(
                          command,
                          route,
                          id,
                          version,
                          payload,
                          key,
                          key_policy,
                          scope,
                          period,
                          states,
                          availability,
                          on_conflict,
                        )
                      let recovery =
                        UniqueRecovery(
                          request,
                          worker.output_codec,
                          worker.error_codec,
                        )
                      case
                        attempt_unique(
                          queue,
                          request,
                          worker.output_codec,
                          worker.error_codec,
                        )
                      {
                        Ok(admission) -> Ok(admission)
                        Error(UniquePortUnavailable) ->
                          Error(UniqueAdmissionFailed(QueueStorageUnavailable))
                        Error(UniquePortRejected(error)) ->
                          Error(UniqueAdmissionFailed(error))
                        Error(UniquePortContended) ->
                          Error(UniqueAdmissionContended)
                        Error(UniquePortUnknown) ->
                          Error(UniqueCommitUnknown(recovery))
                        Error(UniquePortInvalid) ->
                          Error(UniqueBackendContractViolated(recovery))
                      }
                    }
                  }
              }
            }
          }
      }
  }
}

// Recovery accepts the current adapter for the original owner+queue. It never
// rebuilds the key or command and rejects a route mismatch before invoking it.
pub fn recover_unique(
  queue: Queue,
  recovery: UniqueRecovery(output, error),
) -> Result(UniqueAdmission(output, error), UniqueRecoveryError(output, error)) {
  let Queue(route, _, _) = queue
  case same_queue_route(route, recovery.request.route) {
    False -> Error(RecoveryWrongRoute(recovery))
    True ->
      case
        attempt_unique(
          queue,
          recovery.request,
          recovery.output_codec,
          recovery.error_codec,
        )
      {
        Ok(admission) -> Ok(admission)
        Error(UniquePortUnavailable) -> Error(RecoveryPortUnavailable(recovery))
        Error(UniquePortRejected(error)) ->
          Error(RecoveryAdmissionFailed(error, recovery))
        Error(UniquePortContended) -> Error(RecoveryContended(recovery))
        Error(UniquePortUnknown) -> Error(RecoveryStillUnknown(recovery))
        Error(UniquePortInvalid) ->
          Error(RecoveryBackendContractViolated(recovery))
      }
  }
}

pub fn bind_conflict(
  worker: Worker(input, output, error),
  conflict: Conflict,
) -> Result(JobHandle(output, error), ConflictContractError) {
  let Conflict(record) = conflict
  let WorkerId(worker_id) = worker.id
  let WorkerVersion(worker_version) = worker.version
  case worker_id == record.worker_id, worker_version == record.worker_version {
    False, _ -> Error(ConflictWorkerIdMismatch)
    _, False -> Error(ConflictWorkerVersionMismatch)
    True, True ->
      Ok(JobHandle(
        record.id,
        record.route,
        worker.output_codec,
        worker.error_codec,
      ))
  }
}

type UniquePortFailure {
  UniquePortUnavailable
  UniquePortRejected(AdmissionError)
  UniquePortContended
  UniquePortUnknown
  UniquePortInvalid
}

fn attempt_unique(
  queue: Queue,
  request: UniqueRequest,
  output_codec: Codec(output),
  error_codec: Codec(error),
) -> Result(UniqueAdmission(output, error), UniquePortFailure) {
  let Queue(route, _, unique_port) = queue
  case unique_port {
    NoUniquePort -> Error(UniquePortUnavailable)
    HasUniquePort(port) -> {
      let response = port(request)
      case response {
        UniquePortResponse(accepted, evaluated_at, outcome) ->
          case accepted == request && evaluated_at >= 0 {
            False -> Error(UniquePortInvalid)
            True ->
              case outcome {
                PortInserted(record) ->
                  case valid_inserted_record(route, request, record) {
                    False -> Error(UniquePortInvalid)
                    True ->
                      Ok(
                        Inserted(JobHandle(
                          record.id,
                          record.route,
                          output_codec,
                          error_codec,
                        )),
                      )
                  }
                PortExisting(record) ->
                  case valid_existing_record(request, record, evaluated_at) {
                    False -> Error(UniquePortInvalid)
                    True ->
                      case request.conflict_action, record.state {
                        RescheduleScheduled, Scheduled ->
                          Error(UniquePortInvalid)
                        _, _ -> Ok(Existing(Conflict(record)))
                      }
                  }
                PortRescheduled(before, after) ->
                  case
                    valid_rescheduled_records(
                      request,
                      before,
                      after,
                      evaluated_at,
                    )
                  {
                    False -> Error(UniquePortInvalid)
                    True -> Ok(Rescheduled(Conflict(after)))
                  }
                PortContended -> Error(UniquePortContended)
                PortCommitUnknown -> Error(UniquePortUnknown)
                PortRejected(error) -> Error(UniquePortRejected(error))
              }
          }
      }
    }
  }
}

fn valid_inserted_record(
  route: QueueRoute,
  request: UniqueRequest,
  record: UniqueRecord,
) -> Bool {
  let expected_state = case request.availability {
    Immediate -> Available
    At(_) -> Scheduled
  }
  record.id != JobId("")
  && same_queue_route(route, record.route)
  && same_queue_route(request.route, record.route)
  && record.worker_id == request.worker_id
  && record.worker_version == request.worker_version
  && record.key_policy == request.key_policy
  && valid_profile_value(record.key)
  && valid_profile_value(record.payload)
  && unique_values_equal(record.key, request.key)
  && unique_values_equal(record.payload, request.payload)
  && record.availability == request.availability
  && record.state == expected_state
  && record.inserted_at >= 0
}

fn valid_existing_record(
  request: UniqueRequest,
  record: UniqueRecord,
  evaluated_at: Int,
) -> Bool {
  record.id != JobId("")
  && conflict_identity_matches(request, record)
  && valid_profile_value(record.key)
  && valid_profile_value(record.payload)
  && unique_state_selected(request.states, record.state)
  && unique_period_matches(request.period, record, evaluated_at)
}

fn conflict_identity_matches(
  request: UniqueRequest,
  record: UniqueRecord,
) -> Bool {
  let same_owner =
    queue_owner_value(request.route) == queue_owner_value(record.route)
  let same_scope = case request.scope {
    WithinQueue -> same_queue_route(request.route, record.route)
    AcrossQueues -> same_owner
  }
  same_owner
  && same_scope
  && record.worker_id == request.worker_id
  && record.worker_version == request.worker_version
  && valid_profile_value(record.key)
  && valid_profile_value(record.payload)
  && record_key_matches(request, record)
}

fn record_key_matches(request: UniqueRequest, record: UniqueRecord) -> Bool {
  case request.key_policy, record.key_policy {
    FullInputKey, FullInputKey ->
      unique_values_equal(record.payload, record.key)
      && unique_values_equal(record.payload, request.key)
    FullInputKey, NoUniqueKeyMaterial ->
      unique_values_equal(record.payload, request.key)
    SelectedInputKey(request_name, request_version),
      SelectedInputKey(record_name, record_version)
    ->
      request_name == record_name
      && request_version == record_version
      && unique_values_equal(record.key, request.key)
    _, _ -> False
  }
}

fn unique_state_selected(states: UniqueStates, state: UniqueJobState) -> Bool {
  case states, state {
    AllRetained, _ -> True
    Incomplete, Suspended -> True
    Incomplete, Available -> True
    Incomplete, Scheduled -> True
    Incomplete, Executing -> True
    Incomplete, Retryable -> True
    NotCancelledOrDiscarded, Cancelled -> False
    NotCancelledOrDiscarded, Discarded -> False
    NotCancelledOrDiscarded, _ -> True
    ScheduledOnly, Scheduled -> True
    _, _ -> False
  }
}

fn unique_period_matches(
  period: UniquePeriod,
  record: UniqueRecord,
  evaluated_at: Int,
) -> Bool {
  case period {
    WhileRetained -> True
    For(PositiveDuration(milliseconds), origin) -> {
      let timestamp = case origin {
        FromInsertion -> record.inserted_at
        FromSchedule ->
          case record.availability {
            Immediate -> record.inserted_at
            At(available) -> available_at_milliseconds(available)
          }
      }
      timestamp >= evaluated_at - milliseconds
    }
  }
}

fn valid_rescheduled_records(
  request: UniqueRequest,
  before: UniqueRecord,
  after: UniqueRecord,
  evaluated_at: Int,
) -> Bool {
  case request.conflict_action, request.availability {
    RescheduleScheduled, At(requested_availability) ->
      valid_existing_record(request, before, evaluated_at)
      && before.state == Scheduled
      && after.id == before.id
      && same_queue_route(after.route, before.route)
      && after.worker_id == before.worker_id
      && after.worker_version == before.worker_version
      && unique_values_equal(after.key, before.key)
      && after.key_policy == before.key_policy
      && unique_values_equal(after.payload, before.payload)
      && after.state == Scheduled
      && after.inserted_at == before.inserted_at
      && after.availability == At(requested_availability)
    _, _ -> False
  }
}

fn valid_profile_value(value: Value) -> Bool {
  case value {
    value.Null -> True
    value.Bool(_) -> True
    value.Int(_) -> True
    value.Text(_) -> True
    value.Array(values) -> all_valid_values(values)
    value.Object(fields) -> valid_unique_fields(fields)
  }
}

fn all_valid_values(values: List(Value)) -> Bool {
  case values {
    [] -> True
    [value, ..rest] -> valid_profile_value(value) && all_valid_values(rest)
  }
}

fn valid_unique_fields(fields: List(#(String, Value))) -> Bool {
  case fields {
    [] -> True
    [#(name, value), ..rest] ->
      !has_field(name, rest)
      && valid_profile_value(value)
      && valid_unique_fields(rest)
  }
}

fn has_field(name: String, fields: List(#(String, Value))) -> Bool {
  case fields {
    [] -> False
    [#(field_name, _), ..rest] -> field_name == name || has_field(name, rest)
  }
}

// JSON-profile equality: object order is ignored, duplicate names are invalid,
// arrays remain ordered and scalar constructors remain exact.
fn unique_values_equal(left: Value, right: Value) -> Bool {
  case left, right {
    value.Null, value.Null -> True
    value.Bool(a), value.Bool(b) -> a == b
    value.Int(a), value.Int(b) -> a == b
    value.Text(a), value.Text(b) -> a == b
    value.Array(a), value.Array(b) -> values_equal(a, b)
    value.Object(a), value.Object(b) -> fields_equal(a, b)
    _, _ -> False
  }
}

fn values_equal(left: List(Value), right: List(Value)) -> Bool {
  case left, right {
    [], [] -> True
    [left, ..left_rest], [right, ..right_rest] ->
      unique_values_equal(left, right) && values_equal(left_rest, right_rest)
    _, _ -> False
  }
}

fn fields_equal(
  left: List(#(String, Value)),
  right: List(#(String, Value)),
) -> Bool {
  case left, right {
    [], [] -> True
    [#(name, field), ..rest], right ->
      case field_value(name, right) {
        Error(Nil) -> False
        Ok(other) ->
          unique_values_equal(field, other)
          && fields_equal(rest, remove_field(name, right))
      }
    _, _ -> False
  }
}

fn field_value(
  name: String,
  fields: List(#(String, Value)),
) -> Result(Value, Nil) {
  case fields {
    [] -> Error(Nil)
    [#(field_name, value), ..rest] ->
      case field_name == name {
        True -> Ok(value)
        False -> field_value(name, rest)
      }
  }
}

fn remove_field(
  name: String,
  fields: List(#(String, Value)),
) -> List(#(String, Value)) {
  case fields {
    [] -> []
    [#(field_name, value), ..rest] ->
      case field_name == name {
        True -> rest
        False -> [#(field_name, value), ..remove_field(name, rest)]
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
  QueueRouteMismatch
}

// A concrete queue adapter must load the latest state and atomically persist
// the pure transition above; this prototype does neither operation.
pub fn cancel(
  queue: Queue,
  handle: JobHandle(o, e),
) -> Result(CancellationTransition(o, e), CancelError) {
  let Queue(route, _, _) = queue
  case same_queue_route(route, handle.route) {
    False -> Error(QueueRouteMismatch)
    True ->
      todo as "load and persist the cancellation transition through queue storage"
  }
}

pub type PollError {
  JobNotFound
  JobStateCouldNotBeDecoded(String)
  PollQueueRouteMismatch
}

pub fn job_id_of(handle: JobHandle(o, e)) -> JobId {
  handle.id
}

pub fn job_route_of(handle: JobHandle(o, e)) -> QueueRoute {
  handle.route
}

pub fn poll(
  queue: Queue,
  handle: JobHandle(o, e),
) -> Result(JobState(o, e), PollError) {
  let Queue(route, _, _) = queue
  case same_queue_route(route, handle.route) {
    False -> Error(PollQueueRouteMismatch)
    True -> todo as "read a committed job state and decode its typed outcome"
  }
}
