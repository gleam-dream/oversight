# checkout — composition feedback

## Verdict

The combination works through public imports. `POST /orders` runs a
three-step saga over pog and two scripted HTTP APIs. Each failure compensates
in reverse. A grind job sends the receipt, and a durable variant runs the same
saga from a grind worker on a Postgres saga storage written in the app. It
survives a killed runner and a killed job. 9 tests pass, and `gleam run`
narrates six orders and their telemetry.

- One brief requirement is blocked: grind cannot use the application's pog
  pool, so the app runs two pools against one database (CHK-1). The same gap
  rules out enqueueing the receipt inside the order transaction, so the app
  uses an outbox (CHK-2).
- Saga's unknown-effect reporting cannot see the payment outcome that
  http_gun reports as unknown (`MayHaveBeenSent`). A typed error is treated as
  a known failure. A crash is reported as unknown, but only after the typed
  failure becomes a rendered Erlang term (CHK-3).
- Glue is about 750 lines across eight seams (see the glue measure). The
  largest pieces are the pog `Storage` adapter (326 lines), the http_gun
  failure codec needed by durable step errors (129), and cross-package
  telemetry correlation (about 75).

## Answers to the brief's questions

- **Can a saga step carry http_gun failure classes without stringifying
  them?** Locally, yes. Step errors are caller-owned, and
  `ProviderUnreachable(provider, error.Failure)` reaches `execution.Failed`
  and `Unresolved` intact. The test
  `shipment_timeout_after_charge_voids_the_charge_test` matches
  `Failure(DeadlineExceeded, MayHaveBeenSent)` and maps it to HTTP 504.
  Durably, the typed value survives only through a 129-line codec, because
  saga persists errors as `String` and http_gun has no serialised form
  (CHK-7). Reporting the effect as unknown to saga requires a crash, which
  stringifies the failure (CHK-3).
- **How much code is a pog-backed saga `Storage`?** 326 lines of code, plus
  an 8-line table. It passes `saga/storage/conformance`. The six SQL
  statements are short. Most of the code is an in-VM owner registry, which
  the contract forces on a database adapter (CHK-4).
- **Can grind insert transactionally with app writes?** No. `submit*` takes
  grind's `Database`, never a `pog.Connection`. The app commits an outbox row
  with the order and then submits it with `submit_with_id`, using an id
  derived from the order. That costs 76 lines and converges on one job after
  a crash between commit and submit (CHK-2).
- **How do saga, grind and http_gun telemetry correlate for one order?** All
  three can be attributed to one order, as the `gleam run` trace shows, but
  no package carries an application correlation value end to end. The app
  keeps a registry with four key kinds. It also attributes durable saga
  events by the process that emitted them, which works only because saga
  emits synchronously from the runner that claimed the storage (CHK-5).

## Findings

### CHK-1 Grind cannot share the application's pog pool

- **Packages**: grind (pog). **Kind**: composition. **Severity**: blocker
  (for brief requirement (b), one pool for the app, grind and saga storage).
- **Evidence**:
  - The app pool serves the order tables and the saga storage
    (apps/checkout/src/checkout/app.gleam:75, :126-134). Grind gets a URL and
    starts a second pool on the same database
    (apps/checkout/src/checkout/app.gleam:79-92). With two consumers that is
    10 + 5 + 2 reserved renewal connections instead of one budget.
  - `postgres.Settings` takes `database_url` only
    (grind/src/grind/postgres.gleam:40-50). `start` builds its own pool
    (grind/src/grind/postgres.gleam:488-508). The card already lists this
    under "Bring your own pool". The new evidence is a running app with two
    pools.
  - The accessor exists but is `@internal`:
    `pub fn connection(database) -> pog.Connection`
    (grind/src/grind/postgres.gleam:1533-1540).
- **Proposal** (grind): make the reverse direction public. Add
  `postgres.connection(database) -> pog.Connection` for application queries
  on grind's pool, which already carries the deadline and cleanup grind
  needs. The app's pool then becomes grind's. Accepting a foreign pool can
  follow once grind's private pgo coupling (RISKS.md risk 1) is gone.

