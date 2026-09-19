# `grind` — a feature-complete Oban for Gleam

A design for a strongly-typed port of Oban to Gleam, with everything Oban and
Oban Pro offer folded into one flat, unified library — no OSS/Pro split. The
guiding rule:
**anything that lives only in-process stays typed; anything that has to survive a
process crash, a node restart, or a network hop gets serialized — and that's the
only place `Dynamic`/JSON shows up.** Oban's own architecture already isolates that
boundary behind `Ecto.Changeset` + schemaless embeds; this design just makes the
boundary explicit instead of implicit.

Runtime: `gleam_otp` actors + supervisors, `pog` for Postgres (LISTEN/NOTIFY +
polling), optional `sqlight` engine for the SQLite3 parity Oban added.

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
├── grind/event.gleam       -- typed telemetry events + subscribe
├── grind/testing.gleam     -- Mode: Enqueued | Inline | Manual
├── grind/workflow.gleam    -- DAG-of-jobs workflows
├── grind/batch.gleam       -- batches with completion callbacks
├── grind/chunk.gleam       -- chunked/batched worker execution
├── grind/relay.gleam       -- synchronous request/response over the queue
└── grind/recorder.gleam    -- typed capture of a job's return value
```

---

## 2. Core types

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

Gleam has no typeclasses, so a "worker" is a value carrying its own codec —
this replaces `use Oban.Worker` + `perform/1` + the module's own
`Jason.Encoder`/`Ecto.embedded_schema`:

```gleam
// grind/worker.gleam
pub type PerformError {
  Cancel(reason: String)
  Snooze(seconds: Int)
  Discard(reason: String)
  Retry(reason: String)
}

pub type Worker(args) {
  Worker(
    name: String,
    queue: String,
    max_attempts: Int,
    priority: Priority,
    backoff: backoff.Backoff,
    unique: Option(unique.Uniqueness(args)),
    encode: fn(args) -> json.Json,
    decode: decode.Decoder(args),
    perform: fn(job.Job(args)) -> Result(Nil, PerformError),
  )
}

pub fn new(
  name name: String,
  queue queue: String,
  encode encode: fn(args) -> json.Json,
  decode decode: decode.Decoder(args),
  perform perform: fn(job.Job(args)) -> Result(Nil, PerformError),
) -> Worker(args) {
  Worker(name:, queue:, max_attempts: 20, priority: Normal, backoff: backoff.default(),
    unique: None, encode:, decode:, perform:)
}

pub fn max_attempts(w: Worker(a), n: Int) -> Worker(a) { Worker(..w, max_attempts: n) }
pub fn priority(w: Worker(a), p: Priority) -> Worker(a) { Worker(..w, priority: p) }
pub fn backoff(w: Worker(a), b: backoff.Backoff) -> Worker(a) { Worker(..w, backoff: b) }
pub fn unique(w: Worker(a), u: unique.Uniqueness(a)) -> Worker(a) { Worker(..w, unique: Some(u)) }
```

### Enqueueing — a typed changeset, not a keyword list

```gleam
pub opaque type Changeset(args) {
  Changeset(
    worker: Worker(args),
    args: args,
    scheduled_at: Option(timestamp.Timestamp),
    priority: Option(Priority),
    tags: List(String),
    queue_override: Option(String),
  )
}

pub fn build(worker: Worker(args), args: args) -> Changeset(args) {
  Changeset(worker:, args:, scheduled_at: None, priority: None, tags: [], queue_override: None)
}
pub fn schedule_in(cs: Changeset(a), seconds s: Int) -> Changeset(a) { ... }
pub fn schedule_at(cs: Changeset(a), at t: timestamp.Timestamp) -> Changeset(a) { ... }
pub fn tag(cs: Changeset(a), tags: List(String)) -> Changeset(a) { ... }

pub fn insert(oban: Oban, cs: Changeset(a)) -> Result(Job(a), InsertError)
pub fn insert_all(oban: Oban, css: List(Changeset(a))) -> Result(List(Job(a)), InsertError)
```

`insert` calls `worker.encode(cs.args)` exactly once, right at the DB write —
callers never see `json.Json` unless they choose to.

### The heterogeneous-registry problem

A queue runs many worker types. You can't have `List(Worker(a))` for mixed
`a`. Solve it with a closure that closes over its own type at registration
time (Gleam's version of an existential):

```gleam
pub opaque type Registered {
  Registered(name: String, run: fn(RawJob) -> Result(Nil, PerformError))
}

pub fn register(w: worker.Worker(a)) -> Registered {
  Registered(w.name, fn(raw) {
    case decode.run(raw.args_json, w.decode) {
      Ok(args) -> w.perform(job.Job(..raw_to_job(raw), args:))
      Error(_) -> Error(Discard("undecodable args for " <> w.name))
    }
  })
}

