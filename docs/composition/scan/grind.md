# grind — API card

Typed, durable background jobs on OTP and PostgreSQL, with Oban OSS 2.24.1 as the
behavioral reference. Repo: `/code/gleam-dream/grind`. Design: [grind-design.md](../../../grind-design.md).

## Health

| Gate step (run through `nix develop --command`)                                                                                                                           | Result          |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------- |
| `gleam format --check src test` (root and `consumer/`)                                                                                                                    | pass            |
| `bash scripts/test-postgres.sh` (gleam clean, throwaway PG 16, Squirrel check, root `gleam test`, contract markers, Oban oracle, paired oracle, `consumer/` `gleam test`) | GATE_RESULT     |
| External `consumer/` package build and tests (inside the gate)                                                                                                            | CONSUMER_RESULT |

- Git head: `a1627b5 chore: summarize release evidence and remove generated results`. The worktree was clean before and after the run.
- The gate writes paired-oracle results to `oracle/results/`, which Git does not ignore. This run redirected them with `GRIND_ORACLE_RESULTS_ROOT` to a scratch directory. The script started its own disposable cluster on a random port, and its `trap` stopped that cluster.
- Version `0.1.0` is unpublished. `sinal = { path = "../sinal" }` (gleam.toml:24) blocks Hex publication. RELEASE-READINESS.md:9-15 says no release candidate is qualified: the Sinal pin, final-source qualification, the independent result review and the package-content review remain open.
- There is no `TODO` or `FIXME` in `src/` or `consumer/src/`. Open items come from docs/RISKS.md:
  - Risk 4 (renewal starvation): the 2026-09-28 implementation moved ACKs to the attempt and added an independent renewer on a reserved connection (RISKS.md:179-193), but the entry's closing status still reads "Open, high severity" (RISKS.md:333). The register contradicts itself.
  - Risk 19: one coordinator per consumer claims serially, so throughput reaches 0.20 to 0.43 of the T3 target at C=50. Batch claims are deferred.
  - Risk 1: Grind couples to pog/pgo private shapes, so the pins stay tight (`pog >= 4.1 < 4.2`, `pgo >= 0.20 < 0.21`).
  - Risks 14 and 18: plain `submit` is not retry-safe, and no connection pooler has been tested.
  - Day-long endurance is unverified, and the two-hour soak predates the diagnostics work.
- Planned before 1.0: transaction-scoped enqueue and public testing helpers (RELEASE-READINESS.md:107).

## Purpose and scope delivered vs design

Grind persists typed jobs. A versioned `Worker(input, output, error)` definition owns its
identity, its JSON codecs, the attempt limit and the retry policy. Admission into PostgreSQL
returns an opaque typed `JobHandle`. A supervised per-queue consumer claims jobs under
database-time leases, renews them from a reserved connection, and records outcomes through
fenced, receipt-backed acknowledgements. A lost commit reply has a conservative recovery
path: the job becomes `Uncertain` and needs an audited resolution. Other delivered features
are plain, scheduled, id-idempotent and unique admission; retry, snooze, discard, cancel and
uncertain outcomes; typed outcome reads; quarantine; pruning with a supervised pruner; a
versioned migration runner with a cigogne mirror; and lifecycle and diagnostic Sinal events.
The design calls for full Oban plus Pro. These large pieces are still missing
(IMPLEMENTATION-SCOPE.md:375-399):

- Cron and recurring schedules, and plugins (Lifeline, Stager, Reindexer, DynamicCron). Only the pruner exists.
- LISTEN/NOTIFY wake-up. Delivery is polling only.
- Pause, resume and scale at runtime; priorities and tags; bulk insert (`insert_all`).
- Global, rate and partition limits. Concurrency is local to one consumer only.
- Transactional enqueue in the caller's pog transaction; testing modes (inline and manual helpers).
- Workflows, batches, chunking, recorder, relay, the SQLite backend and the storage abstraction.
- A handler-visible job context: attempt number, job id and a cancellation signal.

## Public modules

