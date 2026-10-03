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

**Wave 3:** every blocker is resolved. One pog pool serves the app, grind
and saga_postgres (CHK-1); the receipt and the durable checkout job commit
inside the app's transactions (CHK-2); saga reports the unknown payment
without a crash (CHK-3); the 326-line storage adapter and the 129-line
`Failure` codec are deleted (CHK-4, CHK-7); the correlation registry is gone
(CHK-5); and a crashed job recovers without an operator (CHK-6). 12 tests
pass. `src` shrinks from 2,872 to 2,319 code lines. The remaining glue is a
driver process that lets a handler watch grind's cancellation while
`durable.drive` blocks, and a deadline conversion between grind and saga.
See "Re-run after wave 3".

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

**Status (wave 3):** resolved by grind 749c0dc (one grind facade). `grind.new`
takes the app's `pog.Config` and builds the one pool
(apps/checkout/src/checkout/app.gleam:160); the order tables, saga_postgres
and grind all run on it (`pog.named_connection(pool_name)`, app.gleam:84,
which is what `grind.connection` returns). `db.start_pool` (11 lines), the
`postgres.settings` block (13), the `pool_pid` field and its exit are
deleted: one budget of 10 connections instead of 10 + 5 + 2. One cost: the
pool's `search_path` is grind's schema, so the app dropped
`with_schema("checkout_jobs")` and grind's tables now share `public` with the
app's (see the wave 3 re-run).

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

**Status (wave 3):** resolved by grind 749c0dc (`grind.submit_in`). The order's
confirmation and its receipt job commit in one `pog.transaction`
(apps/checkout/src/checkout/orders.gleam:202-216), and so do the pending
order row and the durable checkout job (orders.gleam:87-106). The outbox is
deleted: its table, `confirm_with_receipt`, `OutboxRow`, `pending_receipts`,
`mark_submitted`, `flush_outbox` and the startup flush, 76 lines. The new
transactional code is 25 lines of ordinary application code (the
transaction and the job builder). The crash-between-commit-and-submit test
is replaced by `receipt_job_commits_with_the_order_test`: a rolled-back
confirmation leaves `grind.state` at `JobNotFound`, and a committed one
leaves one job however often it is resubmitted (`job.with_id`).

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

**Status (wave 3):** resolved by saga f27b628 (`saga.unknown_when`). Both
provider steps mark a `MaybeSent` failure as unknown
(apps/checkout/src/checkout/workflow.gleam:136, :203); the decider still
receives the typed error. `unknown_payment_outcome_is_reported_by_saga_test`
now expects `CompletedWithUnknownEffects` with one
`UnknownEffect(charge_card, StepAttempt(1), ActionReturnedUnknown)` for the
lost answer, and two such effects in the held order's settlement. The crash
test became `unknown_payment_keeps_the_typed_failure_test`: the cause is
`ProviderUnreachable(Payments, error.new(DeadlineExceeded, MaybeSent))`, no
string. The shipment-timeout test now reports `unknown_effects == 1` instead
of 0. +2 lines.

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

**Status (wave 3):** resolved by saga 2ee5e0a (`saga_postgres`) and 1d965bd
(claims as values, id-addressed storage). `checkout/saga_store.gleam` (326
lines) and its 8-line table are deleted; the app wires saga_postgres in 7
lines on the shared pool (apps/checkout/src/checkout/app.gleam:88-89, :140,
:178-179). Conformance now runs against saga_postgres on that pool with a
300 ms lease and `owner_loss_within: lease + 500`
(`saga_postgres_on_the_shared_pool_passes_conformance_test`), so the
"500 ms reclaim" rule no longer forces a sub-second lease on production.

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

**Status (wave 2):** partially resolved by sinal 43279b3 (`sinal/correlation`),
for the shared value only. The app's order key is now a `Correlation` made from
the order id (apps/checkout/src/checkout/telemetry.gleam:70-80), and the web
layer refuses an order id that is not a valid correlation
(apps/checkout/src/checkout/web.gleam:96-104). No package carries the value
yet: saga, http_gun and grind metadata are unchanged at 43ae141, 1dc20a1 and
c1920e6. The registry, all four key kinds, the order → `telemetry.Id` map, the
claim hook and the `process.self()` trick stay. Lines removed: 0 from this
seam; the two `"<kind>:<order>"` parsers became one `from_tagged_id` helper,
which the type change made worth sharing. Lines added: 10 (see the re-run
section). The wave also makes the process trick more fragile: saga now calls
`sinal.emit`, which follows `forwarder.route`
(saga/CHANGELOG.md, "Built on the wave 2 Sinal API"). A
`forwarder.route(["saga"], ..)` anywhere in the VM would move the handlers off
the runner, so `Emitter(process.self())`
(apps/checkout/src/checkout/telemetry.gleam:181) would name the forwarder and
every durable saga event would become unattributed, with no error.

