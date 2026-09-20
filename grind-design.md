# `grind` — typed durable jobs for Gleam

- Grind targets the complete Oban and Oban Pro capability set in one library.
  This is a product requirement, not an achieved parity claim.
- Grind owns durable job delivery. Saga owns typed workflow state and compensation;
  the optional Saga/Grind integration coordinates their separate stores and runners.
- Values remain typed in process. Persisted arguments, results, and errors use
  versioned codecs at the storage boundary.
- The intended runtime uses `gleam_otp` actors and supervisors with PostgreSQL
  through `pog`. The original optional SQLite engine remains a retained requirement
  pending a consumer decision and backend-specific behavioral tests.
- [PUBLIC-API.md](PUBLIC-API.md) freezes an initial delivery subset: typed workers,
  queue routes and configuration, immediate and scheduled admission, opaque job
  handles, uniqueness policy, and implemented pure job/claim transitions.
  It does not remove any full-scope requirement below.
- Storage engines, claim ledgers, processor protocols, callback receipts, and
  unfinished operations remain internal evidence until a runtime validates them.
  Code sketches below express retained capabilities; they are not compiled package
  APIs or evidence that those capabilities work.

---

## 1. Module layout

```
grind
├── grind.gleam            -- Oban{} supervisor/config, start/stop, insert/insert_all
├── grind/job.gleam         -- Job(args), JobId, JobState, Priority, AttemptError
├── grind/worker.gleam      -- Worker(args), Changeset(args), PerformError
├── grind/backoff.gleam     -- Backoff strategies
├── grind/unique.gleam      -- Uniqueness(args)
├── grind/schedule.gleam    -- Schedule, cron AST, parse_cron
├── grind/queue.gleam       -- QueueConfig, GlobalLimit, RateLimit, Partition
├── grind/engine.gleam      -- Engine record (storage backend interface)
├── grind/engine/postgres.gleam
├── grind/engine/sqlite.gleam
├── grind/plugin.gleam      -- Pruner, Lifeline, Cron, DynamicCron, Reindexer, Stager
├── grind/event.gleam       -- historical event-family sketch; current observations use Sinal
├── grind/testing.gleam     -- Mode: Enqueued | Inline | Manual
├── grind/workflow.gleam    -- retained raw dependency-only job workflows
├── grind/batch.gleam       -- batches with completion callbacks
├── grind/chunk.gleam       -- chunked/batched worker execution
├── grind/relay.gleam       -- synchronous request/response over the queue
└── grind/recorder.gleam    -- typed capture of a job's return value
```

---

## 2. Core types

- The original persisted-job sketch below retains states, priorities, timestamps,
  attempt history, and typed arguments as full-scope requirements. The initial
  caller-facing handle is opaque; this record is not its replacement.
- Suspended state appears in later admission and uniqueness contracts but is absent
  from this original enum. The production state vocabulary and history projection
  remain unresolved; implementations must not silently drop suspended jobs.

```gleam
// grind/job.gleam
pub opaque type JobId { JobId(Int) }

pub type JobState {
  Available
  Scheduled
  Executing
  Retryable
  Completed
  Discarded
  Cancelled
}

pub type Priority { Highest  Higher  Normal  Lower  Lowest }

pub type AttemptError {
  AttemptError(attempt: Int, at: timestamp.Timestamp, error: String)
}

pub type Job(args) {
  Job(
    id: JobId,
    args: args,
    queue: String,
    state: JobState,
    attempt: Int,
    max_attempts: Int,
    priority: Priority,
    tags: List(String),
    scheduled_at: timestamp.Timestamp,
    inserted_at: timestamp.Timestamp,
    attempted_at: Option(timestamp.Timestamp),
    errors: List(AttemptError),
  )
}
```

`args` is a real type parameter, not `Dynamic` — a `Job(EmailArgs)` and a
`Job(ResizeArgs)` are different types, and a worker can only ever receive its own.

---

## 3. Worker

- The canonical worker is `Worker(input, output, error)`. It retains a validated
  worker identity, worker version, input/output/error codecs, and an ordinary
  `fn(input) -> Result(output, error)` handler.
- Ordinary invocation remains useful without a queue. Scheduling responses adapt
  the handler result; business functions need not depend on the scheduler.
- Blueprint supplies serialization contracts. Encoded dispatch distinguishes input
  decoding, business failure, output encoding failure, and error encoding failure.
  Runtime failure never fabricates a value of the worker's business error type.

### Typed admission and handles

- Immediate and scheduled admission use one representation containing the full queue
  route, worker identity and version, encoded input, and explicit availability.
  Preparation encodes before storage is called; submission never executes the worker.
- `AvailableAt` is an absolute Unix-millisecond value. Relative scheduling requires
  an explicit clock conversion; it does not introduce a second changeset model.
- An opaque `JobHandle(output, error)` retains job identity and the worker's result
  codecs. The intended public facade provides typed status, result, and cancellation
  outcomes; prototype `poll` and `cancel` bodies do not establish runtime behavior.