### CHK-2 No transactional enqueue; the receipt needs an outbox

- **Packages**: grind, pog. **Kind**: composition. **Severity**: major.
- **Evidence**:
  - The order confirmation and the outbox row commit together
    (apps/checkout/src/checkout/db.gleam:222-242). `flush_outbox` then submits
    with `SubmissionId("receipt:<order>")`
    (apps/checkout/src/checkout/orders.gleam:249-275), and `app.start` flushes
    leftovers (apps/checkout/src/checkout/app.gleam:178). The test
    `receipt_outbox_survives_a_crash_between_commit_and_submit_test` shows
    that a restart flushes the row and that resubmission returns the same job
    id.
  - `pog.transaction` hands the callback a `pog.Connection`
    (build/packages/pog/src/pog.gleam:428-431), but `submit`/`submit_with_id`
    take `Database` (grind/src/grind/postgres.gleam:950-955, :1952-1959).
    This is a known card item, planned "before 1.0"
    (grind/docs/RELEASE-READINESS.md:107).
- **Proposal** (grind): `postgres.submit_in(database, tx: pog.Connection,
queue, worker, input)` runs the same admission statements on the caller's
  connection and emits `admitted` only after the caller commits. A deferred
  observation is acceptable.

### CHK-3 Saga's unknown-effect report cannot see an HTTP outcome that is unknown

- **Packages**: saga, http_gun. **Kind**: composition. **Severity**: major.
- **Evidence**:
  - The payment step returns `ProviderUnreachable(Payments,
Failure(DeadlineExceeded, MayHaveBeenSent))`. Its decider retries under the
    same provider key, and then holds
    (apps/checkout/src/checkout/workflow.gleam:128-145). In
    `unknown_payment_outcome_is_invisible_to_saga_test`
    (apps/checkout/test/checkout_test.gleam:153-189), the lost first answer
    ends as a plain `Completed`, not `CompletedWithUnknownEffects`, although
    attempt 1's effect was unknown when it ended. The provider saw two
    requests for one charge. The held order ends `Unresolved` with
    `settlement.unknown_effects == []`.
  - Saga records an unknown effect only for `ActionCrashed`,
    `ActionTimedOut` or `ActionInterrupted`
    (saga/src/saga/execution.gleam:245-254). Every `Returned(e)` counts as a
    known result. http_gun's `Evidence` is exactly this distinction
    (http_gun/src/http_gun/error.gleam:3-6).
  - The only way to make saga report the effect is to crash the step.
    `crashing_on_unknown_payment_stringifies_the_failure_test`
    (apps/checkout/test/checkout_test.gleam:192-226) then finds the typed
    failure inside `Crash.reason: String`
    (saga/src/saga.gleam:59-61) as a rendered term,
    `{error,#{function => ..., message => <<"...">>, ...}}`.
- **Proposal** (saga): add one step modifier,
  `saga.uncertain_when(step, fn(e) -> Bool)`, and one
  `UnknownEnding` variant, `ActionReturnedUncertain(error: e)`. This needs
  `UnknownEffect` to be generic in `e`. A returned error that matches the
  predicate is still delivered to the decider as `Returned(e)`, and it is
  also named in `unknown_effects`, so a retried success becomes
  `CompletedWithUnknownEffects`.

### CHK-4 The `Storage` contract forces a database adapter to track processes

- **Packages**: saga, pog. **Kind**: extensibility. **Severity**: major.
- **Evidence**:
  - `apps/checkout/src/checkout/saga_store.gleam` has 326 lines of code. The
    SQL takes about 120 lines (create, load, claim with a VM token and lease,
    conditional commit, release, cancel). The rest is an owner-registry actor
    that maps each execution to its claiming pid and monitor
    (saga_store.gleam:131-192). `commit` and `release` check it before
    touching the row (saga_store.gleam:99-129).
  - The registry is required by the contract, not by Postgres. Conformance
    asserts that "token alone grants no ownership": a commit with the right
    generation from another process must fail
    (saga/src/saga/storage/conformance.gleam:139). It also requires a reclaim
    within 100 × 5 ms after the owner process dies
    (conformance.gleam:318, :337-341). A lease-only database adapter cannot
    meet a 500 ms window without a sub-second lease. Commits must come from
    the claiming process, which is true of `durable.drive` but undocumented.
  - Stringly storage errors and positional `commit(Int, Int, Bool, BitArray)`
    are card items 2 and 3 (saga/src/saga/storage.gleam:11, :23). Every pog
    error here becomes `Io(string.inspect(e))` (saga_store.gleam:358-360).