**Status (follow-up):** partially resolved by http_gun 056536b (and sinal
f9cca37 for the shared type); the http_gun clash is gone, the saga and grind
halves are open. `http_gun.with_correlation` takes the order's `Correlation`
(apps/checkout/src/checkout/app.gleam:124), and each http_gun lifecycle event
carries it, so the order → `telemetry.Id` map, the `HttpId` message, the
`http_id` call and the `HttpCorrelation` key are deleted. A new `Order`
key attributes an http_gun event directly
(apps/checkout/src/checkout/telemetry.gleam:40, :143-146, :207-208). The seam goes
from ~85 to ~62 lines (-36 code lines, +13 across `src`, mostly the
registry). Still open: saga attribution by `process.self()` and grind
attribution by parsing `"receipt:<order>"`. The registry keeps three
link kinds (`SagaRun`, `Emitter`, `GrindJob`) plus the new `Order`, so
the proposal's http_gun item (`telemetry.id`) is superseded and its saga
and grind items stand. The wave-2 warning about `forwarder.route` still
applies to `Emitter`.

**Status (wave 3):** resolved by saga 89c1aec and 1d965bd (`execution.with_correlation`,
`durable.with_correlation`, `execution` and `correlation` in every metadata
record), grind 749c0dc (`job.with_correlation`, `JobRef.correlation`) and
sinal c6e2d36 (`correlation.from_key`). Every event is attributed by the
correlation its own package carries
(apps/checkout/src/checkout/telemetry.gleam:99-183). Deleted: the `Key`
type and its four kinds, the links dict and `Link` message,
`from_tagged_id`, the storage claim hook (app.gleam, 8 lines), the
`SagaRun` link in `place_local` (5), the `Emitter(process.self())` trick and
the web-layer correlation check (5; `from_key` cannot fail).
`telemetry.gleam` goes from 224 to 154 code lines; the seam from ~62 to 8
(five `with_correlation` calls and `order`). The wave-2 `forwarder.route`
hazard is gone: nothing depends on which process runs a handler.

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

**Status (wave 3):** resolved by saga 1d965bd (`drive(run, timeout:)` stops its
runner when the caller exits) and grind 749c0dc
(`worker.with_abandonment(ReplayAfterLeaseExpiry(max_replays:))`). The
checkout worker declares replay (apps/checkout/src/checkout/jobs.gleam:61).
`durable_checkout_after_job_crash_replays_without_an_operator_test` kills
the handler process: the runner is dead within 1 s, grind requeues the job
after its lease, and the next claim resumes the saga (one charge, one
shipment request) with no `admin.resolve_uncertain`. The operator replay
(10 lines in the test) is gone. Grind's `worker.cancellation` also reaches a
running checkout now (`durable_checkout_cancelled_through_grind_rolls_back_test`),
at the cost of a driver process (see the wave 3 re-run). New defect: grind
emits no `quarantined` event for a replayed attempt, so `replayed: True` is
unreachable (wave 3 re-run).

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

**Status (wave 2):** open. http_gun 1dc20a1 adds no serialised form
(`error.gleam` still exports only `describe` and `file_description`), and saga
`codec.Codec` and grind `worker.Codec` are unchanged, so both the 129-line
codec and the 18-line bridge stay. json_blueprint 2.0 would not shrink
either. The app does not use Blueprint, and `codec.to_json`/`codec.decoder`
bridge Blueprint to gleam_json, not to saga's or grind's codec type, so the
bridge would keep `to_grind` and `to_saga`. Rewriting the `Failure` codec as a
`codec.union` would need one `use .. <- codec.variant(..)` line and one
`match` arm for each of the 23 `Reason` constructors, a field codec for
`LimitExceeded`, a `codec.custom` for the lossy `FixtureIo`, and the same two
`string_enum` tables. That is not shorter than the current encoder and
decoder, and it adds a dependency. The cure stays in http_gun.

**Status (follow-up):** the grind half of the bridge changed by grind
c44e4be, but nothing shrank. `worker.codec` now takes a fallible encoder, so
`to_grind` wraps the app's plain gleam_json encoder in `worker.infallible`
(apps/checkout/src/checkout/codecs.gleam:32): +1 line, -0. The app never had a
panicking or `null`-storing Blueprint bridge to delete, because it does not use
json_blueprint. The 129-line `Failure` codec and the 18-line (now 18, longer
line) bridge stay, so CHK-7 remains open.

**Status (wave 3):** resolved by http_gun e55fa1d (`error.to_json`,
`error.decoder`). The 129-line codec is two calls
(apps/checkout/src/checkout/codecs.gleam:170, :206), and
`checkout_error_codec_round_trips_http_failures_test` round-trips four
failures, including a status and a `DestinationRejected(HostNotAllowed)`.
saga's `codec.json` and grind's `worker.codec` take the same
`fn(a) -> Result(Json, String)` encoder, so the bridge goes from 18 to 10
lines (codecs.gleam:20-33).

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

**Status (wave 3):** partially resolved by saga f27b628 (`EffectKey.idempotency`,
stable across retries and across restarts of one durable execution). The
app keeps `pay-<order>` and `ship-<order>`
(apps/checkout/src/checkout/workflow.gleam:48-54), because a local run
derives `idempotency` from its run id (saga/src/saga.gleam:84-87): a second
`POST /orders` for the same order is a new run and would charge again. The
order id is the business key across runs; saga has no way to take one. 0
lines removed.

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