- Original changeset capabilities remain required (priority, tags, maximum attempts,
  queue override, single insertion, and bulk insertion). Their integration into this
  admission representation remains backlog.
- Inactive scheduled, queued, or suspended jobs can transition to terminal
  cancellation. Running cancellation records cooperative intent; already-cancelled
  and already-finished outcomes remain distinct and preserve finished results.

### Queue-bound heterogeneous registration

- Registration binds a canonical worker to a full queue route, worker identity, and
  worker version. Duplicate tuples reject; multiple deployed versions may coexist.
- Selection requires the exact tuple and never falls back to another version.
  Queue owners distinguish identically named queues.
- An opaque erased selection closes over the original typed worker. Selection
  neither decodes input nor invokes the handler; explicit invocation performs both.
- Read-only descriptors expose route and version identities without executable
  closures. An erased selection cannot be recast as a caller-chosen native worker.
- Handler metadata, live configuration replacement, deployed-code retention, codec
  migrations, process isolation, and handler-visible cancellation remain required
  runtime or interface work.
- Evidence: [worker registration](playground/interface_lab/WORKER-REGISTRY.md) and
  [scheduled jobs](playground/interface_lab/SCHEDULED-JOBS.md) exercise typed and
  erased invocation, exact submission records, and pure cancellation transitions.
  They establish no durable queue or concurrent registry behavior.

---

## 4. Backoff

- Backoff remains configurable. The following original policy sketch does not
  establish Oban's timing distribution; deterministic policy probes use an injected
  clock, while timers, jitter, and retry latency require the pinned oracle.

```gleam
// grind/backoff.gleam
pub type Backoff {
  Exponential(base_seconds: Int, cap_seconds: Int)
  Linear(step_seconds: Int)
  Constant(seconds: Int)
  Custom(fn(attempt: Int) -> Int)
}

pub fn default() -> Backoff { Exponential(base_seconds: 15, cap_seconds: 86_400) }

pub fn delay_for(b: Backoff, attempt: Int) -> Int {
  case b {
    Exponential(base, cap) -> int.min(base * pow2(attempt), cap)
    Linear(step) -> step * attempt
    Constant(s) -> s
    Custom(f) -> f(attempt)
  }
}
```

---

## 5. Uniqueness

- Uniqueness governs admission, not concurrent execution or exactly-once effects.
  The conservative typed profile includes worker identity and version in every
  uniqueness domain; cross-worker uniqueness remains retained backlog.
- Queue scope is explicit: `WithinQueue` or `AcrossQueues`. Across-queue matching
  stays within one storage owner; a conflict retains its actual route.
- Full-input uniqueness reuses encoded admission input. Projected uniqueness uses
  a typed selector and codec with explicit key-policy identity and version.
  Stored candidates need matching retained key material or an explicit backfill.
- Typed equality compares JSON-shaped values recursively: object order is irrelevant,
  duplicate fields reject recursively, array order and multiplicity matter, and
  scalar constructors stay distinct. This deliberately differs from Oban Basic's
  selected-field PostgreSQL containment behavior.
- Period origin is explicit (`FromInsertion` or `FromSchedule`). Finite periods are
  positive and include the exact cutoff; `WhileRetained` has no timestamp cutoff.
- The first state profile exposes `Incomplete`, `ScheduledOnly`,
  `NotCancelledOrDiscarded`, and `AllRetained`. The original four-state default
  (available, scheduled, executing, retryable) is not Oban 2.24.1's default, which
  also includes suspended and completed jobs; no implicit legacy default is retained.
- Arbitrary state lists and the reconciliation of the original §2 state vocabulary
  with suspended jobs remain unresolved requirements. The first named groups do
  not delete the broader original state-policy capability.
- Conflict actions are `KeepExisting` and `RescheduleScheduled`. Rescheduling changes
  only an eligible scheduled job's requested availability, retaining job and worker
  identity; other states return an unchanged existing conflict.
- An existing conflict is not a typed handle. Binding checks persisted worker
  identity and version before attaching the submitting worker's result codecs.
- Outcomes distinguish insertion, existing conflict, rescheduled conflict, known
  lock contention, encoding failure, storage failure, and uncertain commit.
  A lock miss does not establish that an existing job exists.
- A stable submission identity names the exact prepared command independently of
  the uniqueness key. Reconciliation retains the original route, command, decision
  time, and receipt even after a matching period or stored state changes.
- Storage owns current rows, authoritative time, command lookup, matching, insertion
  or replacement, and commit atomically. Unknown commits and invalid success replies
  preserve reconciliation evidence and never authorize blind resubmission.
- General field replacement, bulk uniqueness, cross-worker policies, arbitrary state
  lists, and backend-specific optimization remain retained backlog. Basic bulk
  insertion does not apply each changeset's uniqueness policy, so bulk behavior
  requires an explicit Grind contract rather than an assumed parity claim.
- Evidence: [typed uniqueness](playground/interface_lab/UNIQUE-JOBS.md) supplies pure
  consumer and compiler-negative evidence; the [pinned Oban study](research/grind-uniqueness-contract.md)
  supplies source findings and the still-required PostgreSQL concurrency oracle.