| Module              | Responsibility                                                                                                                                                                                                                                                                   |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `grind`             | `version()` only                                                                                                                                                                                                                                                                 |
| `grind/worker`      | `Codec(v)`, `codec`; `Worker(i,o,e)`, `define`, `define_with_error_codec`, `with_max_attempts`, `with_retry_policy`, `with_queue_handler`, `invoke`; `WorkerResponse`, `RetryDelay`, `RetryPolicy`                                                                               |
| `grind/job`         | `JobHandle(i,o,e)`, `JobId`, `AvailableAt` (`available_at`), `State` (11 variants), `Outcome(o,e)`                                                                                                                                                                               |
| `grind/registry`    | `Registry` for one queue: `new(queue)`, `register(worker)`                                                                                                                                                                                                                       |
| `grind/queue`       | `QueuePolicy` record and `with_*` setters, `validate_policy`, `start`/`stop`, manual `process_one`/`process_available`, `StartError`/`ProcessError`/`StopOutcome`                                                                                                                |
| `grind/postgres`    | `Settings`, `validate`, `start`/`close`, `migrate`; `submit`/`submit_at`/`submit_with_id`/`submit_unique`/`reconcile_unique`; `bind_handle`, `arguments`, `state`, `outcome`, `cancel`, `resolve_uncertain`, `reconcile_acknowledgement`, `quarantine_expired`, `prune_finished` |
| `grind/submission`  | `SubmissionId`, `Availability` (`Immediately`/`At`), `Admission` (`Inserted`/`Existing`/`Rescheduled`), `Conflict`, `PendingSubmission`, `SubmitError`                                                                                                                           |
| `grind/unique`      | `Policy(input)`, `Key` (`full_input`/`selected`), `QueueScope`, `Period`, `States`, `ConflictAction`                                                                                                                                                                             |
| `grind/pruner`      | `PrunerPolicy`, `start`/`stop`, and `supervised` (the only `ChildSpecification` in the package)                                                                                                                                                                                  |
| `grind/observation` | Ten Sinal descriptors: `[grind, job, admitted/claimed/acknowledged/quarantined/resolved/cancellation_decided/released/contract_mismatch_recorded]` and `[grind, prune, completed/failed]`                                                                                        |
| `grind/diagnostic`  | Six `[grind, diagnostic, …]` descriptors: renewal, acknowledgement, acknowledgement_retry, checkout, claim_failed, capacity                                                                                                                                                      |

## Common path

This snippet compiles against the current tree from a scratch consumer package. The
caller polls for completion because no await API exists.

```gleam
pub type Email { Email(to: String, subject: String) }

pub fn run(database_url: String) -> String {
  let assert Ok(input) = worker.codec("email-v1", encode_email, email_decoder())
  let assert Ok(output) = worker.codec("msg-id-v1", json.string, decode.string)
  let assert Ok(send_email) =
    worker.define("mailer.send", "v1", input, output, fn(email: Email) -> Result(String, Nil) {
      Ok("msg:" <> email.to)
    })
  let assert Ok(settings) = postgres.settings(database_url) |> postgres.validate
  let assert Ok(database) = postgres.start(settings)        // Grind-owned pog pool, unlinked
  let assert Ok(Nil) = postgres.migrate(database)
  let assert Ok(workers) = registry.new("mailers")
  let assert Ok(workers) = registry.register(workers, send_email)
  let assert Ok(consumer) =                                  // linked to the caller; no child spec
    queue.start(database, workers, queue.default_policy_validated())
  let assert Ok(handle) =
    postgres.submit(database, "mailers", send_email, Email("a@b.c", "hi"))
  process.sleep(500)                                         // or await postgres.state / sinal acknowledged
  let assert Ok(job.SucceededWith(message_id)) = postgres.outcome(database, handle)
  let assert Ok(queue.StoppedCleanly) = queue.stop(consumer) // must run in the starting process
  let assert Ok(Nil) = postgres.close(database)
  message_id
}
```

## Configuration and advanced paths

- **Database**: `postgres.Settings` is a public record with `with_pool_size`, `with_schema` (the isolation unit, default `"public"`), `with_statement_deadline` (default 4000), `with_unique_lock_wait` (2000), `with_migration_deadline` (30000) and `with_observation_capacity` (1024). `validate` checks every value before any process starts.
- **Queues**: `QueuePolicy` sets polling (`PollEvery(ms)` or `Manual`), `maximum_concurrency` (default 1), `maximum_batch_jobs` (which affects manual mode only), `lease_duration_ms` (30000; `start` rejects a lease shorter than 4× the statement deadline) and `shutdown_grace_ms`. The queue is the `Registry`'s queue string. Each registry serves one queue, and an application runs one consumer per queue. The limits are local only.
- **Retries and backoff**: `with_max_attempts` (default 20). `with_retry_policy(retry_policy(fn(RetryFailure(e), RetryContext) -> RetryDecision))` replaces the default, which doubles from 15 s up to a 1-day cap. The policy sees the typed error before the error is erased.
- **Snooze, discard, cancel, uncertain**: `with_queue_handler(fn(i) -> WorkerResponse(o, e))` lets a handler return `WorkerSnoozed(RetryDelay, reason)`, `WorkerDiscarded`, `WorkerCancelled` or `WorkerUncertain`. The default handler adapts the plain `Result`.
- **Scheduling**: `submit_at(..., job.available_at(unix_ms))` takes an absolute Unix-millisecond time only. There is no relative scheduling and no cron.
- **Idempotent admission**: `submit_with_id(db, queue, SubmissionId, worker, input, Availability)` converges a retry on the original `Inserted` result. After `CommitUnknown(pending)`, call `reconcile_unique`.
- **Uniqueness**: `submit_unique(db, queue, id, worker, input, availability, unique.policy(key, scope, period, states), on_conflict)` returns `Inserted`, `Existing(Conflict)` or `Rescheduled(Conflict)`. The policy is passed at each call, not bound to the worker.
- **Operations**: `cancel`, `resolve_uncertain(ResolutionRequest(id, by, details, ConfirmSuccess | ConfirmBusinessFailure | AuthorizeReplay))`, `quarantine_expired(limit:)` and `prune_finished(older_than_ms:, limit:)`. The pruner offers `start` or `supervised` with Oban defaults.
- **Migrations**: `postgres.migrate` applies versions 11 and 12 under an advisory lock. Alternatively, an application applies `priv/migrations/*.sql` through `cigogne.include_lib`. One database must have exactly one migration owner.
- **Extension points**: worker closures, the retry policy and Sinal handlers only. Grind has no plugin interface, middleware or storage port.