**Status (2 Oct 2026):** resolved by grind b2545a9 and saga 26dbc73 (both
now allow `gleam_stdlib < 2.0.0`). `gleam update` resolves gleam_stdlib 1.0.5
with no app change; the app already asked for `< 2.0.0`.

### CHK-10 A queue-handler-only grind worker needs a dummy `perform`

- **Packages**: grind. **Kind**: ergonomics. **Severity**: minor.
- **Evidence**: The durable worker answers through `with_queue_handler`
  (snooze, uncertain, cancelled), but `worker.define` still requires
  `perform: fn(input) -> Result(output, error)`
  (grind/src/grind/worker.gleam:162-171). The app passes
  `fn(_order) { Error(Nil) }` (apps/checkout/src/checkout/jobs.gleam:37).
- **Proposal** (grind): `worker.define_responding(id, version, input, output,
handler: fn(input) -> WorkerResponse(output, error))`.

**Status (2 Oct 2026):** open. grind 7a04831 fixes the error-contract version
but adds no handler-only definition, so `fn(_order) { Error(Nil) }` stays
(apps/checkout/src/checkout/jobs.gleam:37). The app never had an error-codec
workaround to remove: both workers use `worker.define` with `Nil` errors,
because the durable handler answers only `Succeeded`, `Snoozed`, `Uncertain`
or `Cancelled`, and the receipt failure carries nothing worth keeping.

**Status (wave 3):** resolved by grind 749c0dc. `worker.responding(id, input:,
output:, handle: fn(context, input))` needs no `perform`
(apps/checkout/src/checkout/jobs.gleam:51). -1 line.

### CHK-11 Lowering grind's statement deadline trips a private margin

- **Packages**: grind. **Kind**: docs. **Severity**: nit.
- **Evidence**: `with_statement_deadline(1500)` fails `validate` with
  `UniqueLockWaitTooCloseToDeadline`. The default 2000 ms lock wait plus a
  private 1000 ms margin (grind/src/grind/postgres.gleam:228, :306) must stay
  below the deadline (apps/checkout/src/checkout/app.gleam:84-86).
- **Proposal** (grind): carry the numbers in the error,
  `UniqueLockWaitTooCloseToDeadline(lock_wait_ms, margin_ms, deadline_ms)`.

**Status (wave 3):** resolved by grind 749c0dc:
`UniqueLockWaitTooCloseToDeadline(lock_wait_ms:, margin_ms:, deadline_ms:)`.
The constraint stays, so the app keeps `with_unique_lock_wait(250)` and its
comment (apps/checkout/src/checkout/app.gleam:168-170).

## Re-run after wave 3

The heads are grind 008b657, saga 2ee5e0a (with `integrations/saga_postgres`),
http_gun 1a5f5ef and sinal 44c5395. 12 tests pass (9 before). Three are
new: the `Failure` round trip, the destination pin, and cancellation through
grind. Four replace a test of a gap with a test of the correct behavior: the
crash test, the operator replay, the outbox, and the adapter's conformance
(now saga_postgres on the shared pool). They passed three runs in a row. `gleam format` is clean. `gleam run` narrates the six orders, waits for
the durable one with `grind.await` instead of polling the order row, prints
both traces and reports 0 unattributed events. The grind schema is v13
through `grind.migrate`, and saga_postgres's v1 migration runs from
`saga_postgres.migrate` on the same pool (apps/checkout/src/checkout/app.gleam:175-180).

| Seam                                    | Before | After | Change                                                                                                                         |
| --------------------------------------- | -----: | ----: | ------------------------------------------------------------------------------------------------------------------------------ |
| Saga `Storage` on pog (CHK-4)           |    334 |     7 | `saga_store.gleam` and its table deleted; `saga_postgres.config`, `with_lease`, `storage`, `migrate`                           |
| http_gun `Failure` codec (CHK-7)        |    129 |     2 | `error.to_json`, `error.decoder()`                                                                                             |
| Saga ↔ grind codec bridge               |     18 |    10 | `codec.json` and `worker.codec` take the same fallible gleam_json encoder                                                      |
| Receipt outbox (CHK-2)                  |     76 |     0 | `grind.submit_in` in the confirmation's transaction; the durable job is also admitted with its order row                       |
| Second pool (CHK-1)                     |     24 |     0 | `grind.new(pog.Config)`; the app uses the same pool by name                                                                    |
| Telemetry correlation (CHK-5)           |    ~62 |     8 | registry, key kinds, claim hook, `process.self()` attribution, tagged-id parser and web check deleted                          |
| Dummy `perform` (CHK-10)                |      1 |     0 | `worker.responding`                                                                                                            |
| Grind worker driving durable saga       |     63 |   128 | +30 driver process for `worker.cancellation`; +11 deadline → `timeout:`; `error_kind` mapping; Busy snoozes for the saga lease |
| Unknown-outcome handling (CHK-3, CHK-8) |    ~45 |   ~51 | +2 `unknown_when`; +4 shipment undo, needed once cancellation can roll back a finished last step; keys still order-derived     |
| http_gun destination policy             |     13 |    17 | `loopback_only() \|> only_hosts([..])` pins `host:port` of both providers; +7 for an app `authority(url)` helper               |