- **Proposal** (saga): make ownership a value. `claim` returns an opaque
  `storage.Claim` containing the generation and a VM-unique reference, and
  `commit`/`release` take that claim. Give `conformance.run` an
  `owner_loss_within: Int` parameter so lease-based adapters can declare
  their window. Ship the Postgres adapter as `saga_postgres` on pog. With
  those changes, this app's adapter would shrink to its SQL.

### CHK-5 Following one order across packages takes a correlation registry and a process trick

- **Packages**: saga, http_gun, grind, sinal. **Kind**: composition.
  **Severity**: major.
- **Evidence**:
  - The app correlates with four key kinds: `SagaRun(Int)`, `Emitter(Pid)`,
    `HttpCorrelation(Id)` and `GrindJob(Int)`
    (apps/checkout/src/checkout/telemetry.gleam:35-40). Links are resolved at
    query time (telemetry.gleam:156-159).
  - Saga: run metadata is `workflow` plus a per-run integer
    (saga/src/saga/observation.gleam:23-25). A durable run gets a new integer
    on every `drive`, and the app never learns it. The app attributes durable
    events by `process.self()` in the handler (telemetry.gleam:170), linked
    from a hook in its own storage's `claim`
    (apps/checkout/src/checkout/app.gleam:126-134). This works only because
    saga emits synchronously in the claiming runner process.
  - http_gun: `telemetry.Id` is opaque and created only by `new_id()`
    (http_gun/src/http_gun/telemetry.gleam:19-29). The app keeps an order →
    Id map (telemetry.gleam:86-88, :123-138). Lifecycle metadata names no
    route or host (telemetry.gleam:66-73 upstream), so the trace cannot tell
    the charge request from the shipment request.
  - Grind: only `admitted` carries the `submission_id`
    (grind/src/grind/observation.gleam:182-188). The app parses
    `"receipt:<order>"` out of it (telemetry.gleam:229-240) and joins
    `claimed`/`acknowledged` by job id.
- **Proposal**:
  - saga: add `execution_id: Option(String)` (the durable reference id) to
    `RunMetadata`, `StepMetadata` and the stop metadata, and let `execution.start`
    take an optional caller label for local runs.
  - http_gun: add `telemetry.id(String) -> Id`, so an application value can
    be the correlation.
  - grind: repeat `submission_id: Option(String)` in `ClaimedMetadata` and
    `AcknowledgedMetadata`.

### CHK-6 A crashed grind attempt leaves the saga runner alive, and recovery needs an operator

- **Packages**: grind, saga. **Kind**: composition. **Severity**: major.
- **Evidence**:
  - `durable_checkout_after_job_crash_needs_authorised_replay_test`
    (apps/checkout/test/checkout_test.gleam:287-338) kills the grind attempt
    process that called `durable.drive`. The saga runner is still alive 100 ms
    later, with its claim and an HTTP call in flight (test line 308). `drive`
    spawns the runner unlinked (saga/src/saga/durable.gleam:153-177). The
    card names this detachment; this test shows its effect: a crashed job
    keeps advancing the saga with no job attached.
  - After lease expiry, grind marks the job `Uncertain` and never redelivers
    it on its own. The test must call
    `resolve_uncertain(.., AuthorizeReplay)` (test lines 318-326). The saga
    checkpoint makes the replay safe, which the next `drive` proves, but
    grind has no way to know that.
  - In contrast, a killed runner with a live attempt recovers automatically:
    `drive` returns `RunnerLost`, the handler snoozes, and redelivery resumes
    (apps/checkout/src/checkout/jobs.gleam:69-72;
    `durable_checkout_survives_a_killed_runner_test`).