---

## 6. Scheduling & Cron

```gleam
// grind/schedule.gleam
pub type Field { Any  At(List(Int))  Step(Int) }

pub type Schedule {
  Every(duration.Duration)
  Cron(minute: Field, hour: Field, day: Field, month: Field, weekday: Field)
}

pub fn parse_cron(input: String) -> Result(Schedule, CronParseError)
pub fn cron_matches(s: Schedule, at: calendar.TimeOfDay, date: calendar.Date) -> Bool
```

Cron strings are parsed once, at plugin-config time, into `Schedule` — the
scheduler loop never re-parses text, unlike matching against a raw cron
string every tick.

- One-time scheduling evidence does not establish recurrence. Cron and interval
  schedules must define timezone, missed-run, clock-jump, duplicate-tick, and leader
  election behavior; dynamic sources must report registration and parse errors.
- Pruner, Lifeline, Stager, and Reindexer remain separate retained plugin contracts.
  Their crash, rescue, retention, and scheduling behavior needs runtime tests.

### Cron plugin

```gleam
// grind/plugin.gleam
pub type CronEntry {
  CronEntry(schedule: schedule.Schedule, build: fn() -> RawChangeset)
}

pub type Plugin {
  Cron(entries: List(CronEntry))
  DynamicCron(refresh: duration.Duration, source: fn(Db) -> List(CronEntry))  -- Pro
  Pruner(max_age: duration.Duration, keep_discarded: Bool)
  Lifeline(rescue_after: duration.Duration)   -- rescues orphaned Executing jobs
  Stager(interval: duration.Duration)          -- moves Scheduled -> Available
  Reindexer(schedule: schedule.Schedule)
}
```

`DynamicCron` (Oban Pro) reads entries from the database at runtime instead
of app config — here `source` is still a typed function returning
`CronEntry`, it just gets re-invoked on a timer; the DB row itself is
`(worker_name: String, args_json: Json, schedule_text: String)`, decoded via
the same `Registered` machinery as regular jobs.

---

## 7. Queues, concurrency, and smart limits

- A queue route contains a validated storage owner and queue name. Configuration
  rejects duplicate full routes while allowing equal names under different owners.
- Local concurrency is positive; supplied active counts are nonnegative. A paused
  or saturated processor proposes zero claims; otherwise capacity is the configured
  limit minus active work, clamped at zero.
- A dispatch plan advises demand without reserving capacity or issuing a claim.
  Scaling below active work lets it drain; resuming does not create capacity early.
- [Queue configuration](playground/interface_lab/QUEUE-CONFIGURATION.md) demonstrates
  immutable planning only. Processor handles, management outcomes, persisted revisions,
  atomic capacity reservation, fairness, and live reconfiguration remain required.
- Global limits, rate limits, and partitions remain advanced scope. Typed partition
  extraction and cluster-wide failure recovery need an original black-box contract
  or licensed Pro oracle; the sketches below are not runtime evidence.

```gleam
// grind/queue.gleam
pub type Partition {
  PartitionByArgs(keys: List(String))
  PartitionByWorker
  PartitionByArgsAndWorker(keys: List(String))
}

pub type RateLimit {
  RateLimit(allowed: Int, period: duration.Duration, partition: Option(Partition))
}

pub type GlobalLimit {
  GlobalLimit(allowed: Int, partition: Option(Partition))
}

pub type QueueConfig {
  QueueConfig(
    name: String,
    local_limit: Int,
    global_limit: Option(GlobalLimit),   -- Pro: cap across the whole cluster
    rate_limit: Option(RateLimit),        -- Pro: sliding-window throttle
    paused: Bool,
  )
}

pub fn queue(name: String, local_limit n: Int) -> QueueConfig {
  QueueConfig(name:, local_limit: n, global_limit: None, rate_limit: None, paused: False)
}
pub fn with_global_limit(q: QueueConfig, g: GlobalLimit) -> QueueConfig { ... }
pub fn with_rate_limit(q: QueueConfig, r: RateLimit) -> QueueConfig { ... }
```

Global limits and rate limits need cluster-wide coordination, which Oban Pro
does via the database (a `producers`/counters table). Same here — the
`Engine` (§9) exposes `try_claim(db, queue_name, partition_key) -> Result(Nil, Throttled)`,
called by each node's queue producer actor before pulling more jobs. The
_type_ of a rate limit is fully static; only the counter row is mutable
shared state, same as Oban.

Pausing/resuming a queue at runtime:

```gleam
pub fn pause(oban: Oban, queue_name: String) -> Result(Nil, Nil)
pub fn resume(oban: Oban, queue_name: String) -> Result(Nil, Nil)
pub fn scale(oban: Oban, queue_name: String, local_limit: Int) -> Result(Nil, Nil)
```

---

## 8. Runtime shape (queue producer/consumer actors)

### Attempt outcomes and ownership

- A worker response preserves typed success, business failure, snooze, discard,
  worker cancellation, or effect uncertainty. An attempt report separately records
  a returned response, observed runtime failure, or unknown outcome.