Code lines in `src` (excluding blanks and comments) go from 2,872 to 2,319
(−553). The test module goes from 323 to 387, for three more tests.

Seams that still need glue:

- **Watching grind's cancellation while saga drives** (saga, 30 lines,
  apps/checkout/src/checkout/jobs.gleam:112-148). `durable.drive` blocks its
  caller, and `worker.cancellation(context)` is a selector on the handler's
  own mailbox (grind/src/grind/worker.gleam:404), so a handler cannot wait
  for both without a second process:

  ```gleam
  let reply = process.new_subject()
  process.spawn(fn() { process.send(reply, durable.drive(run, timeout:)) })
  let driving =
    process.new_selector()
    |> process.select_map(reply, Driven)
    |> process.merge_selector(
      process.map_selector(worker.cancellation(context), fn(_) { CancelRequested }),
    )
  case process.selector_receive(driving, timeout + 1000) {
    Ok(Driven(result)) -> result
    Ok(CancelRequested) -> {
      let _ = durable.cancel(run)
      process.receive(reply, timeout + 1000)
      |> result.unwrap(Error(durable.DriveTimedOut))
    }
    Error(Nil) -> Error(durable.DriveTimedOut)
  }
  ```

  The extra process also moves `drive`'s caller: the runner's parent is now
  the driver, not the handler, so the crash test walks two parents. Proposal
  (saga): `durable.drive_until(run, timeout:, cancel: process.Selector(Nil))`,
  which selects on the caller's selector inside `drive` and records the
  cancellation itself. Severity: minor.

- **Grind's deadline to saga's timeout** (grind or saga, 11 lines,
  jobs.gleam:152-163). `worker.deadline(context)` is an
  `Option(Timestamp)`; `durable.drive` takes `timeout: Int` milliseconds.
  Every grind job that drives a saga computes the difference against the
  system clock. Proposal (grind): `worker.time_left(context) ->
Option(Duration)`; or (saga) let `drive` take a `Duration`. Severity: nit.
- **Order-derived provider keys** (saga, 6 lines). See the CHK-8 status.
- **Pinning the providers' ports** (http_gun, 7 lines,
  apps/checkout/src/checkout/gateway.gleam:60-66). `only_hosts` takes
  `"host:port"` strings, and the app holds base URLs, so it parses each URL.
  Proposal (http_gun): `destination.only_origins(policy, List(String))`
  taking URLs. Severity: nit.

New friction:

- **A killed runner's claim blocks every drive for a whole lease, and
  grind's snooze cap can end the job first** (saga, grind, major). `drive`
  learns the claim (`RunnerClaimed`) and releases it when it times out, but
  on `RunnerDown` it returns `RunnerLost` without releasing
  (saga/src/saga/durable.gleam:711). saga_postgres's lease is 30 s by
  default. The wave-2 handler snoozed every retryable error for 100 ms; with
  grind's new 100-snooze cap, the redelivered job would see `Busy` about 100
  times in 10 s and end `Failed(.., SnoozeLimitReached, ..)` with the saga
  unfinished. The app now snoozes `Busy` for the saga lease
  (apps/checkout/src/checkout/jobs.gleam:99-105), and the killed-runner test
  lowers the lease to 1 s. Two bounded defaults (decision 5) interact here,
  and neither README mentions the other. Proposal (saga): release a claim
  `drive` holds when its runner dies, as on `DriveTimedOut`; and document
  "snooze `Busy` for at least the storage lease" next to `error_kind`.

  **Status (wave 3 fixes):** partially resolved by saga 92612fd; a killed
  runner now releases its claim before `drive` returns `RunnerLost`, so the
  redelivery resumes at once. The killed-runner test keeps the 30 s default
  lease instead of lowering it to 1 s, and asserts the job finishes in under
  10 s. The app's `Busy` snooze stays at the lease
  (apps/checkout/src/checkout/jobs.gleam:41-46): saga's guide says the lease
  remains the fallback when the runner's node is lost, and a shorter snooze
  would meet grind's snooze cap first. Only the doc comment changed.

- **A replayed attempt emits no `quarantined` event** (grind, minor,
  defect). The quarantine scan's `RETURNING job.attempt_id` reads the row
  after the update, and a replay sets `attempt_id = NULL`
  (grind/src/grind/internal/lease.gleam:62-72); `emit_quarantined` then
  skips the row (lease.gleam:217-218). So `QuarantinedMetadata.replayed` is
  never `True`, and the only trace of the replay is a second `claimed` event
  (`attempt=2`). The crash test asserts on the two claims instead. Proposal
  (grind): return the pre-update attempt from the candidate CTE, and add a
  test that a replay emits `quarantined` with `replayed: True`. The second
  claim's `attempt=2` also reads oddly next to `with_max_attempts`'s "a
  replayed lease does not use one".

  **Status (wave 3 fixes):** resolved by grind 6bd06ec. The crash test now
  asserts `job quarantined replayed=True` and two `claimed attempt=1` events
  (a replay no longer uses a business attempt), where it pinned `attempt=2`
  and no `quarantined` event
  (apps/checkout/test/checkout_test.gleam).

