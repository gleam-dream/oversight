# Release API review: grind

Reviewed at grind `b2545a9` (includes `7a04831`) against [grind-design.md](../../grind-design.md),
the [API card](../composition/scan/grind.md), [FEEDBACK.md](../composition/FEEDBACK.md)
(including "Fix round results") and the app findings CHK, EXT, WHK, RA and SMCP.
A scratch consumer package compiled the "today" program below, plus two probes:
a mistyped queue string and a positional `queue.QueuePolicy(...)` constructor. Both compile.

## 1. Verdict

Grind is not release-ready as an API: its engine is careful and well evidenced, but
its facade exposes the engine's parts (pool, registry, consumer, pruner, 28 error
types, 4 `submit*` variants, 59 `@internal pub` helpers) instead of one job system.
The blockers are that an application cannot give Grind its pog pool or its transaction
(CHK-1, CHK-2) and that nothing but the pruner can be supervised; close behind are
loose queue strings that the worker never declares and a handler that gets no job
context (attempt, snooze count, cancellation). A single `grind` facade in Oban's shape
fixes this while keeping typed workers, fenced acknowledgements and the full scope.

## 2. First ten minutes

**Oban, for reference.** Oban's first ten minutes take three concepts. The worker
module declares its queue. Oban's config names the app's `Repo` and the queue limits.
One child goes into the app's supervision tree. `perform/1` receives `%Oban.Job{}`, which
carries the id, attempt and args. `Oban.insert(multi, ...)` enqueues inside the app's
transaction.

**Today** (compiles against `b2545a9` from a scratch consumer):

```gleam
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import grind/job
import grind/postgres
import grind/queue
import grind/registry
import grind/worker

pub fn run(database_url: String) -> String {
  let assert Ok(input) = worker.codec("email-v1", encode_email, email_decoder())
  let assert Ok(output) = worker.codec("msg-id-v1", json.string, decode.string)
  let assert Ok(send_email) =
    worker.define("mailer.send", "v1", input, output, fn(email: Email) {
      Ok("msg:" <> email.to)
    })
  let assert Ok(settings) = postgres.settings(database_url) |> postgres.validate
  let assert Ok(database) = postgres.start(settings)     // second pool, unlinked
  let assert Ok(Nil) = postgres.migrate(database)
  let assert Ok(workers) = registry.new("mailers")        // queue string #1
  let assert Ok(workers) = registry.register(workers, send_email)
  let assert Ok(consumer) =                               // linked to caller, no child spec
    queue.start(database, workers, queue.default_policy_validated())
  let assert Ok(handle) =                                 // queue string #2; "mailer" compiles too
    postgres.submit(database, "mailers", send_email, Email("a@b.c", "hi"))
  process.sleep(500)                                      // no await
  let assert Ok(job.SucceededWith(message_id)) = postgres.outcome(database, handle)
  let assert Ok(queue.StoppedCleanly) = queue.stop(consumer) // only from this process
  let assert Ok(Nil) = postgres.close(database)
  message_id
}
```

**Proposed:**

```gleam
import gleam/otp/static_supervisor as supervisor // plus json, decode, process, pog as today
import grind
import grind/job
import grind/worker

pub fn mailer() -> worker.Worker(Email, String, Nil) {
  worker.new(
    "mailer.send",
    input: worker.codec(encode_email, email_decoder()),
    output: worker.codec(json.string, decode.string),
    perform: fn(email: Email) { Ok("msg:" <> email.to) },
  )
  |> worker.with_queue("mailers")                         // the only place the queue is named
}

pub fn children(pool: pog.Config, name: process.Name(grind.Message)) {
  let config = grind.new(name, pool) |> grind.with_worker(mailer())
  supervisor.new(supervisor.OneForOne)
  |> supervisor.add(grind.supervised(config))             // pool, consumers, pruner, forwarder
}

pub fn send(name: process.Name(grind.Message)) -> String {
  let jobs = grind.named(name)                            // valid across restarts
  let assert Ok(Nil) = grind.migrate(jobs)                // or the app's cigogne migration
  let assert Ok(grind.Inserted(handle)) =
    grind.submit(jobs, job.new(mailer(), Email("a@b.c", "hi")))
  let assert Ok(job.Succeeded(message_id)) = grind.await(jobs, handle, within: 5000)
  message_id
}
```