- The pure resolver uses validated attempt accounting, retry policy, and an explicit
  clock to propose a disposition. Only a successful store transition acknowledges
  it; retry, snooze, and reconciliation do not imply a finished job.
- Failure retries only below the total attempt limit and with policy permission.
  Snooze refunds the current claim and increments a separate snooze count, so a
  later execution may reuse the attempt number.
- Claims therefore carry distinct attempt identity and ownership epoch. Renewal
  preserves ownership while updating a record revision; takeover changes ownership.
  A same-owner acknowledgement remains valid after renewal.
- Storage must atomically read current ownership, executing state, cancellation,
  and expiry, decide, and commit. Exact expiry rejects acknowledgement; an outdated
  claim expiry or revision cannot replace the current record check.
- Cancellation intent, committed cancellation, and worker cancellation are distinct.
  The pure acknowledgement contract checks expiry first and lets matching live-owner
  acknowledgement commit requested cancellation instead of the proposed outcome.
- Rejection preserves the exact proposed result, including successful output and
  uncertainty evidence. Cancellation does not undo an external effect or convert
  unacknowledged success into a committed job result.
- Results distinguish rejected ownership, expired lease, cancellation victory,
  already-acknowledged state, missing record, unavailable storage, and unknown commit.
  Acknowledged state alone does not identify which command committed; durable command
  receipts are required for replay recognition.
- Unknown effect or acknowledgement outcomes require reconciliation rather than
  automatic execution. Retry permission does not prove idempotency; downstream
  deduplication, fencing, or a shared transaction must protect the actual effect.
- Evidence: [worker outcomes](playground/interface_lab/WORKER-OUTCOMES.md) and
  [claim ownership](playground/interface_lab/CLAIM-OWNERSHIP.md) establish pure scripted
  transitions. Persisted history, job-state projection, capacity release, cancellation
  observation, renewal races, process loss, and shutdown remain runtime obligations.

### Supervised processors

Each configured queue gets a supervised actor tree, mirroring Oban's
`Producer` + per-job `Executor` tasks:

```gleam
pub type ProducerMsg {
  Poll
  Notified(RawJob)
  JobFinished(JobId, Outcome)
  Pause
  Resume
  Scale(Int)
}

fn producer_loop(state: ProducerState, msg: ProducerMsg) -> actor.Next(ProducerState, ProducerMsg) {
  case msg {
    Poll -> {
      let available = engine.fetch_available(state.engine, state.queue.name, slots_free(state))
      list.each(available, fn(raw) { process.spawn(fn() { run_job(state, raw) }) })
      actor.continue(state)
    }
    JobFinished(id, outcome) -> actor.continue(release_slot(state, id, outcome))
    ...
  }
}
```

`pog`'s `LISTEN/NOTIFY` wakes idle producers immediately on insert (matching
Oban's `Oban.Notifiers.Postgres` / `Notifiers.PG` choice); the `Stager`
plugin polls on an interval as the fallback for missed notifications and for
promoting `Scheduled` → `Available`, as a required fallback whose behavior still needs differential tests.

Graceful shutdown: on supervisor `shutting_down`, the top-level `Oban`
process sends `Pause` to every producer, waits (bounded by a configurable
grace period) for in-flight `Executing` jobs to finish via `JobFinished`,
then lets the supervisor proceed — jobs still running past the grace period
are left `Executing` for the `Lifeline` plugin to rescue on the next boot.

---

## 9. Storage engine abstraction

- The injected admission callback in the laboratory is a fake boundary, not a
  durable engine. The original engine sketch below must grow transactional admission,
  current-record acknowledgement, command receipts, reconciliation, schema versions,
  and migrations before serving as a production storage contract.
- PostgreSQL tests must establish locking, isolation, competing claims, unknown-commit
  recovery, notification loss with polling fallback, and codec-version rejection.
  SQLite remains optional retained scope, with backend-specific semantics unresolved.

Oban supports Postgres and SQLite3 engines; model that as a record of
functions rather than a behaviour:

```gleam
// grind/engine.gleam
pub type Engine {
  Engine(
    insert: fn(Db, RawChangeset) -> Result(RawJob, InsertError),
    insert_all: fn(Db, List(RawChangeset)) -> Result(List(RawJob), InsertError),
    fetch_available: fn(Db, queue_name: String, demand: Int) -> Result(List(RawJob), EngineError),
    complete: fn(Db, JobId) -> Result(Nil, EngineError),
    error: fn(Db, JobId, PerformError, next_state: job.JobState) -> Result(Nil, EngineError),
    cancel: fn(Db, JobId) -> Result(Nil, EngineError),
    prune: fn(Db, max_age: duration.Duration) -> Result(Int, EngineError),
    try_claim_global: fn(Db, String, Option(String), GlobalLimit) -> Result(Nil, Throttled),
    try_claim_rate: fn(Db, String, Option(String), RateLimit) -> Result(Nil, Throttled),
  )
}

pub fn postgres(pool: process.Name(pog.Message)) -> Engine
pub fn sqlite(conn: sqlight.Connection) -> Engine
```