- **One pool means one `search_path`** (grind, minor). The pool's
  `search_path` is grind's schema (grind/src/grind.gleam:116-121,
  grind/README.md "One pool"). The wave-2 app kept grind in
  `checkout_jobs`, away from its own tables. Keeping that now means
  schema-qualifying every app statement (13 queries and 4 tables), so the app
  dropped `with_schema` and grind's `grind_*` tables share `public`
  with the app's. The README states it; the cost is that "one pool" and
  "one installation per schema" pull in opposite directions for an app with
  its own tables.

  **Status (wave 3 fixes):** resolved by grind 9ccbfb5. The pool keeps the
  app's `search_path`, so the app's queries stay unqualified and
  `grind.with_schema("checkout_jobs")` is back
  (apps/checkout/src/checkout/app.gleam:170-175). All 13 queries and 4 tables
  are unchanged, and grind's tables are out of `public` again.

- **`submit_in` emits no `admitted` event** (grind, nit). It is documented
  (grind/src/grind.gleam:788-790), because grind cannot see the commit. Both
  of the app's jobs are now admitted that way, so the trace lost its
  `job admitted` lines; the first grind event of an order is `claimed`.
  Proposal (grind): `grind.announce(jobs, admission)` for the caller to call
  after its commit.

  **Status (wave 3 fixes):** partially resolved by grind eb7b173; `submit_in`
  documents the recipe (record the admission after the commit, keyed by
  `job.id(grind.handle(admission))`). The app did not adopt it, so its trace
  still starts at `claimed`. `grind.handle(admission)` replaced the
  three-variant match in `admission_job_id` (-6 lines).- **Cancellation can roll back a finished last step** (saga, docs). The app's
  `book_shipment` had no undo, because a successful last step used to mean a
  completed run. With `grind.cancel` → `durable.cancel`, a shipment booked
  while the cancellation was pending ended the run `Cancelled` with the
  shipment in `settlement.not_undoable` and still booked at the provider.
  The app added an undo (apps/checkout/src/checkout/workflow.gleam:200-202).
  Saga behaves as documented; the durable README could say that a
  cancellation observed after the last step's attempt still rolls that step
  back.

- **A killed handler logs a supervisor report** (grind, nit). Killing the
  handler process prints a `SUPERVISOR REPORT ... reason: killed` from
  grind's handler factory supervisor in the test output.
- **http_gun's default observations reach a client that never asked**
  (http_gun, nit). The demo's and tests' customer client used to emit
  nothing; with `sinal.emit` as the default it would put un-correlated
  events into the collector, so it now needs `config.without_observations`
  (apps/checkout/src/checkout/gateway.gleam:53-57). The migration guide says
  so.

Positive:

- The grind, saga and http_gun guides each had a checkout section that named
  every change this app needed, including the `unknown_payment` test's new
  expectation.
- `grind.named` and `pog.named_connection` make every handle available
  before the runtime starts, so the workers that need the pool could be
  defined before `grind.start` without threading a value.
- `durable.error_kind` replaced the variant match with a five-way decision
  that maps cleanly onto grind responses.
- `grind.await` replaced every poll of a job's state, in the demo and in the
  durable tests.
- `destination.loopback_only() |> destination.only_hosts([..])` expresses
  the payment client's policy, and a refused destination is
  `Kind.Refused`/`NotSent` before any connection
  (`payment_client_refuses_public_and_unpinned_hosts_test`).

### After the follow-up fixes

All 12 tests pass three runs in a row, `gleam format` is clean, and `gleam run`
reports 0 unattributed events. `src` loses 15 code lines and gains 7 (net -8);
the test module goes from 485 to 511 lines. Removed: the `let assert Ok` around
`saga.define` and `durable.new`, `durable.new`'s `version: "1"`, the
three-variant `admission_job_id` match, the `pool` parameter of
`receipt_worker` (its handler reads `worker.connection(context)`), and the
`grind.migrate` call after `grind.start`. Added: `grind.with_schema` and
`grind.with_startup_migration`.

- **Startup order** (grind 9ccbfb5): `grind.with_startup_migration` replaces
  `start` then `migrate`. The app's own tables and saga_postgres's migration
  still run after `start`, on grind's pool, because no consumer reads them
  before a job is submitted.
- **Unknown effects** (saga 92612fd): the CHK-3 test
  `unknown_payment_keeps_the_typed_failure_test` pinned `Failed(StepFailed(..))`
  for a step with `unknown_when` and no decider. That ending is now
  `Unresolved` with nothing undone. The test asserts it, and asserts the old
  ending through `saga.on_unknown(_, saga.RollBack)`. The app's payment and
  shipment deciders decide every unknown error themselves, so the order tests
  did not change.