| Measure                            | Today                  | Proposed                     |
| ---------------------------------- | ---------------------- | ---------------------------- |
| Grind imports                      | 5                      | 3                            |
| Grind calls                        | 15                     | 12                           |
| `let assert` on a library `Result` | 9                      | 3                            |
| Grind types the reader meets       | 11                     | 6                            |
| Places the queue name is written   | 2, unchecked           | 1                            |
| Supervisable                       | no                     | yes, one child               |
| Pools on the database              | 2 (app's and Grind's)  | 1 (Grind's, exported to app) |
| Waiting for a result               | `process.sleep` + poll | `await(within:)`             |

The transactional path (CHK-2) then becomes:

```gleam
pog.transaction(grind.connection(jobs), fn(tx) {
  use _ <- result.try(orders.confirm(tx, order))
  grind.submit_in(jobs, tx, job.new(receipt(), order.id) |> job.with_id("receipt:" <> order.id))
})
```

## 3. Target surface

| Module             | Holds                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `grind`            | `Config` (opaque), `Grind`, `Message`. `new(name, pool: pog.Config)`, `with_worker`, `with_queue(queue.Queue)`, `with_pruner`/`without_pruner`, `without_consumers`, `with_schema`, deadlines, `with_max_payload_bytes`. `start`, `supervised`, `stop`, `named`, `connection`, `migrate`. `submit`, `submit_in`, `reconcile_submission`. `await`, `bind`, `arguments`, `state`, `outcome`, `cancel`. `StartError`, `SubmitError`, `ReadError`, each with `describe_*` and `*_kind`. `Admission` |
| `grind/worker`     | `Worker(i,o,e)`, `Codec`, `Context` (opaque), `Response`, `RetryPolicy`, `RetryDelay`, `Backoff`, `Abandonment`, `TerminalCause`. `new`, `responding`, `with_queue`, `with_version`, `with_error_codec`, `with_max_attempts`, `with_backoff`, `with_retry_policy`, `with_timeout`, `with_max_snoozes`, `with_abandonment`. `codec`, `with_codec_version`. Context accessors                                                                                                                     |
| `grind/job`        | `Job(i,o,e)` (opaque admission request), `JobHandle`, `State`, `Outcome`, `Failure`. `new`, `with_id`, `at`, `after`, `unique`, `with_queue`, `with_max_attempts`, `with_correlation`. `id`, `queue`, `state_name`, `is_finished`                                                                                                                                                                                                                                                               |
| `grind/queue`      | `Queue` (opaque): `new(name)`, `with_concurrency`, `with_poll_interval`, `with_lease`, `with_shutdown_grace`. Needed only to tune a queue                                                                                                                                                                                                                                                                                                                                                       |
| `grind/unique`     | `Policy`, `Key`, `Period`, `QueueScope`, `States`. `policy(key, period)`, `with_scope`, `with_states`, `reschedule_to` (the conflict action moves into the policy), `full_input`, `selected`, `within`, `while_retained`                                                                                                                                                                                                                                                                        |
| `grind/admin`      | Operator work: `list(grind, queue:, state:, limit:)`, `resolution(...)`, `resolve_uncertain`, `quarantine_expired`, `prune_finished`, `reconcile_acknowledgement`. `Error`, `describe_error`. `JobSummary`, `PruneReport`, `AcknowledgementReceipt`                                                                                                                                                                                                                                             |
| `grind/telemetry`  | The 16 Sinal descriptors from `observation` and `diagnostic`, with one shared `Count` measurement and a `correlation` field                                                                                                                                                                                                                                                                                                                                                                     |
| `grind/testing`    | `perform(worker, input)` (inline, codec round trip), `context(job_id:, attempt:)`, `drain(grind, queue, limit:, within:)` (replaces manual polling)                                                                                                                                                                                                                                                                                                                                             |
| `grind/internal/*` | `Execution`, `StoredCodecError`, `CodecKind`, `QueueRunError`, `AckRejection`, `ProcessError`, `Installation`, metadata, codec plumbing, and every current `@internal pub` helper                                                                                                                                                                                                                                                                                                               |

| Count               | Before | After | Note                                                                                                                                     |
| ------------------- | -----: | ----: | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Public modules      |     11 |     8 | `postgres`, `registry`, `submission`, `pruner`, `observation`, `diagnostic` fold away; `admin`, `testing`, `telemetry`                   |
| Public functions    |    159 |  ~105 | 100 documented plus 59 `@internal pub` before. About 25 of the 105 are new capabilities: context, await, `submit_in`, list and testing   |
| Public records      |     44 |   ~32 | Single-constructor records (55 types with labelled fields); 37 are telemetry. 9 count-only measurements become one `Count`               |
| Opaque types        |     22 |   ~18 | `Validated*` ×3, `Database`, `Consumer`, `Pruner`, `JobId` and `Installation` go; `Config`, `Grind`, `Job`, `Context` and `Queue` arrive |
| Error types         |     28 |    ~6 | One per boundary: start, submit, read, admin, testing, and unique policy construction                                                    |
| Ways to admit a job |      4 |     1 | plus `submit_in` (transaction) and `reconcile_submission`                                                                                |
| start/stop pairs    |      3 |     1 | database, consumer and pruner become one supervised tree                                                                                 |

## 4. Proposals

Ranked by user impact. "Breaks" means breaks today's callers. The package is
unpublished, so no migration shims are needed.

### GRIND-R1 Use the application's pool and transaction (blockers CHK-1, CHK-2)

- **Problem.** `Settings` takes only a URL (postgres.gleam:40-50), and `start` builds a
  second pool (:488-508), so checkout, research_agent and extractor each run two pools on
  one database (CHK-1, RA-11, EXT-9). `connection` is `@internal` (:1536). `submit*`
  takes `Database`, so app writes and enqueue cannot commit together, and checkout built
  an outbox (CHK-2). The FFI already runs a `{single_connection, _}` without a new
  checkout (grind_postgres_ffi.erl:67-70), so the mechanism is there.
- **After.**
  ```gleam
  pub fn new(name: process.Name(Message), pool: pog.Config) -> Config   // Grind owns the pool built from the app's pog.Config
  pub fn connection(grind: Grind) -> pog.Connection                     // deadline-bounded; the app's single pool
  pub fn submit_in(grind: Grind, tx: pog.Connection, job: Job(i, o, e))
    -> Result(Admission(i, o, e), SubmitError(i, o, e))
  ```
  `submit_in` issues schema-qualified statements, because the app's `search_path` is not
  pinned. It never opens `BEGIN`/`COMMIT` and emits `admitted` only after
  `reconcile_submission` confirms the receipt on Grind's connection (RELEASE-EXECUTION.md:88-95).
  A shared foreign pool (`new_shared(pool_name)`) can follow once Risk 1 is closed.
- **Breaks:** yes (`postgres.settings`, `postgres.start`). **Effort:** L.

### GRIND-R2 One supervised runtime with a stable handle

- **Problem.** `postgres.start` starts unlinked (postgres.gleam:488-508). `queue.start`
  links to its caller, and `queue.stop` refuses any other process (queue.gleam:843-846),
  so research_agent calls `exit(Pid, shutdown)` through FFI (RA-11). `pruner.supervised`
  returns `ChildSpecification(Subject(Message))` with an opaque, useless `Message`
  (pruner.gleam:151, 262). Three lifecycles must be stopped in order: `close` before
  `stop` abandons claims. The design's wiring is `supervisor.add(grind.supervised(oban))`
  (grind-design.md:801).
- **After.**
  ```gleam
  pub fn supervised(config: Config) -> ChildSpecification(Grind)  // pool, forwarder, consumer per queue, pruner
  pub fn start(config: Config) -> Result(Grind, StartError)
  pub fn stop(grind: Grind) -> Result(StopOutcome, StopError)    // any process; drains, then pool last
  pub fn named(name: process.Name(Message)) -> Grind             // valid before start and across restarts
  pub fn without_consumers(config: Config) -> Config             // submit-only node, Oban `queues: false`
  ```
  The caller-supplied name also ends the atom growth from repeated `validate` calls
  (Risk 12).
- **Breaks:** yes. **Effort:** M to L.

### GRIND-R3 The worker owns its queue; one definition, no dummy `perform`

- **Problem.** The queue string is written twice and never checked:
  `registry.new(queue)` (registry.gleam:26) and `postgres.submit(db, queue, ...)`
  (postgres.gleam:950-955). The scratch probe `submit(db, "mailer", ...)` compiles, and
  no consumer ever claims the job. A handler that snoozes, discards or reports
  uncertainty must still pass `perform` (worker.gleam:162-173): checkout passes
  `fn(_) { Error(Nil) }` (CHK-10), and extractor and webhooks write adapters (EXT-8,
  WHK-8). `define`/`define_with_error_codec` are an arity family. `codec` and `define`
  return `Result` only for an empty string (worker.gleam:21-31, 184-196).
- **After.**
  ```gleam
  pub fn new(id: String, input input: Codec(i), output output: Codec(o),
    perform perform: fn(i) -> Result(o, e)) -> Worker(i, o, e)
  pub fn responding(id: String, input input: Codec(i), output output: Codec(o),
    handle handle: fn(Context, i) -> Response(o, e)) -> Worker(i, o, e)
  pub fn with_queue(worker, queue: String) -> Worker(i, o, e)     // default "default", as in Oban
  pub fn with_version(worker, version: String) -> Worker(i, o, e) // default "1"
  pub fn with_error_codec(worker, codec: Codec(e)) -> Worker(i, o, e)
  pub fn codec(encode: fn(v) -> Json, decoder: Decoder(v)) -> Codec(v)  // version "1"; with_codec_version
  ```
  `grind.with_worker` derives the registry. `start` rejects a `queue.new(name)` that no
  registered worker uses and a duplicate `(id, version)`. Empty ids and versions fail at
  `start` or `submit` with a typed error. `job.with_queue` keeps Oban's per-job override,
  and checking it is the caller's choice.
- **Breaks:** yes. **Effort:** M.

### GRIND-R4 A job context with attempt, snooze count and cancellation

- **Problem.** The handler is `fn(input)` (worker.gleam:147-158), although the registry
  already holds a `RetryContext` (registry.gleam:17, worker.gleam:91-93). A snooze rolls
  `attempt_count` back (acknowledgement.gleam:231), so a worker that always answers 429
  snoozes forever; the fix round rated this major (WHK-8). `cancel` never reaches the
  handler, so research_agent fans the cancellation out itself (RA-5). Apps keep
  job-to-request join tables because the handler never learns its job id (WHK-5, EXT-4,
  CHK-5).
- **After.**
  ```gleam
  pub opaque type Context   // grows: tags, priority, workflow step
  // job_id, attempt, max_attempts, snooze_count: Int; queue: String
  pub fn correlation(c: Context) -> Option(String)        // from job.with_correlation / with_id
  pub fn cancellation(c: Context) -> process.Selector(Nil) // fires when `cancel` commits
  pub fn deadline(c: Context) -> Option(Int)              // from with_timeout
  ```
- **Breaks:** no (new). **Effort:** L, for delivering cancellation from the renewer.

### GRIND-R5 One admission path

- **Problem.** `submit`, `submit_at`, `submit_with_id` and `submit_unique`
  (postgres.gleam:950, 967, 1952, 1872) express availability twice: as separate
  functions and as `submission.Availability`. `submit_unique` takes 8 positional
  arguments, with `on_conflict` outside the policy. `reconcile_unique` also reconciles
  `submit_with_id`. Plain `submit` is not retry-safe (`CommitUnknownWithoutId`,
  postgres.gleam:1039, Risk 14). `SubmissionId` and `AvailableAt` each need a `let assert`.
- **After.**
  ```gleam
  job.new(worker, input) -> Job(i, o, e)
  |> job.with_id(String)                 // idempotency key, checked at submit
  |> job.at(timestamp.Timestamp)         // or job.after(duration.Duration): Oban's schedule_in
  |> job.unique(unique.Policy(i))        // conflict action lives in the policy
  |> job.with_correlation(String)
  grind.submit(grind, job) -> Result(Admission(i, o, e), SubmitError(i, o, e))
  grind.reconcile_submission(grind, PendingSubmission(i, o, e)) -> Result(Admission(i, o, e), SubmitError(i, o, e))
  ```
  Back every admission with a receipt, using a generated id when none is given. That way
  `CommitUnknown(pending)` is always reconcilable and `CommitUnknownWithoutId` disappears
  (open question 5).
- **Breaks:** yes. **Effort:** M.

### GRIND-R6 Typed outcomes and classified errors

- **Problem.** `FailedOperationally(String)` carries three persisted states
  (job_reads.gleam:522-546): a business failure without an error codec, `runtime_failed`
  and `contract_mismatch`. `*With`/`*WithCause` pairs encode an optional cause as extra
  variants (job.gleam:200-211). No error type has a `describe` function. The 28 error
  types repeat the same few classes per operation (`CancellationQueryFailed`,
  `JobReadQueryFailed` and `QuarantineQueryFailed` all wrap one database failure).
  `QueueRunError` exposes the erased `worker.Execution`, whose `ExecutedInvalidInput`
  holds `string.inspect` text (postgres.gleam:1470-1473, worker.gleam:470).
- **After.**
  ```gleam
  pub type Outcome(o, e) {
    Pending(State)  Succeeded(o)  Uncertain(evidence: String)  Discarded(reason: String)
    Failed(reason: Failure(e), cause: Option(TerminalCause), description: String)
    Cancelled(reason: String)  // keeps the handler's WorkerCancelled reason (RA-5)
  }
  pub type Failure(e) { Business(e) BusinessUnrecorded RuntimeFailure ContractMismatch }
  pub type ErrorKind { Invalid NotFound Mismatch Contended Unavailable CommitUnknown }
  pub fn submit_error_kind(e: SubmitError(i, o, e)) -> ErrorKind
  pub fn describe_submit_error(e: SubmitError(i, o, e)) -> String
  ```
  The docs say that `State`, `Outcome`, `TerminalCause` and every error type may gain
  variants. Callers branch on `*_kind`. Add `job.state_name` and `job.is_finished`, which
  secure_mcp and extractor wrote themselves (EXT-11, SMCP nit).
- **Breaks:** yes. **Effort:** M.

### GRIND-R7 Abandonment replay and an operator list (RA-2, CHK-6)

- **Problem.** A job whose node died stays `Uncertain` until
  `resolve_uncertain(AuthorizeReplay)` with a made-up resolver releases it
  (postgres.gleam:777); research_agent runs a 38-line sweep. Reads need a handle, so an
  operator cannot find uncertain jobs. The design specifies Lifeline (grind-design.md:327).
- **After.**
  ```gleam
  pub type Abandonment { HoldUncertain  ReplayAfterLeaseExpiry(max_replays: Int) }
  pub fn with_abandonment(worker, policy: Abandonment) -> Worker(i, o, e)   // default HoldUncertain
  admin.list(grind, queue: Option(String), state: job.State, limit: Int) -> Result(List(JobSummary), admin.Error)
  ```
  The fail-closed default stays. Replay is a per-worker declaration for handlers that are
  idempotent by construction.
- **Breaks:** no. **Effort:** L.

### GRIND-R8 Bound every wait by default

- **Problem.** A handler has no timeout, and its lease is renewed for as long as it
  runs. `process_one` waits in a 1 s loop for as long as the coordinator lives
  (queue.gleam:786-800). Snoozes have no cap. Checkout uses `{timeout, infinity}` and
  relies on pgo's CoDel shedding (grind_postgres_ffi.erl:111). Nothing prunes unless the
  app starts a pruner. Payloads have no size limit. There is no `await`, so apps poll
  (EXT-11). See section 5.
- **After.** `worker.with_timeout(worker, Timeout)` with a default and an explicit
  `Infinity`. On expiry, the handler is killed and the abandonment policy decides what
  happens next. `worker.with_max_snoozes`, which ends in `TerminalCause.SnoozeLimitReached`.
  `grind.await(grind, handle, within:)`. `testing.drain(.., within:)`. The pruner is on by
  default and turned off with `without_pruner`. `with_max_payload_bytes`.
- **Breaks:** behavior only. **Effort:** M.

### GRIND-R9 Opaque `Config`, no `Validated*` types, `config` not `settings`

- **Problem.** `Settings`, `QueuePolicy` and `PrunerPolicy` are public records that also
  carry a `with_*` setter for every field (postgres.gleam:40-152, queue.gleam:51-173,
  pruner.gleam:44-64). The probe `queue.QueuePolicy(queue.PollEvery(100), 1, 5, 30_000,
5000)` compiles, so any new option breaks positional callers, as it did in http_gun in
  the fix round. `ValidatedSettings`, `ValidatedPolicy`, `ValidatedPrunerPolicy` and
  `default_policy_validated()` ×2 double every config path. `settings` disagrees with
  the siblings' `config`. Five constants are published as functions
  (`statement_deadline_ms`, `prune_limit_maximum`, `retry_delay_maximum_milliseconds`,
  `max_attempts_supported_maximum`, `default_retry_delay_milliseconds`). `ConfigError`
  drops the numbers (CHK-11).
- **After.** `grind.new` with `with_*` setters. Validation happens once in `start` and
  `supervised`, returning `StartError.InvalidConfig(ConfigError)`. Each variant carries
  its numbers, for example `UniqueLockWaitTooCloseToDeadline(lock_wait_ms:, margin_ms:, deadline_ms:)`.
- **Breaks:** yes. **Effort:** S.

### GRIND-R10 Consolidate modules and remove machinery from the public surface

- **Problem.** `grind/postgres` holds 34 functions spanning configuration, lifecycle,
  admission, reads and operator work. The public modules export 59 `@internal pub`
  helpers (job.gleam:49-338, unique.gleam:147-262, worker.gleam:271-549,
  queue.gleam:102-1227). `job.JobId` has no accessor and no use (job.gleam:112, 214).
  `pruner.supervisor_pid` and `registry.queue` leak internals, and `grind.version()`
  hard-codes `"0.1.0"`. Telemetry is split across `observation` and `diagnostic`, with 9
  records that hold only `count: Int`. Only `admitted` carries `submission_id`
  (observation.gleam:182; CHK-5), and measurements have no timestamp, so arrival order
  across forwarders is not causal (WHK-5).
- **After.** Use the module list in section 3. `grind/telemetry` gives every
  `[grind, job, *]` event a `correlation: Option(String)` and a `monotonic_ms` measurement.
- **Breaks:** yes. **Effort:** M.

### GRIND-R11 A public `grind/testing`

- **Problem.** Manual polling (`with_manual_polling`, `process_one`,
  `process_available`, `with_maximum_batch_jobs`, `BatchOutcome`, `ProcessError` ×11)
  lives in the production queue API. The design's Inline and Manual modes are missing
  (grind-design.md:733-757; RELEASE-READINESS.md:107 lists them for before 1.0). The
  consumer tests count attempts by hand
  (consumer/test/grind_consumer/support/workers.gleam:111-118). `worker.invoke` ignores
  the queue handler.
- **After.**
  ```gleam
  testing.perform(worker, input) -> worker.Response(o, e)              // codec round trip, synthetic Context
  testing.perform_with(worker, testing.context(job_id: 1, attempt: 3), input)
  testing.drain(grind, queue: String, limit: Int, within: Int) -> Result(Int, testing.Error)
  ```
- **Breaks:** yes (manual mode moves). **Effort:** M.

### GRIND-R12 Dependencies and docs that match behavior

- **Problem.** `sinal = { path = "../sinal" }` blocks publication (gleam.toml:24).
  `pog.QueryError` sits in public errors under a `< 4.2` pin, so a pog upgrade becomes a
  Grind major release. Durations and times are raw `Int` milliseconds. `grind.gleam:1-5`
  calls the package a "serial consumer slice", although concurrency exists.
  `queue.gleam:44, 138` point to a `process_batch` that does not exist. `job`, `worker`,
  `registry` and the root have no module doc (`////`). The README opens with a 50-line
  paragraph; its first code (line 104) defines no worker and submits no job. There is no
  CHANGELOG.
- **After.** Pin sinal to a Hex version. Keep `pog.QueryError` only inside an
  `Unavailable(pog.QueryError)` variant behind `*_kind`. Take `gleam_time` `Timestamp` and
  `Duration` in `job.at`, `job.after` and the timeouts. Start the README with the
  section 2 program and the section 5 table.
- **Breaks:** partly. **Effort:** S.

## 5. Defaults table

| Operation                          | Current default                                                                             | Proposed default                                                |
| ---------------------------------- | ------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| Storage call (checkout hold)       | 4000 ms (`statement_deadline`)                                                              | keep                                                            |
| Checkout queue wait                | none from Grind; pgo CoDel shedding only (ffi:111)                                          | `with_checkout_timeout`, default = statement deadline           |
| Pool initial connect / `start`     | unbounded TCP connect (README:498)                                                          | `start` fails after 15 s with `StartError.Unavailable`          |
| Uniqueness lock wait               | 2000 ms                                                                                     | keep                                                            |
| Migration step / lock              | 30 000 ms / 2000 ms fixed                                                                   | keep; numbers in errors                                         |
| Handler execution                  | **none**; the lease is renewed indefinitely                                                 | 15 min, `with_timeout(Infinity)` explicit                       |
| Business retries                   | 20 attempts, 15 s doubling to 1 day, no jitter                                              | keep; add jitter (Oban parity), open question                   |
| Snoozes                            | **unbounded**; a snooze refunds the attempt                                                 | 100, then terminal `SnoozeLimitReached`                         |
| Uncertain (abandoned) jobs         | held until an operator resolves them                                                        | keep `HoldUncertain` (fail closed); replay opt-in               |
| Lease / renewal                    | 30 s, renew every L/3, minimum 4 × deadline                                                 | keep                                                            |
| Poll interval                      | 250 ms                                                                                      | keep until LISTEN/NOTIFY                                        |
| Local concurrency per queue        | 1                                                                                           | 10, checked at `start` against the pool size                    |
| Manual batch (`process_available`) | 1                                                                                           | becomes the required `limit:` on `testing.drain`                |
| `process_one` / manual wait        | **none** while the coordinator lives                                                        | `within:` required                                              |
| Await a result                     | n/a (apps sleep and poll)                                                                   | `await(within:)` required                                       |
| Shutdown grace                     | 5000 ms; stop waits grace + 1 s + 6 s                                                       | 15 000 ms (Oban `shutdown_grace_period`)                        |
| Observation forwarder              | 1024 events, drops beyond                                                                   | keep                                                            |
| Job retention                      | **unbounded** unless the app starts a pruner; pruner max age 60 s, every 30 s, limit 10 000 | pruner on by default, max age 7 days; `without_pruner` explicit |
| Prune / quarantine per call        | limit required, at most 10 000                                                              | keep                                                            |
| Input / output / error payload     | **unbounded** JSON, both on encode and on read                                              | 1 MiB, typed `PayloadTooLarge`                                  |
| Pool size                          | 10                                                                                          | from the app's `pog.Config`                                     |
| Atom creation                      | 2 names per `validate`, 2 per consumer start (Risk 12)                                      | names are supplied once by the caller                           |

Security defaults are sound. `search_path` is pinned, an unknown schema fails closed,
isolation is pinned to READ COMMITTED, and `idle_in_transaction_session_timeout` is set
to twice the deadline. The defaults are spread across README sections ("Deadlines",
"Retention" and others). The README should collect them in this one table.

## 6. Convention feedback

- **Conventions 1 and 2 against PUBLIC-API-GUIDELINES.md.** The guidelines prefer public
  settings records and say record updates need no builder. Grind did both at once, which
  has the cost of both and the safety of neither. Options will keep arriving (priority,
  tags, rate limits, cron), so convention 1 is right and the guidelines should follow it.
- **Validation sites (convention 1).** `submit` uses a worker definition on nodes that
  never start consumers. Definitions with only string invariants should be infallible,
  and both `start` and `submit` check them with one typed error. The convention should
  name both sites.
- **Stable handle (convention 5).** The handle needs a name that exists before `start`,
  as pog's config already does. The convention should specify `new(name, ...)` plus
  `<pkg>.named(name) -> Handle`, so a web handler reaches the runtime without threading.
- **Bounded queues (convention 4).** Grind's queues are durable tables. The bound there
  is a retention default and a payload limit, not an in-memory capacity. Say so.
- **`describe_error` (convention 6).** `grind` has three boundaries (start, submit,
  read). Allow `describe_<boundary>_error` and `<boundary>_error_kind`; one module per
  boundary would cost the newcomer an import.
- **Correlation (convention 7).** Define it as an optional caller-supplied string that
  flows from `job.with_correlation` into the context and every event, so http_gun and
  saga can carry the same value onward.
- **JSON currency (convention 8).** Grind fits. A persisted codec also needs a version:
  allow `encoder + decoder + version` built from `json.Json` and `decode.Decoder`.
- **One ordinary path (convention 9).** `worker.new`/`worker.responding` pass, because
  the second adds context and a richer response. `define`/`define_with_error_codec` fail.

## 7. Open questions

1. **Pool ownership.** Grind could own a pool built from the app's `pog.Config` and
   export `connection` (possible now). Or it could accept a foreign pool, which needs
   Risk 1 closed, either through a pog upstream checkout deadline or a fork. The first
   option unblocks CHK-1 without the second.
2. **Transactional submit shape.** The choice is a borrowed `tx` connection
   (`submit_in`) or a Grind-managed `grind.transaction(grind, fn(tx) {..})` that owns the
   checkout (RELEASE-EXECUTION.md:95). Separately, can unique admission run inside a
   caller transaction? It pins READ COMMITTED as the first statement and takes an
   advisory lock.
3. **Default versions.** Should workers and codecs default to version `"1"`? Oban has
   no versioning at all. An explicit version is safer for a later migration, but it
   costs every newcomer three strings.
4. **Default numbers.** The handler timeout (15 min), snooze cap (100), pruner age
   (7 days), payload limit (1 MiB) and concurrency (10) each need an owner decision.
5. **Receipts for every submit.** Backing every submit with a receipt removes a
   non-retryable failure mode. It also costs one more row and index write per job.
   Benchmark this against Risk 19 before deciding.
6. **Submit result.** `Admission` makes the common path match `Inserted(handle)`. The
   alternative returns `JobHandle` and reports a unique conflict as `Error(Duplicate(..))`.
   Oban returns `{:ok, job}` with `conflict?: true`.
7. **Queue identity.** Is a string on the worker enough, with `start` checking the
   configured queues? Or should `Queue` be a typed value that both the worker and the
   config reference? The design's route model includes a storage owner
   (grind-design.md:343).
8. **Durability ownership with fabric and saga** (FEEDBACK theme 5). Abandonment replay
   (R7) assumes that Grind owns delivery and that the other packages own effect
   checkpoints.