## Lifecycle and supervision

- **Database**: `postgres.start` starts Grind's own pog pool under a package supervisor through `pool.start_unlinked` (postgres.gleam:488-508). It returns no `ChildSpecification`, and the caller must call `close` itself.
- **Bring your own pool**: an application cannot pass in its own `pog.Connection` or pool name. `Settings` takes a URL (postgres.gleam:40-50). Grind needs its own pool because it attaches a checkout deadline to the pool and tracks calls for cleanup (Risk 1). Each consumer also opens one reserved renewal connection.
- **Consumer**: `queue.start` returns an opaque `Consumer`, and its supervisor links to the caller (queue.gleam:451, 657). Only the starting process may `stop` it; any other caller gets `ConsumerOwnedByAnotherProcess` (queue.gleam:843-846). There is no `queue.supervised`, so the consumer cannot be placed in an application's `static_supervisor`.
- **Pruner**: `pruner.supervised(database, policy)` returns a `ChildSpecification(Subject(Message))`. `Message` is opaque, so the returned data is unusable (pruner.gleam:151, 262-264).
- **Shutdown order**: the caller stops consumers before closing the database. A consumer whose stop times out leaves its claims to lease expiry and quarantine.
- **Migrations**: the application owns migrations, through an explicit `postgres.migrate` call or cigogne. `start` never migrates or creates a schema.

## Failure model

- **Handler**: returns `Result(output, error)`, or a `WorkerResponse` from the queue handler. A crash or kill becomes `Uncertain` and is never replayed automatically. An operator resolves it.
- **Reading an outcome**: `postgres.outcome` returns `job.Outcome(o, e)`:
  - `Pending(State)` and `SucceededWith(o)`.
  - `BusinessFailedWith(e)` and `BusinessFailedWithCause(e, BudgetExhausted | RetryDeclined)`. These need an error codec.
  - `DiscardedWithReason(String)` and `CancelledWithReason(String)`.
  - `FailedOperationally(String)` and `FailedOperationallyWithCause(String, cause)`.
  - `ReconciliationRequired(String)`.
- **Admission**: `submission.SubmitError` has `EmptyQueueName`, `AdmissionContended`, `SubmissionConflict`, `NotCommitted(pog.QueryError)`, `CommitUnknown(PendingSubmission)` and `CommitUnknownWithoutId(pog.QueryError)`. The last one means plain `submit` may have committed, so a retry may duplicate the job.
- **Reads**: `JobReadError` has query, not-found, route, contract and codec variants. Each function documents which variants it can return.
- **Other operations** each have their own sum type: `CancellationResult` and `CancellationError`, `ResolutionError` (15 variants), `StorageError` for migrations, `QueueRunError`, `ProcessError` (12 variants), `PruneError` and `QuarantineError`.
- Errors are structured throughout, and many carry a raw `pog.QueryError`.

## Composition seams