- **`execution.describe_cause`** takes `error: domain.describe_error` (1 site).
- Not adopted: `grind.connection(grind.named(..))` was never in a worker (the
  workers read the pool from `Services`); only the receipt worker moved to
  `worker.connection`.

## Re-run after the follow-up fixes

The heads are grind 2d66835, http_gun 056536b and sinal 6de2b69. All 9 tests
pass, `gleam format` is clean, and `gleam run` narrates the six orders, prints
both traces and reports 0 unattributed events. Compile errors came from two
places: `codecs.gleam` (`worker.codec` encoder type) and `telemetry.gleam`
(`telemetry.Id`, `new_id`, removed by http_gun).

| Seam                                    | Before | After | Change                                                                                                                              |
| --------------------------------------- | -----: | ----: | ----------------------------------------------------------------------------------------------------------------------------------- |
| Telemetry correlation (CHK-5)           |    ~85 |   ~62 | `http_ids` map, `HttpId` message and handler arm, `http_id`, `HttpCorrelation` key and `client_for` call deleted; `Order` key added |
| Saga ↔ grind codec bridge (CHK-7)       |     18 |    18 | `worker.infallible(c.encode)`: one expression longer, no line change; no panic or `null` to delete                                  |
| Sinal record builder                    |      0 |     0 | The app only reads events (`sinal.observe`); it defines no `fields` records, so there is no builder or getter to move               |
| `Option` correlation (`required_field`) |      0 |     0 | The app defines no events; it reads http_gun's, which use `field()`                                                                 |

Code lines across `apps/checkout/src` (excluding blanks and comments):
-36 / +13, net -23. About 28 of the removed lines are the http_gun id join
table; the rest is reflow by `gleam format`.

New friction:

- **The reader still handles `Option(Correlation)` for http_gun** (http_gun,
  nit). `metadata.correlation` is optional because the client may have no
  correlation. The app sets one on every request through `client_for`, but the
  handler still carries a `Some`/`None` arm
  (apps/checkout/src/checkout/telemetry.gleam:207-208). The `None` arm is
  reachable only for a request made without `client_for`, which the app does
  not do. `required_field()` cannot help, because the field belongs to
  http_gun's metadata type, not the app's.
- **`telemetry.order` still asserts** (sinal, minor). `correlation.from_string`
  returns a `Result`, so the app keeps its `let assert` plus the web-layer
  check (apps/checkout/src/checkout/telemetry.gleam:66). Passing the
  `Correlation` to http_gun removed the join table but not this precondition.
- **Correlation now crosses one package of three** (saga, grind, nit). The
  `Order` key makes the http_gun half trivial and the saga and grind halves
  look worse in comparison: they still need `Emitter(Pid)` and a parser for
  the submission id. The app now has two attribution styles in one collector.
- **The `worker.infallible` wrap is mandatory churn for plain encoders**
  (grind, nit). An app that never rejects a value gets a one-word migration
  and no new capability; `JsonCodec.encode` could hold a `Result` encoder, but
  that would add noise to the app's encoders for no failure they can raise.

Positive: the migration guides named the exact before and after for both
changes, and the http_gun guide's "match `metadata.correlation` against it"
advice worked as written. The wave-2 guide gap (present-tense `Correlation`
in `with_correlation` before it existed) is closed.

## Glue measure

Lines of code, excluding blanks and comments.

| Seam                                                         | Lines | Where                                                                                      |
| ------------------------------------------------------------ | ----: | ------------------------------------------------------------------------------------------ |
| Saga `Storage` on pog (owner registry, lease, fencing)       |   334 | saga_store.gleam (326), db.gleam:52-60 (8)                                                 |
| http_gun `Failure` codec for durable step errors             |   129 | codecs.gleam:236-373                                                                       |
| Saga ↔ grind codec bridge                                    |    18 | codecs.gleam:22-47                                                                         |
| Receipt outbox (no transactional enqueue)                    |    76 | db.gleam:44-48, :222-273; orders.gleam:249-275                                             |
| Grind worker driving durable saga (outcome → response)       |    63 | jobs.gleam                                                                                 |
| Telemetry correlation (registry, keys, claim hook, wiring)   |   ~75 | telemetry.gleam:35-40, :86-159, :229-240; app.gleam:123-134                                |
| Unknown-outcome handling in steps (deciders, key derivation) |   ~45 | workflow.gleam:38-44, :128-160, :198-224                                                   |
| http_gun loopback destination policy                         |    13 | gateway.gleam:39-54 (unchanged on 2 Oct: `config.allow_loopback` cannot keep the host pin) |

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

## Re-run after fixes (2 Oct 2026)

`gleam update` on the new heads (grind b2545a9, saga 26dbc73, http_gun
a2869b7) resolved gleam_stdlib 1.0.5 (was 0.71.0). It also moved gleeunit
1.11.0, glisten 9.0.1, gramps 6.0.1 and mist 6.0.3. All 9 tests pass, and
`gleam run` narrates the six orders and the trace with no unattributed
events.