- **Proposal**:
  - saga: add an option for caller loss, `durable.drive(.., on_caller_exit:
StopRunner | Detach)`. `StopRunner` kills the runner and keeps the
    checkpoint; it does not cancel the saga.
  - grind: add a worker declaration such as
    `worker.with_expired_lease(ReplayAutomatically)` for handlers that are
    idempotent by construction.

### CHK-7 http_gun's `Failure` has no serialised form, so durable step errors need a hand-written codec

- **Packages**: http_gun, saga. **Kind**: ecosystem-interop. **Severity**:
  major.
- **Evidence**: `durable.prepare` needs a `Codec(CheckoutError)`, and
  `CheckoutError` contains `error.Failure`. The app writes 129 lines that
  cover `Reason`, `TransportCause`, `LimitKind` and `Evidence`, and drops
  fixture file detail on purpose
  (apps/checkout/src/checkout/codecs.gleam:236-373). http_gun already depends
  on gleam_json (http_gun/gleam.toml:15). Only the one-way `error.describe`
  exists (http_gun/src/http_gun/error.gleam:93).
- **Proposal** (http_gun): add `error.to_json(Failure) -> json.Json` and
  `error.decoder() -> Decoder(Failure)` with stable tags. The saga↔grind
  codec bridge is a further 18 lines (codecs.gleam:22-47; saga card,
  "Codec fragmentation").

### CHK-8 Saga effect keys cannot serve as provider idempotency keys