`RawChangeset`/`RawJob` here are the one place args are `json.Json` text —
the `Engine` never sees your typed `args`, only the already-encoded payload,
so this module has zero knowledge of any worker's types.

---

## 10. Workflows

### Raw job workflows and typed Saga workflows

- The original dependency-only job workflow remains required: named steps, dependency
  policies, recorded intermediate results, completion state, and persistence across
  retries and cancellation. A raw job DAG need not return a typed final value or
  adopt Saga compensation.
- Saga owns typed workflow authoring, dependency semantics, business retry policy,
  and compensation. Its optional `saga_grind` runner owns the durable workflow journal,
  readiness, operation results, branch decisions, revisions, and compensation progress;
  Grind owns delivery, claims, leases, and attempt recovery.
- The original raw dependency policies below remain a compatibility obligation.
  Their placement beside Saga-owned workflow state needs an explicit integration
  contract; removing them would lose promised scope.
- A whole local Saga inside one Grind job restarts as a whole after delivery loss.
  Its intermediate values and undo state are not durable; terminal workflow business
  and undo failures map to terminal non-retryable job results by default.
- A durable Saga definition instead journals individual operations and compensation.
  Admission and journal updates require a shared transaction or outbox protocol;
  putting a continuation reference into a job does not supply that protocol.
- Delivery recovery and retry after observed business failure have separate counters
  and ambiguity rules. One declared layer owns automatic retry for each effect;
  Saga, Grind, and provider retries must not multiply it implicitly.
- Preserve typed upstream-result decoding from the original workflow requirement.
  The rank-polymorphic `WorkflowContext` sketch below is unvalidated; final bindings
  must retain the actual result codec rather than accept a fabricated native type.