pub fn registry(workers: List(Registered)) -> Dict(String, Registered) {
  workers |> list.map(fn(r) { #(r.name, r) }) |> dict.from_list
}
```

This is the _only_ intentional dynamic-typing seam in the whole library —
job args cross a process/restart boundary through Postgres, so they must be
serializable. Everything downstream of `decode.run` is fully typed again.

---

## 4. Backoff

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

Oban's `unique: [fields: [:args, :queue], keys: [:type], period: 60]` becomes
a typed extractor instead of a keyword soup — no risk of typoing a field atom:

```gleam
// grind/unique.gleam
pub type UniqueBy(args) {
  ByFullArgs
  ByArgsSubset(extract: fn(args) -> List(#(String, String)))
  ByQueue
  ByWorker
}

pub type Uniqueness(args) {
  Uniqueness(
    period: duration.Duration,
    by: List(UniqueBy(args)),
    states: List(job.JobState),   -- defaults to [Available, Scheduled, Executing, Retryable]
  )
}
```

`ByArgsSubset` still ends up hashed into a text column for the DB unique
index, but the _call site_ is a real function of `args`, checked by the
compiler — you can't reference a field that doesn't exist on `args`.

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
promoting `Scheduled` → `Available`, exactly like Oban's own design.

Graceful shutdown: on supervisor `shutting_down`, the top-level `Oban`
process sends `Pause` to every producer, waits (bounded by a configurable
grace period) for in-flight `Executing` jobs to finish via `JobFinished`,
then lets the supervisor proceed — jobs still running past the grace period
are left `Executing` for the `Lifeline` plugin to rescue on the next boot.

---

## 9. Storage engine abstraction

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
satisfying state — a `workflow_deps` join table, same shape as Oban Pro's.

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

The queue producer accumulates decoded, same-worker `Job(args)` up to
`size` or `timeout`, calls `chunk.perform` once, then reports each job's
individual `Result` back to the engine — so partial failures inside a chunk
still retry only the failed jobs, same as Oban Pro.

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

Implementation: inserts the job, subscribes to a `pog` `LISTEN` channel
named after the job id, and does a `process.receive` with `timeout_ms`. On
`NOTIFY` it decodes the recorded output (§13) with the caller's decoder —
again, JSON only because this genuinely crosses a process boundary (and
potentially a node), same as Oban Pro's own implementation over Postgres.

---

## 15. Telemetry / events

```gleam
// grind/event.gleam
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

pub fn subscribe(oban: Oban, handler: fn(Event) -> Nil) -> process.Subject(Event)
```

A typed sum type instead of `:telemetry.execute([:oban, :job, :stop], measurements, metadata)`
with metadata as a loosely-typed map — pattern-matching `Event` is
exhaustive-checked, so adding a new event forces every handler to be
updated or explicitly wildcard it.

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

In `Inline` mode, `insert` calls `worker.perform` directly with the typed
`args` it already has in hand — no JSON round-trip at all, unlike Oban's
`perform_job/2` test helper, which still goes through `Ecto.embedded_schema`
casting. You get `Result(Job(args), InsertError)` back with the real
post-perform state, synchronously.

---

## 17. Wiring example

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

| Oban feature                                          | Covered by                                      |
| ----------------------------------------------------- | ----------------------------------------------- |
| Queues, local concurrency                             | `queue.QueueConfig`                             |
| Priorities                                            | `job.Priority`                                  |
| Scheduling (`schedule_in`/`schedule_at`)              | `worker.Changeset`                              |
| Retries + backoff                                     | `backoff.Backoff`, `PerformError`               |
| Uniqueness                                            | `unique.Uniqueness`                             |
| Cron                                                  | `schedule.Schedule` + `plugin.Cron`             |
| Pruning                                               | `plugin.Pruner`                                 |
| Orphan rescue                                         | `plugin.Lifeline`                               |
| Pause/resume/scale queues                             | `grind.pause/resume/scale`                      |
| Node & queue metrics                                  | `event.Event` + a metrics-collecting subscriber |
| Graceful shutdown                                     | producer `Pause` + grace-period drain (§8)      |
| Notifiers (Postgres/PG)                               | `pog` LISTEN/NOTIFY, swappable in `Engine`      |
| Testing modes                                         | `testing.Mode`                                  |
| Smart queues (global limit, rate limit, partitioning) | `queue.GlobalLimit`, `RateLimit`, `Partition`   |
| Dynamic/DB-backed cron                                | `plugin.DynamicCron`                            |
| Workflows (DAG deps)                                  | `workflow.gleam`                                |
| Batches                                               | `batch.gleam`                                   |
| Chunking                                              | `chunk.gleam`                                   |
| Recorder                                              | `recorder.gleam`                                |
| Relay                                                 | `relay.gleam`                                   |
| Reindexer                                             | `plugin.Reindexer`                              |

---

## 19. Where "dynamic" survives, and why

Three seams, all inherent to Oban's own architecture, not weaknesses of
this design:

1. **Job args at rest** — `jsonb` in Postgres, decoded once via
   `Registered.run` (§3).
2. **Recorded results** — same shape, needed because a workflow/relay
   consumer's result type is independent of the producer's args type (§13).
3. **Global/rate-limit counters** — plain integers in a DB row, not typed
   data at all, just shared mutable state guarded by SQL, same as Oban Pro.

Everything else — states, errors, priorities, backoff, cron, workflow
policy, queue config — is a real Gleam sum type, checked exhaustively by the
compiler, with no `Dynamic` or stringly-typed config anywhere in the public API.