- **Packages**: saga. **Kind**: ergonomics. **Severity**: minor.
- **Evidence**: The app derives `pay-<order>` and `ship-<order>`
  (apps/checkout/src/checkout/workflow.gleam:38-44). Saga's key is per attempt
  ("Retries receive distinct attempt keys", saga/DURABILITY.md:70). In local
  runs it embeds the run integer (saga/src/saga.gleam:267: "when persistence
  is enabled"). A retry after an unknown outcome therefore gets a new key.
  That is the opposite of what a payment API's `Idempotency-Key` needs.
- **Proposal** (saga): pass `effect` a structured key value,
  `EffectKey(step: String, attempt: Int)`, with `step` stable across retries
  and runs of the same execution. Document which part to send downstream.

### CHK-9 Saga and grind cap `gleam_stdlib < 1.0`

- **Packages**: saga, grind. **Kind**: ecosystem-interop. **Severity**: minor.
- **Evidence**: The app resolves to gleam_stdlib 0.71.0. A probe package
  that asks for `gleam_stdlib >= 1.0.0` (1.0.5 is current) fails:

  ```
  There's no compatible version of `gleam_stdlib`:
    - You require grind 0.1.0
      - grind requires gleam_stdlib >= 0.70.0 and < 1.0.0
    - You require gleam_stdlib >= 1.0.0 and < 2.0.0
  ```

  saga/gleam.toml:11 has the same cap. http_gun and sinal allow `< 2.0.0`.
  `pog` resolves to 4.1.0, the newest release, so grind's `< 4.2` pin does
  not bind today. One app-side mistake cost a rebuild: `mist < 6` pulled
  glisten 8.0.3, which calls the removed `list.range` on stdlib 0.71.

- **Proposal** (saga, grind): widen to `< 2.0.0` as http_gun and sinal did.

### CHK-10 A queue-handler-only grind worker needs a dummy `perform`

- **Packages**: grind. **Kind**: ergonomics. **Severity**: minor.
- **Evidence**: The durable worker answers through `with_queue_handler`
  (snooze, uncertain, cancelled), but `worker.define` still requires
  `perform: fn(input) -> Result(output, error)`
  (grind/src/grind/worker.gleam:162-171). The app passes
  `fn(_order) { Error(Nil) }` (apps/checkout/src/checkout/jobs.gleam:37).
- **Proposal** (grind): `worker.define_responding(id, version, input, output,
handler: fn(input) -> WorkerResponse(output, error))`.

### CHK-11 Lowering grind's statement deadline trips a private margin

- **Packages**: grind. **Kind**: docs. **Severity**: nit.
- **Evidence**: `with_statement_deadline(1500)` fails `validate` with
  `UniqueLockWaitTooCloseToDeadline`. The default 2000 ms lock wait plus a
  private 1000 ms margin (grind/src/grind/postgres.gleam:228, :306) must stay
  below the deadline (apps/checkout/src/checkout/app.gleam:84-86).
- **Proposal** (grind): carry the numbers in the error,
  `UniqueLockWaitTooCloseToDeadline(lock_wait_ms, margin_ms, deadline_ms)`.

## Glue measure

Lines of code, excluding blanks and comments.

| Seam                                                         | Lines | Where                                                       |
| ------------------------------------------------------------ | ----: | ----------------------------------------------------------- |
| Saga `Storage` on pog (owner registry, lease, fencing)       |   334 | saga_store.gleam (326), db.gleam:52-60 (8)                  |
| http_gun `Failure` codec for durable step errors             |   129 | codecs.gleam:236-373                                        |
| Saga ↔ grind codec bridge                                    |    18 | codecs.gleam:22-47                                          |
| Receipt outbox (no transactional enqueue)                    |    76 | db.gleam:44-48, :222-273; orders.gleam:249-275              |
| Grind worker driving durable saga (outcome → response)       |    63 | jobs.gleam                                                  |
| Telemetry correlation (registry, keys, claim hook, wiring)   |   ~75 | telemetry.gleam:35-40, :86-159, :229-240; app.gleam:123-134 |
| Unknown-outcome handling in steps (deciders, key derivation) |   ~45 | workflow.gleam:38-44, :128-160, :198-224                    |
| http_gun loopback destination policy                         |    13 | gateway.gleam:39-54                                         |

The rest (domain, providers, web, the telemetry handlers themselves, and
the order tables) is ordinary application code.

## What worked well

- **One workflow for local and durable runs.** `workflow.define` builds once,
  and the HTTP handler runs it with `execution.start`/`await`. The grind
  worker runs the same value through `durable.prepare`/`drive`. Recovery
  reused saved outputs and reconciled the in-flight shipment by lookup. The
  provider saw one charge and one shipment request across a killed runner and
  a killed job.
- **Saga outcomes map cleanly onto grind responses.** `Unresolved` →
  `WorkerUncertain`, `RunnerLost`/`Busy` → `WorkerSnoozed`, and anything
  else → `WorkerSucceeded` with a summary (jobs.gleam:55-73). A snoozed job
  without an error codec redelivers correctly.
- **Typed failures flowed end to end locally.** http_gun's
  `Failure(DeadlineExceeded, MayHaveBeenSent)` traveled through the saga
  cause to the web layer's 504 without a string
  (apps/checkout/src/checkout/web.gleam:120-131). `Settlement.undone`
  reported reverse-order compensation exactly (`["charge_card",
"reserve_stock"]`).
- **Compensation vocabulary.** `Retry`, `Hold` and
  `AbortAfterCleanupFailure` expressed "retry under the same key, then hold"
  for payments and "cancel what may exist, then abort" for shipping without
  any extra state.
- **http_gun's loopback opt-in felt right.** It is a record update on
  `destination.Policy`, plus an exact-host allowlist (`127.0.0.1`), in one
  13-line function. Per-request deadlines through `request_options` composed
  with the client ceiling as documented. The default refusing loopback is
  the correct default for an app that also takes URLs from users.
- **`submit_with_id` makes the outbox correct.** An order-derived
  `SubmissionId` converged a forced resubmission on the original job. The
  `admitted` event's `submission_id` was the one grind field that tied a job
  to the order.
- **`saga/storage/conformance` is a real gift to adapter authors.** It caught
  the "token alone grants no ownership" rule before any workflow ran.
- **wisp, mist and pog needed nothing special.** Grind using its own schema
  (`with_schema("checkout_jobs")`) kept its migration runner away from the
  app's tables in the shared database.