- Evidence: [composition contracts](research/composition-contracts.md) preserves both
  workflow modes, and [API coverage](API-COVERAGE.md#grind) leaves raw workflows open.
  Durable journals, dependency admission, compensation recovery, and partial completion
  require integration and fault tests.

### Retained dependency-only capability sketch

A DAG of named steps, each depending on others by name, with configurable
behavior when an upstream step fails:

```gleam
// grind/workflow.gleam
pub type DepsPolicy { WaitForCompletion  IgnoreDiscarded  IgnoreCancelled }

pub opaque type Workflow {
  Workflow(id: WorkflowId, steps: List(Step))
}
type Step {
  Step(name: String, changeset: RawChangeset, deps: List(String), policy: DepsPolicy)
}

pub fn new() -> Workflow { Workflow(id: new_workflow_id(), steps: []) }

pub fn add(
  wf: Workflow,
  name name: String,
  worker worker: worker.Worker(args),
  args args: args,
  deps deps: List(String),
) -> Workflow {
  let raw = to_raw_changeset(worker, args)
  Workflow(..wf, steps: [Step(name, raw, deps, WaitForCompletion), ..wf.steps])
}

pub fn insert(oban: Oban, wf: Workflow) -> Result(Nil, InsertError)
```

The engine only marks a step `Available` once all its `deps` are in a
satisfying state — a `workflow_deps` join table, as an unvalidated storage proposal.

### Reading an upstream step's result, typed

Different deps can produce different result types, so the workflow context
takes a decoder per lookup instead of returning `Dynamic`:

```gleam
pub type WorkflowContext {
  WorkflowContext(fetch: fn(step_name: String, decode.Decoder(a)) -> Result(a, WorkflowError))
}

// worker perform signature for a workflow step:
perform: fn(job.Job(args), WorkflowContext) -> Result(Nil, worker.PerformError)
```

`fetch("resize_image", image_decoder)` looks up the named step's recorded
output (§13) and decodes it against _your_ decoder — if you ask for the
wrong shape you get a typed `WorkflowError`, never a silent `Dynamic`.

---

## 11. Batches

A batch inserts many jobs together and runs typed callback jobs when the
batch reaches terminal states:

```gleam
// grind/batch.gleam
pub opaque type Batch {
  Batch(id: BatchId, jobs: List(RawChangeset), callbacks: Callbacks)
}

pub type Callbacks {
  Callbacks(
    on_complete: Option(RawChangeset),
    on_attempted: Option(RawChangeset),
    on_discarded: Option(RawChangeset),
    on_cancelled: Option(RawChangeset),
  )
}

pub fn new() -> Batch { Batch(new_batch_id(), [], Callbacks(None, None, None, None)) }
pub fn add(b: Batch, worker: worker.Worker(a), args: a) -> Batch
pub fn on_complete(b: Batch, worker: worker.Worker(a), args: a) -> Batch
pub fn on_discarded(b: Batch, worker: worker.Worker(a), args: a) -> Batch

pub fn insert(oban: Oban, b: Batch) -> Result(Nil, InsertError)
```

- Batch callback triggers remain required for complete, attempted, discarded, and
  cancelled aggregation. Heterogeneous entries, typed handles, cancellation, deduplicated
  callback admission, and restart recovery remain unimplemented contracts.
- Exactly-once callback admission requires atomic completion accounting and a durable
  deduplication record; it does not promise exactly-once callback effects.

Implementation: every job in a batch carries a `batch_id`; a lightweight
trigger/poll (mirroring Oban Pro's `BatchManager`) checks batch completion
counts and enqueues the matching callback changeset exactly once.

---

## 12. Chunking

A worker that processes many jobs' args together as one call, flushed by
count or timeout — Gleam models this as an alternate `perform` shape on the
worker rather than a special job type:

```gleam
// grind/chunk.gleam
pub type ChunkConfig(args) {
  ChunkConfig(
    size: Int,
    timeout: duration.Duration,
    perform: fn(List(job.Job(args))) -> List(#(job.JobId, Result(Nil, worker.PerformError))),
  )
}

pub fn chunked(
  name: String,
  queue: String,
  encode: fn(args) -> json.Json,
  decode: decode.Decoder(args),
  chunk: ChunkConfig(args),
) -> worker.Worker(args)
```

- Chunking remains required with count and timeout flushing and per-job results.
  Tests must define missing or duplicate result IDs, partial failure, cancellation,
  timeout, and recovery without replaying completed effects implicitly.

The queue producer accumulates decoded, same-worker `Job(args)` up to
`size` or `timeout`, calls `chunk.perform` once, then reports each job's
individual `Result` back to the engine — so partial failures inside a chunk
still retry only the failed jobs, as a required behavior whose oracle remains outstanding.

---

## 13. Recorder

Captures a job's return value for later inspection (by workflows, batches,
or relay) — this needs its own encode/decode pair since a job's _result_
type is independent of its _args_ type:

```gleam
// grind/recorder.gleam
pub type Recorder(args, result) {
  Recorder(
    encode_result: fn(result) -> json.Json,
    decode_result: decode.Decoder(result),
    perform: fn(job.Job(args)) -> Result(result, worker.PerformError),
  )
}

pub fn recorded(
  worker_base: worker.PartialWorker(args),
  recorder: Recorder(args, result),
) -> worker.Worker(args)
```

- Recording remains required independently of input type. Durable writes must retain
  result codec identity and version; typed handles alone do not implement recording.

Recorded output is stored as `jsonb` on the job row (matching Oban Pro's
`recorded` column); `fetch` in `WorkflowContext` and `relay` (§14) both read
through it with a caller-supplied decoder.

---

## 14. Relay

Synchronous request/response over the job queue — insert a job, block the
calling process until it completes, get a typed result back:

```gleam
// grind/relay.gleam
pub type RelayError {
  RelayTimeout
  RelayJobFailed(reason: String)
  RelayUndecodable
}

pub fn relay(
  oban: Oban,
  worker: worker.Worker(args),
  args: args,
  decode_result: decode.Decoder(result),
  timeout_ms timeout_ms: Int,
) -> Result(result, RelayError)
```

- The bounded waiting contract must distinguish timeout, job failure, cancellation,
  missing recorded result, and decoding failure. A timeout does not cancel delivery
  or prove that an effect failed; missed wakeups, late completion, caller death, and
  connection cleanup require tests.

Implementation: inserts the job, subscribes to a `pog` `LISTEN` channel
named after the job id, and does a `process.receive` with `timeout_ms`. On
`NOTIFY` it decodes the recorded output (§13) with the caller's decoder —
again, JSON only because this genuinely crosses a process boundary (and
potentially a node), with behavior to establish through an original contract or licensed oracle.

---

## 15. Telemetry / events

- Grind does not own a telemetry event sum or subscription API. Its current target is
  package-owned Sinal descriptors emitted after the job state owner decides a
  transition. Observations never control admission, retries, or cancellation.
- [Package observations](playground/interface_lab/PACKAGE-OBSERVATIONS.md) demonstrates
  `grind/job/cancellation/decided` from a pure queued-job cancellation decision.
  Failed emission preserves the job ID, next state, and decision.
- The original job, queue, attempt, plugin, node, and queue-metric event families remain
  required as package-owned observations. Commit/event ordering, duplicate delivery,
  backend failure, and native telemetry interoperability need runtime evidence; no
  universal lifecycle type is added.

```gleam
// HISTORICAL MECHANISM — superseded by package-owned Sinal descriptors.
// The event families remain in scope; this sum and subscription API are not the current target.
pub type Event {
  JobStarted(job.JobId, queue: String, worker: String)
  JobCompleted(job.JobId, duration: duration.Duration)
  JobFailed(job.JobId, error: worker.PerformError, duration: duration.Duration, will_retry: Bool)
  JobSnoozed(job.JobId, seconds: Int)
  QueueStarted(queue: String)
  QueuePaused(queue: String)
  QueueShuttingDown(queue: String)
  PluginRan(plugin: String, result: Result(Nil, String))
}
```

This earlier typed-sum proposal would have replaced `:telemetry.execute` and
`process.Subject` subscriptions. It is retained only as historical rationale for
the event families; the current design routes observations through Sinal's native
registry after a state transition.

---

## 16. Testing modes

```gleam
// grind/testing.gleam
pub type Mode {
  Enqueued            -- default: row is written, a real queue picks it up
  Inline               -- perform runs synchronously in the caller's process
  Manual                -- row is written but nothing ever processes it
}
```

- All three testing modes remain required with explicit serialization, persistence,
  clock, retry, side-effect, and cleanup semantics. Inline execution cannot establish
  queue recovery, database atomicity, or process-loss behavior.

In `Inline` mode, `insert` calls `worker.perform` directly with the typed
`args` it already has in hand — no JSON round-trip at all, unlike Oban's
`perform_job/2` test helper, which still goes through `Ecto.embedded_schema`
casting. You get `Result(Job(args), InsertError)` back with the real
post-perform state, synchronously.

---

## 17. Wiring example

- This retained runtime sketch illustrates intended supervision and plugin composition.
  Its string-only registration predates full-route/version registration (§3); final
  wiring must use that exact registry and keep runtime protocol constructors internal.

```gleam
import gleam/otp/static_supervisor as supervisor
import pog
import grind
import grind/queue
import grind/plugin

pub fn start(pool_name: process.Name(pog.Message)) {
  let engine = grind.postgres_engine(pool_name)

  let oban =
    grind.new(engine)
    |> grind.with_queue(queue.queue("default", local_limit: 10))
    |> grind.with_queue(
      queue.queue("mailers", local_limit: 5)
      |> queue.with_rate_limit(queue.RateLimit(100, duration.minutes(1), None)),
    )
    |> grind.with_workers([
      worker.register(email_worker),
      worker.register(resize_worker),
    ])
    |> grind.with_plugin(plugin.Pruner(duration.days(7), keep_discarded: True))
    |> grind.with_plugin(plugin.Lifeline(duration.minutes(20)))
    |> grind.with_plugin(plugin.Cron([
      plugin.CronEntry(schedule.Every(duration.hours(1)), fn() {
        worker.to_raw(digest_worker, DigestArgs(period: "hourly"))
      }),
    ]))

  supervisor.new(supervisor.OneForOne)
  |> supervisor.add(pog.supervised(pog.default_config(pool_name)))
  |> supervisor.add(grind.supervised(oban))
  |> supervisor.start
}
```

---

## 18. Feature checklist

| Oban feature                                          | Required capability owner                                          |
| ----------------------------------------------------- | ------------------------------------------------------------------ |
| Queues, local concurrency                             | `queue.QueueConfig`                                                |
| Priorities                                            | `job.Priority`                                                     |
| Scheduling (`schedule_in`/`schedule_at`)              | `worker.Changeset`                                                 |
| Retries + backoff                                     | `backoff.Backoff`, `PerformError`                                  |
| Uniqueness                                            | `unique.Uniqueness`                                                |
| Cron                                                  | `schedule.Schedule` + `plugin.Cron`                                |
| Pruning                                               | `plugin.Pruner`                                                    |
| Orphan rescue                                         | `plugin.Lifeline`                                                  |
| Pause/resume/scale queues                             | `grind.pause/resume/scale`                                         |
| Node & queue metrics                                  | `event.Event` + a metrics-collecting subscriber                    |
| Graceful shutdown                                     | producer `Pause` + grace-period drain (§8)                         |
| Notifiers (Postgres/PG)                               | `pog` LISTEN/NOTIFY, swappable in `Engine`                         |
| Testing modes                                         | `testing.Mode`                                                     |
| Smart queues (global limit, rate limit, partitioning) | `queue.GlobalLimit`, `RateLimit`, `Partition`                      |
| Dynamic/DB-backed cron                                | `plugin.DynamicCron`                                               |
| Workflows (DAG deps)                                  | Raw job workflow compatibility; Saga/Grind typed integration (§10) |
| Batches                                               | `batch.gleam`                                                      |
| Chunking                                              | `chunk.gleam`                                                      |
| Recorder                                              | `recorder.gleam`                                                   |
| Relay                                                 | `relay.gleam`                                                      |
| Reindexer                                             | `plugin.Reindexer`                                                 |

### Capability disposition against `9194f02`

- Retained means still required; expanded adds demonstrated contracts; reassigned
  changes the owner without removing the capability. Deferred means outside the
  initial facade, with the original requirement retained.

| Original capability                                                   | Disposition and destination                                | Evidence and remaining acceptance obligation                                                        |
| --------------------------------------------------------------------- | ---------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Typed arguments, worker codecs, heterogeneous registry                | Expanded — §3 versioned workers and exact route registry   | `WORKER-REGISTRY.md`; process isolation, migrations, and deployed-version tests                     |
| Job state, priorities, tags, attempts, queue override, bulk insertion | Retained; partly deferred — §§2–3                          | `SCHEDULED-JOBS.md`; persisted history and all admission options need tests                         |
| One-time scheduling and cancellation                                  | Expanded — §§3, 8                                          | `SCHEDULED-JOBS.md`, `CLAIM-OWNERSHIP.md`; atomic cancel/complete races and wakeups                 |
| Retry, backoff, snooze, discard                                       | Expanded — §§4, 8                                          | `WORKER-OUTCOMES.md`; Oban 2.24.1 differential timing and crash tests                               |
| Uniqueness                                                            | Expanded; broader policies deferred — §5                   | `UNIQUE-JOBS.md`, pinned uniqueness study; concurrent PostgreSQL admission oracle                   |
| Local queues and pause/resume/scale                                   | Expanded — §7                                              | `QUEUE-CONFIGURATION.md`; live management and atomic occupancy tests                                |
| Global limits, rate limits, partitions                                | Retained/deferred — §7                                     | Original black-box contract or licensed Pro oracle; cluster fault tests                             |
| Claims, orphan rescue, graceful shutdown                              | Expanded — §§6, 8                                          | `CLAIM-OWNERSHIP.md`; OTP/PostgreSQL loss, rescue, drain, and fencing tests                         |
| Cron, dynamic cron, pruning, staging, reindexing                      | Retained/deferred — §6                                     | Pinned OSS oracle where applicable; original advanced contracts and clock/fault tests               |
| PostgreSQL, SQLite, notifier abstraction                              | Retained; SQLite semantics unresolved — §9                 | PostgreSQL isolation/migration and missed-notification tests; SQLite consumer decision              |
| Raw DAG dependencies and upstream-result lookup                       | Retained; ownership integration unresolved — §10           | `composition-contracts.md`; dependency policy, result decoding, cancellation, and persistence tests |
| Typed durable workflow state and compensation                         | Reassigned/expanded — Saga plus optional `saga_grind`, §10 | Saga integration probes; journal/outbox and compensation recovery tests                             |
| Batches and all callback triggers                                     | Retained/deferred — §11                                    | Original contract or licensed Pro oracle; atomic callback admission and recovery                    |
| Chunking and partial results                                          | Retained/deferred — §12                                    | Original contract or licensed Pro oracle; partial-result, timeout, and recovery tests               |
| Recorder and queue request/response                                   | Retained/deferred — §§13–14                                | Typed worker codecs are partial evidence; durable writes and bounded waiting tests                  |
| Events, node/queue metrics                                            | Expanded — §15 package facts through Sinal                 | `PACKAGE-OBSERVATIONS.md`; commit/event ordering and native telemetry tests                         |
| Enqueued, inline, manual testing modes                                | Retained/deferred — §16                                    | Explicit mode contracts, observable differences, and cleanup tests                                  |

### Oracle and unresolved scope

- [API-COVERAGE.md](API-COVERAGE.md#grind) tracks the full capability families.
  Open and Partial entries remain implementation backlog despite the facade freeze;
  no original capability is excluded by this consolidation.
- [Oban 2.24.1 source and tests](https://github.com/oban-bg/oban/tree/v2.24.1)
  remain the pinned OSS behavioral oracle. The research inspected source and tests;
  it did not run the upstream PostgreSQL suite here.
- [Execution research](research/grind-execution-contract.md) and
  [uniqueness research](research/grind-uniqueness-contract.md) define decisive
  differential cases and deliberate differences. Explicit stale/unknown outcomes,
  typed success results, conservative replacement, and typed key equality are Grind
  choices rather than exact Oban parity claims.
- Pro-equivalent capabilities need original black-box contracts from public behavior
  or licensed access to a pinned oracle. Public Pro descriptions do not establish
  internal implementation or test parity.
- Runtime acceptance must prove competing claims, renewal and takeover, exact expiry,
  retry timing, both cancellation/completion orders, shutdown, rescue, codec-version
  rejection, and lifecycle facts for committed transitions. It must expose the
  crash window between external effect and acknowledgement as at-least-once delivery.
- Remaining potential losses are explicit review blockers for full-scope completion:
  replacing raw job DAGs with typed Saga alone; dropping SQLite without a decision;
  losing arbitrary uniqueness states or broad replacement; and omitting original
  priority, tags, queue override, bulk admission, or advanced plugin capabilities.
  Their retained sections and disposition rows prevent the initial facade from
  silently becoming the entire product.

---

## 19. Serialization and compatibility boundaries

- Persisted arguments cross through versioned input codecs and decode into the
  registered worker's native input type. Registration must retain the exact worker
  version required by a stored job.
- Recorded output and business errors have their own codecs because their types
  differ from the input type. Failed encoding or decoding remains an explicit
  boundary failure rather than an invented native value.
- Workflow consumers retain or supply the actual compatible result codec. A raw
  dependency-only workflow is not required to expose a typed final result; a typed
  Saga definition has a separate workflow result contract.
- Global and rate-limit counters are shared database state guarded by transactions.
  Their integer representation neither requires a dynamic application value nor
  establishes cluster coordination.
- Worker versions, key-policy versions, storage schema versions, and journal versions
  are compatibility commitments. Equal version labels do not prove semantic codec
  equivalence; applications must change versions when their contracts change.
- Queue-owner labels identify routes, not authenticated storage authorities. Queue
  ownership epochs fence queue acknowledgements, not arbitrary downstream effects.