- **Codecs**: `worker.codec(version, fn(v) -> json.Json, decode.Decoder(v))` uses plain `gleam_json` and `gleam/dynamic/decode`. Grind has no json_blueprint dependency, which matches the design and guideline 35. The codec type is Grind's own. `saga/codec.Codec` uses `String`-returning closures (saga/src/saga/codec.gleam:5-19), and `json/blueprint/codec.Codec` is a third type. A future `saga_grind` integration, or an app that shares one codec value across packages, must write adapters.
- **Calling other packages from a worker**: a worker is a plain `fn(input) -> Result(output, error)` with caller-owned types, so it can call llm_wire, http_gun or saga directly with no adapter. The handler runs in its own temporary process, and the reserved connection keeps its lease renewed. Grind gives the handler no execution timeout, no job id or attempt, and no cancellation signal (worker.gleam:153). A long LLM or HTTP call cannot learn that it was cancelled. The test suite itself works around the missing context with a counter (consumer/test/grind_consumer/support/workers.gleam:111-118).
- **Transactions**: an application cannot enqueue inside its own pog transaction. `submit*` takes `Database`, not `pog.Connection` (postgres.gleam:950-1003). For retry-safe enqueue after the app's own write, use `submit_with_id` with a deterministic `SubmissionId`. That is an outbox-like pattern, not atomicity.
- **pog**: Grind uses pog internally, pinned to `< 4.2`. `pog.QueryError` appears in public errors, so callers compile against pog types. Grind cannot share the application's pool.
- **gleam_otp**: only the pruner has a child spec. Database and Consumer start imperatively, and `stop` has a single-owner constraint.
- **sinal**: lifecycle events in `grind/observation` and operational events in `grind/diagnostic` are typed `sinal.Event` descriptors. A per-Database `sinal/forwarder` emits them, best-effort and only after the commit is proven. Applications attach with `sinal.observe`.
- **Web handlers (wisp)**: any process holding the `Database` value can call `postgres.submit(db, queue, worker, input)`. The handle's `job.id_value` returns an Int. After a restart, `bind_handle(db, worker, id)` re-binds the id to a typed handle.

## Ergonomics concerns

1. **The queue route is a loose string, and the API never relates the two strings.** `registry.new(queue: String)` (registry.gleam:26) and `postgres.submit(database, queue: String, worker, input)` (postgres.gleam:950-955) each take a queue string, and neither the worker nor the API ties them together. A typo or a mismatch admits a job that no consumer will claim, and no error reports it. The design asked for a typed `Queue` route (grind-design.md:116-129) with registration bound to "a full queue route" (grind-design.md:159). The guideline says to derive facts that a definition already owns (PUBLIC-API-GUIDELINES.md:10).
2. **No supervision integration for the two main resources.** `postgres.start` starts unlinked (postgres.gleam:488-508), and `queue.start` links to the caller and allows only the starting process to stop it (queue.gleam:451, 843-846). Neither offers `supervised`. warden (`warden.gleam:173`), fabric and `sinal/forwarder.supervised` all return a `ChildSpecification`, and the design's wiring places `grind.supervised(oban)` in the application tree (grind-design.md:801). Applications cannot bring their own pog pool either. Guideline 40 asks for lifecycle that is verified through an external consumer.
3. **`job.Outcome` hides distinct failures behind strings and duplicates variants.** `FailedOperationally(String)` carries three different persisted states: a business failure with no error codec, `runtime_failed` and `contract_mismatch` (job_reads.gleam:522-546; job.gleam:200-211). A caller can tell them apart only by parsing the description or by calling `state` a second time. The `*With`/`*WithCause` pairs encode an optional cause as separate variants instead of an `Option` field. This conflicts with guideline 27 (types for distinct meanings) and guideline 39 (no diagnostic-string parsing).
4. **Internal erased types appear in public errors.** `QueueRunError.QueueAckUnknown(command_id, proposed: worker.Execution)` and `QueueAckStale(proposed: worker.Execution, ...)` (postgres.gleam:1470-1473) expose the erased JSON-string proposal (worker.gleam:435-445), whose `ExecutedInvalidInput` holds `string.inspect` output (worker.gleam:470). `Execution`, `StoredCodecError` and `CodecKind` are public, not `@internal`, so applications reach implementation state (guideline 31).
5. **Four overlapping admission functions with positional arguments.** `submit`, `submit_at`, `submit_with_id` and `submit_unique` (postgres.gleam:950, 967, 1952, 1872) express availability in two ways: separate functions, or the `submission.Availability` value. `submit_unique` takes 8 positional arguments, and `on_conflict` sits outside `unique.Policy`. One admission value, such as `submission.new(worker, input) |> with_id |> at |> unique(policy)` passed to a single `submit`, would remove these families (guideline 33).
6. **Naming and defaults drift from the siblings.** Grind uses `postgres.settings(url)`, while http_gun, saga and llm_wire use `config(...)`. `queue.default_policy_validated()` and `pruner.default_policy_validated()` duplicate `default_policy() |> validate_policy`. The public records `QueuePolicy`, `Settings` and `PrunerPolicy` also carry a `with_*` setter for every field, which guideline 19 says a record does not need.

Minor: the public modules export many `@internal pub` helpers (job.gleam:49-338, unique.gleam:147-262), and the package root `grind` exports only `version()`.