| Seam                                 | Before | After | Change                                                                                |
| ------------------------------------ | -----: | ----: | ------------------------------------------------------------------------------------- |
| http_gun loopback destination policy |     13 |    13 | kept: `config.allow_loopback` cannot also pin `allowed_hosts` and refuse public hosts |
| gleam_stdlib resolution (CHK-9)      |      0 |     0 | No app glue existed; the manifest now resolves stdlib 1.0.x                           |
| Dummy `perform` (CHK-10)             |      1 |     1 | Unchanged; no handler-only definition yet                                             |

Other seams are unchanged: CHK-1 to CHK-8 and CHK-11 stay open. The
`request_options.Options` field addition needed no change, because
`gateway.gleam` already builds options with a record update from
`request_options.default()`.

New friction: `config.allow_loopback` only sets `allow_loopback: True`. The
original policy also pinned `allowed_hosts: Some(["127.0.0.1"])` and set
`allow_public: False`. Keeping that pin still needs the nested
`destination.Policy` record update. The app keeps that update, because a
payment client must not reach hosts outside its allowlist. A
`config.allow_only_hosts(config, List(String))` helper (http_gun) would let
an app keep both in one pipeline. Severity: minor.

## Re-run after wave 2

The heads are sinal a0c05ef, saga 43ae141, grind c1920e6 and http_gun
1dc20a1. The app does not use json_blueprint. All 9 tests pass. `gleam run`
narrates the six orders, prints both traces and reports 0 unattributed
events. Compile errors on the new heads came only from
`apps/checkout/src/checkout/telemetry.gleam` (`sinal.handler_id`, the
three-argument `observe`). `forwarder.new(name, 1024)` also changed.

| Seam                                                               | Before | After | Change                                                                                                                             |
| ------------------------------------------------------------------ | -----: | ----: | ---------------------------------------------------------------------------------------------------------------------------------- |
| Handler ids (helper, random per-collector suffix, `result.values`) |     11 |     0 | `sinal.observe(event, run)` returns an `Attachment`; automatic ids remove the suffix that kept test collectors apart               |
| Forwarder construction                                             |      2 |     2 | `let assert Ok(..) = forwarder.new(name, 1024)` → `forwarder.new(name)`; 1024 is now `default_capacity`                            |
| Telemetry correlation (CHK-5)                                      |    ~75 |   ~85 | The order key is a `Correlation`: `order` and `from_tagged_id` (8), the web check (5), wrapped call sites (+3), shared parser (−6) |
| http_gun `Failure` codec (CHK-7)                                   |    129 |   129 | Unchanged; no upstream serialised form                                                                                             |
| Saga ↔ grind codec bridge (CHK-7)                                  |     18 |    18 | Unchanged; both codec types are unchanged                                                                                          |

Code lines across `src` and `test` (excluding blanks and comments) go from
3,219 to 3,218. The handler-id glue that was removed is offset by the
correlation glue that was added. Other seams (CHK-1 to CHK-4, CHK-6, CHK-8,
CHK-10, CHK-11) are unchanged.

New friction:

- **Adopting `Correlation` before packages carry it costs lines and buys
  nothing yet** (sinal, minor). `from_string` returns a `Result`, so an id
  from the request needs a validation point and every other use needs a
  `let assert` or a fallback:

  ```gleam
  // telemetry.gleam:70: a precondition the web layer has to uphold
  pub fn order(order_id: String) -> Correlation {
    let assert Ok(order) = correlation.from_string(order_id)
    order
  }

  // web.gleam:100: the new validation point
  correlation.from_string(order.order_id)
  |> result.replace(order)
  |> result.replace_error(Nil)
  ```

  This is the right type, and the 128-byte bound is a reasonable thing to
  refuse at the edge. The payoff depends on the other waves. With
  `http_gun.with_correlation(client, Correlation)`, the `http_ids` map, the
  `HttpId` message and `http_id` (about 20 lines) disappear. With saga and
  grind metadata carrying `correlation`, the `Key` type, the claim hook and
  the submission-id parsing disappear too.

- **Routing makes the saga process trick fail silently** (sinal and saga,
  minor). See the CHK-5 status. `forwarder.route` is VM-global, so a library
  or test that routes `["saga"]` changes which process runs the app's
  handlers. Until saga carries an execution id, CHK-5's proposal is the only
  robust fix.
- **Three delivery models remain** (http_gun, grind, nit). Saga emits with
  `sinal.emit` and can now be routed. Grind emits into its own forwarder.
  http_gun still emits only into the forwarder the app passes in
  (`client_config(Some(forwarder))`); with `None` it emits nothing, so the app
  cannot use `forwarder.route(["http_gun"], ..)` instead of the explicit
  forwarder.

Positive: `sinal.observe(event, run)` reads better than before. The eleven
attachments are now one list of plain calls, and the random suffix existed
only because handler ids were global and tests start several collectors.

Migration guides: the sinal guide was sufficient for every compile error;
its `handler_id` and `forwarder.new` examples are this app's own code. Two
gaps:

- It says "http_gun replaces `telemetry.Id` as the cross-package key with
  `Correlation` (HTTPGUN-R8)" in the present tense. At 1dc20a1, http_gun still
  takes `telemetry.Id` in `with_correlation`, so an app reading the guide
  would look for an API that does not exist yet.
- It does not say how an application should use `Correlation` while its
  packages do not carry it. It does not say where to validate an untrusted
  id, or whether to keep an app-side registry.

The json_blueprint guide does not apply; see the CHK-7 status for why
adopting json_blueprint would not shrink this app's codecs.

## Re-run after wave 4 (Duration)

http_gun dcfbc07. Tests: 12 passed. `gleam run` completes with no unattributed
events. `gleam format --check` is clean.

Removed (2 lines): `config.Milliseconds(5000)` and the bare
`deadline.after(deadline_ms)`. Added (3 lines):
`config.After(duration.seconds(5))`,
`deadline.after(duration.milliseconds(deadline_ms))` and the
`gleam/time/duration` import in `gateway.gleam`. `gleam.toml` raises
`gleam_time` to `>= 1.11.0` (the guide's floor; `manifest.toml` re-resolved).

Friction:

- The guide says grind and saga "already use" `Duration`. That holds for grind
  and for `saga_postgres.with_lease`, but not for the call this app converts
  for. `durable.drive(run, timeout: Int)` (saga `durable.gleam:703`) still
  takes milliseconds, so the conversion glue in `jobs.gleam` stays:
  `budget` turns grind's deadline into `duration.to_milliseconds`, and
  `drive_until_cancelled` adds `+ 1000` to that `Int` for the two receives.
  `execution.with_step_timeout(10_000)` and `Config.saga_lease_ms` are also
  `Int`. The glue can only go once saga takes a `Duration`.
- `Gateway.payment_deadline_ms` and `shipping_deadline_ms` are the app's own
  `Int` fields and still convert at the one `deadline.after` call. I left
  them: the guide's row for this app asks only for that conversion, and
  retyping them would also change `app.Config` and the test that sets
  `shipping_deadline_ms: 5000`.

### Saga af644b0 (`Duration` for every timeout)

Tests: 12 passed. `gleam run` completes with no unattributed events.
`gleam format --check` is clean.

Removed:

- `jobs.gleam`: `const attempt_budget_ms = 60_000`; `import gleam/int`;
  `budget(..) -> Int` with `duration.to_milliseconds` and
  `int.max(left - 5000, 1)`; `timeout: Int`, `timeout + 1000` (twice) and
  `duration.milliseconds(attempt_budget_ms + 5000)`.
- `app.gleam`: `saga_lease_ms: Int`, `grind_lease_ms: Int`,
  `payment_deadline_ms: Int`, `shipping_deadline_ms: Int` (and their
  defaults `30_000`, `6000`, `300`, `300`); `with_step_timeout(10_000)`;
  `duration.milliseconds(config.saga_lease_ms)` and
  `duration.milliseconds(config.grind_lease_ms)`.
- `gateway.gleam`: `payment_deadline_ms: Int`, `shipping_deadline_ms: Int`,
  `deadline_ms: Int` and `duration.milliseconds(deadline_ms)`.
- `orders.gleam`: `execution.await(run, 60_000)`.
- `checkout_test.gleam`: `shipping_deadline_ms: 5000` (x3), `lease = 300`,
  `timeout: 10_000`, `lease + 500`.

Added:

- `jobs.gleam`: `fn attempt_budget() -> Duration` (`duration.seconds(60)`);
  `budget(..) -> Duration` (`duration.subtract(.., duration.seconds(5))`,
  floored at 1 ms with `duration.compare`, plus `import gleam/order`);
  `timeout: Duration` passed straight to `durable.drive`; one
  `wait = to_milliseconds(add(timeout, seconds(1)))` for the two receives,
  because `process.selector_receive` and `process.receive` still take an
  `Int`.
- `app.gleam`: `Duration` fields `payment_deadline`, `shipping_deadline`,
  `saga_lease`, `grind_lease` (`milliseconds(300)` x2, `seconds(30)`,
  `seconds(6)`); `execution.After(duration.seconds(10))`;
  `config.saga_lease` and `config.grind_lease` passed as they are.
- `gateway.gleam`: `payment_deadline: Duration`, `shipping_deadline:
Duration`, `limit: Duration`; `deadline.after(limit)`.
- `orders.gleam`: `duration.seconds(60)` and the `gleam/time/duration` import.
- `checkout_test.gleam`: `shipping_deadline: duration.seconds(5)` (x3),
  `lease = duration.milliseconds(300)`, `timeout: duration.seconds(10)`,
  `owner_loss_within: duration.add(lease, duration.milliseconds(500))`.

Friction: the Int-to-`Duration` conversion between grind and saga is gone,
but one `to_milliseconds` remains at the `gleam/erlang/process` receive
calls. The migration note says the `+ 1000` moves onto a `Duration`; it
cannot reach the receive without that conversion.
