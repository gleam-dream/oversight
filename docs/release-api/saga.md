# saga — release API review

Reviewed 2 October 2026 at saga `26dbc73` against the [design](../../saga-design.md),
the [API card](../composition/scan/saga.md), [FEEDBACK.md](../composition/FEEDBACK.md)
and the app findings. "Probe" marks a claim checked in a scratch consumer.

## 1. Verdict

The local path is nearly release-ready: two imports run a typed saga with
undo, compensation, settlement and unknown-effect reporting, and its outcome
vocabulary is precise. The durable path and the storage extension point are
not ready, because a repeated `(storage, reference, persistence)` triple,
positional codecs, string errors, an unbounded `drive` and a process-owned
`Storage` contract make them easy to misuse. The largest correctness gap is
that a returned "maybe sent" error counts as a known result (CHK-3, SD-1),
and the release also lacks rendered module docs, correlation in events and
supervision for the adapter process.

## 2. First ten minutes

### Local run (the main job)

Today (probe; compiles at `26dbc73`):

```gleam
import saga
import saga/execution

let assert Ok(workflow) =
  saga.define("checkout", fn(order) {
    let reserve_step =
      saga.step("reserve", reserve) |> saga.undo(fn(_order, hold) { release(hold) })
    let charge_step =
      saga.step("charge", charge)
      |> saga.compensate(max_attempts: 3, with: fn(_order, failure, _attempt) {
        case failure {
          saga.Returned(error) -> saga.Abort(error)
          _ -> saga.RetryAfter(100)
        }
      })
    saga.both(saga.perform(order, reserve_step), saga.perform(order, charge_step))
  })
case execution.run(workflow, "o-1", execution.config()) {
  Ok(execution.Completed(pair)) -> Ok(pair)
  Ok(other) -> Error(execution.unknown_effects(other))
  Error(_run_error) -> Error([])
}
```

Proposed (same imports and structure; only the changed lines are shown):

```gleam
      saga.step("reserve", reserve) |> saga.undo(fn(undo) { release(undo.output) })
      saga.effect("charge", fn(order, key) { charge(order, key.idempotency) })
      |> saga.unknown_when(is_maybe_sent)
      |> saga.compensate(max_attempts: 3, with: fn(failed) {
        case failed.failure {
```

Counts, today → proposed: 2 → 2 imports and modules, 4 → 4 saga types
named, 11 → 12 calls, 3 → 0 ignored callback parameters. The local path needs
no structural change. R6 changes the callback shapes, and R1 adds the
evidence modifier the apps needed.

### Durable run (where newcomers struggle)

Today (`DURABILITY.md` "Example"; probe):

```gleam
import saga
import saga/codec
import saga/durable
import saga/execution
import saga/storage/memory

let text = codec.text()
let action =
  saga.effect("charge", fn(order, key) { charge(order, key) })
  |> saga.undo_effect(fn(order, receipt, key) { refund(order, receipt, key) })
  |> saga.recoverable("1", text, text, fn(order, key) { lookup_charge(order, key) })
  |> saga.reconcile_undo(fn(order, receipt, key) { lookup_refund(order, receipt, key) })
let assert Ok(workflow) = saga.define("checkout", fn(input) { saga.perform(input, action) })
let assert Ok(persistence) = durable.prepare(workflow, "1", text, text, text, text)
let memory = memory.new()
let storage = memory.storage(memory)
let assert Ok(reference) =
  durable.start_or_reconnect(storage, "checkout-123", persistence, "order-123")
let outcome = durable.drive(storage, reference, persistence, execution.config())
let saved = durable.read(storage, reference, persistence)
memory.close(memory)
```

Proposed:

```gleam
import saga
import saga/codec
import saga/durable
import saga/storage/memory

let text = codec.text()
let action =
  saga.effect("charge", fn(order, key) { charge(order, key.idempotency) })
  |> saga.undo(fn(undo) { refund(undo.input, undo.output, undo.key.idempotency) })
  |> durable.recoverable(version: "1", input: text, output: text, resolve: lookup_charge)
  |> durable.resolve_undo(lookup_refund)
let assert Ok(workflow) = saga.define("checkout", saga.perform(_, action))
let assert Ok(persistence) =
  durable.new(workflow, version: "1", input: text, output: text, error: text, undo_error: text)
let assert Ok(store) = memory.start()
let assert Ok(run) =
  durable.start_or_reconnect(persistence, memory.storage(store), id: "checkout-123", input: "order-123")
let outcome = durable.drive(run, timeout: 30_000)
let saved = durable.read(run)
memory.stop(store)
```

Counts, today → proposed: 5 → 4 imports, 15 → 14 calls, 3 → 0 calls
repeating storage, reference and persistence, 8 → 0 unlabeled same-type
arguments (6 in `prepare`, 2 in `recoverable`), 1 → 0 unbounded waits. The
probe confirmed two traps. `map_step_errors` after `recoverable` silently
drops the codecs, and `prepare` then fails with
`InvalidDefinition("step requires persistence codecs: charge")`. A second id
on the same `Storage` fails with `ReferenceMismatch`, because a storage value
addresses one execution.

## 3. Target surface

| Module                     | Disposition                                                       | Key types                                                                                                                                                                                 | Key functions                                                                                                                                                                                                                          |
| -------------------------- | ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `saga`                     | keep, slimmed                                                     | opaque `Workflow`, `Step`, `Port`; records `StepAddress`, `Crash`, `StepDescriptor`, `EffectKey`, `FailedAttempt`, `UndoRequest`; `Recovery`, `Undo`, `AttemptFailure`, `DefinitionError` | `step`, `effect`, `undo`, `compensate`, `timeout`, `unknown_when`, `map_step_errors`, `perform`, `map`, `both`, `all`, `choose`, `embed`, `define`, `map_errors`, `name`, `describe`, `address_to_string`, `describe_definition_error` |
| `saga/execution`           | keep                                                              | opaque `Config`, `Execution`; records `Settlement`, `UnknownEffect`, `Progress`, `StepProgress`; `Outcome`, `Cause`, `RunError`, `AwaitError`, `OutcomeKind`                              | `config`, 8 `with_*`/`without_step_timeout`, `run`, `start`, `start_reporting`, `await`, `cancel`, `progress`, `unknown_effects`, `kind`, `describe_cause`, `pid`, `run_id`                                                            |
| `saga/durable`             | keep; absorbs `reconciliation` and the step persistence modifiers | opaque `Persistence`, `Run`; `Error`, `ErrorKind`, `Evidence`, `Status`; record `Required`                                                                                                | `new`, `with_config`, `recoverable`, `restore_undo`, `resolve_undo`, `resolve_compensation`, `start_or_reconnect`, `drive`, `read`, `cancel`, `id`, `error_kind`, `describe_error`                                                     |
| `saga/codec`               | keep, JSON-first                                                  | opaque `Codec`; `CodecError`                                                                                                                                                              | `json`, `new`, `text`, `bool`, `int`                                                                                                                                                                                                   |
| `saga/storage`             | keep, opaque contract                                             | opaque `Storage`, `Claim`, `Stored`; record `Commit`; `Error`                                                                                                                             | `new`, `claim`, `claim_generation`, `stored`, `describe_error`                                                                                                                                                                         |
| `saga/storage/memory`      | keep                                                              | opaque `Memory`                                                                                                                                                                           | `start`, `supervised`, `storage`, `stop`                                                                                                                                                                                               |
| `saga/storage/file`        | keep                                                              | none                                                                                                                                                                                      | `open`                                                                                                                                                                                                                                 |
| `saga/storage/conformance` | keep                                                              | opaque `Fixture`; `Failure`                                                                                                                                                               | `fixture`, `run`                                                                                                                                                                                                                       |
| `saga/telemetry`           | rename of `saga/observation`                                      | metadata records with `correlation` and `execution`; 4 kind enums                                                                                                                         | the same 6 event descriptors                                                                                                                                                                                                           |
| `saga/testing`             | keep                                                              | `WaitError`                                                                                                                                                                               | `wait_until`                                                                                                                                                                                                                           |
| `saga/reconciliation`      | delete; merged into `durable`                                     | none                                                                                                                                                                                      | none                                                                                                                                                                                                                                   |

Hidden or deleted: `saga.CrashOrTimeout` (in no public signature,
`saga.gleam:247`); the `execution.Crash` and `execution.StepAddress` aliases
(`execution.gleam:133-137`); `execution.validate` (`start`, `run` and `drive`
validate); `codec.encode`/`decode`/`version` (`@internal`); `undo_effect` and
`compensate_with_key` (R6); `saga.Attempt` (fields move into
`FailedAttempt`); `EffectStatus` and `UndoStatus` (merged into
`durable.Evidence`, R9).

| Count                   | Before | After | Main changes                                                                                                                                            |
| ----------------------- | -----: | ----: | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Public modules          |     11 |    10 | `reconciliation` merged                                                                                                                                 |
| Public functions        |     58 |    76 | +8 config setters, +5 `describe`/`kind`, +5 storage constructors, adapter lifecycle; −`undo_effect`, `compensate_with_key`, `validate`, 3 codec helpers |
| Public records          |     23 |    22 | −`Config`, `Storage`, `Record`, `Fixture`, `Attempt`; +`EffectKey`, `FailedAttempt`, `UndoRequest`, `Commit`                                            |
| Opaque types            |      8 |    13 | +`Config`, `Storage`, `Claim`, `Stored`, `Fixture`; `Run` replaces `Reference`                                                                          |
| Public unions and enums |     32 |    34 | +typed error details (`CodecError`, `PersistenceProblem`, `Boundary`, `CheckpointProblem`, `ErrorKind`, `Evidence`); −4                                 |

Only setters, classifiers and adapter constructors add functions; the
ordinary path is unchanged.

## 4. Proposals

### SAGA-R1 Count returned "maybe sent" errors as unknown effects

- **Problem.** Only a crash, timeout or interruption is unknown
  (`execution.gleam:245-254`). A retried `MayHaveBeenSent` charge ends as
  plain `Completed`, and a held order reports `unknown_effects == []`
  (CHK-3). Crashing instead renders the typed error as an Erlang term
  (`saga.gleam:59-61`), and fabric_saga reports a refund the provider took
  as a clean failure (SD-1, theme 3).
- **Sketch.**

  ```gleam
  pub fn unknown_when(step: Step(i, o, e, u), classify: fn(e) -> Bool) -> Step(i, o, e, u)
  // execution.UnknownEnding gains ActionReturnedUnknown (no payload)
  ```

  A matching error still reaches the decider as `Returned(e)`. It is also
  named in `unknown_effects`, so a retried success becomes
  `CompletedWithUnknownEffects`.

- **Breaks:** exhaustive matches on `UnknownEnding` (do it before release).
  **Effort:** M, including the durable restart rule (open question 1).

### SAGA-R2 One durable handle, labeled preparation, storage addressed by id

- **Problem.** `read`, `cancel` and `drive` each take
  `(storage, reference, persistence)` (`durable.gleam:125-157`), and
  `start_or_reconnect` takes an `id` the per-execution `Storage` already
  fixes (`:101`; RA-6; probe). `prepare`'s four positional codecs swap
  silently when types match (`:69`). Pool-backed adapters build one
  `Storage` per execution (`apps/checkout/src/checkout/jobs.gleam:50`).
- **Sketch.**

  ```gleam
  pub opaque type Run(i, o, e, u)   // persistence + storage + id
  pub fn new(workflow, version version: String, input input: Codec(i), output output: Codec(o),
             error error: Codec(e), undo_error undo_error: Codec(u)) -> Result(Persistence(i, o, e, u), Error)
  pub fn start_or_reconnect(persistence, storage: Storage, id id: String, input input: i) -> Result(Run(i, o, e, u), Error)
  pub fn drive(run, timeout timeout: Int) -> Result(execution.Outcome(o, e, u), Error)
  ```

  `read(run)`, `cancel(run)` and `id(run)` take only the handle, and
  `with_config` replaces the per-call `execution.Config`. Storage operations
  take the execution id, so one store serves a pool, as in `fabric_postgres`.

- **Breaks:** every durable caller (two apps) and every adapter.
  **Effort:** M.

### SAGA-R3 Make storage ownership a value and the contract opaque

- **Problem.** Conformance requires process ownership ("token alone grants
  no ownership", `storage/conformance.gleam:139`) and a reclaim within
  100 × 5 ms of owner death (`:318`, `:337-341`). Database adapters therefore
  keep an in-VM owner registry: 326 lines in checkout, 262 with pid FFI in
  research_agent (CHK-4, RA-6, theme 2). The file adapter keeps ownership
  in the process dictionary (`saga_storage.erl:73-104`), an undocumented
  same-process rule. `commit: fn(Int, Int, Bool, BitArray)` takes bare
  `Int`s (`storage.gleam:23`), and adapters construct the public `Storage`
  and `Record` records, so a new operation breaks them all.
- **Sketch.**

  ```gleam
  pub opaque type Storage
  pub opaque type Claim   // generation + adapter lease token
  pub type Commit { Commit(expected_revision: Int, observed_cancelled: Bool, data: BitArray) }
  // labeled: create(id, bytes), load(id), claim(id) -> #(Claim, Stored),
  // commit(Claim, Commit) -> Stored, release(Claim), cancel(id)
  pub fn new(create create, load load, claim claim, commit commit, release release, cancel cancel) -> Storage
  // conformance
  pub fn run(fresh, timeout timeout: Int, owner_loss_within owner_loss_within: Int) -> Result(Nil, Failure)
  ```

  `Io(String)` becomes `Unavailable(detail)` plus `TimedOut`; the detail is
  diagnostic only. Ship `saga_postgres` on pog, checked by the suite.

- **Breaks:** the memory and file adapters and both app adapters (which
  shrink to their SQL). **Effort:** L.

### SAGA-R4 Bound `drive`; stop the runner when its caller dies

- **Problem.** `drive` spawns an unlinked runner and waits with
  `selector_receive_forever` (`durable.gleam:164, 177`). A grind job timeout
  only detaches the runner. A killed attempt leaves the runner holding its
  claim, with an HTTP call in flight (CHK-6, theme 4).
- **Sketch.** `drive(run, timeout: Int)` links the runner to the caller. On
  timeout or caller exit, it stops the runner, keeps the last checkpoint and
  releases the claim. This is not cancellation: the next `drive` resumes. A
  `drive_detached` variant only if open question 4 needs one.
- **Breaks:** the signature. **Effort:** M.

### SAGA-R5 JSON codecs and typed durable errors with a stable classification

- **Problem.** `Codec` is `String` closures with `String` errors
  (`codec.gleam:5-19`), so every app bridged gleam_json (CHK-7, RA-8,
  theme 6). `InvalidDefinition`, `CodecFailure` and `InvalidCheckpoint`
  carry strings callers branch on (`durable.gleam:16-28`);
  `InvalidDefinition` merges three problems (`saga.gleam:1795-1871`).
  `Required.step` is a rendered `String` (`reconciliation.gleam:10`). With
  no `describe`, checkout uses `string.inspect(error)` (`jobs.gleam:72`).
- **Sketch.**

  ```gleam
  // codec
  pub fn json(version: String, encode: fn(a) -> json.Json, decoder: decode.Decoder(a)) -> Codec(a)
  // CodecError: EncodeFailed(detail) | DecodeFailed(List(decode.DecodeError)) | RoundTripFailed | CodecRaised(Crash)
  // durable.Error replaces its strings:
  //   NotPersistable(List(PersistenceProblem))  -- MissingCodecs(StepAddress), MissingRestoreUndo(StepAddress), EmptyVersion
  //   CodecFailure(boundary: Boundary, error: CodecError)
  //   InvalidCheckpoint(CheckpointProblem)
  //   RecoveryRequired(Required(step: StepAddress, action: execution.Action, key: EffectKey))
  pub type ErrorKind { Busy  Transient  NeedsReconciliation  Incompatible  Defect }
  pub fn error_kind(error: Error) -> ErrorKind
  pub fn describe_error(error: Error) -> String
  ```

  `error_kind` covers checkout's grind branches (`jobs.gleam:55-72`); docs
  say `Error` may grow. R4 adds `DriveTimedOut`; R2 removes `ReferenceMismatch`.

- **Breaks:** codec construction and error matches. **Effort:** M; adds
  gleam_json.

### SAGA-R6 Collapse the keyed/unkeyed pairs; give effects a stable key

- **Problem.** The three pairs differ only by a trailing `String`
  (`saga.gleam:263, 268, 297, 306, 339, 351`), under three naming schemes.
  The key changes per retry (probe: `"10:checkout-1:0:attempt:1"`), the
  opposite of what an `Idempotency-Key` needs, so checkout derives its own
  (CHK-8). The positional decider ignores two of three arguments in the
  README.
- **Sketch.**

  ```gleam
  pub type EffectKey { EffectKey(idempotency: String, attempt: Int, attempt_key: String) }
  pub type UndoRequest(i, o) { UndoRequest(input: i, output: o, key: EffectKey) }
  pub type FailedAttempt(i, e) {
    FailedAttempt(input: i, failure: AttemptFailure(e), attempt: Int, attempts_left: Int, key: EffectKey)
  }
  pub fn effect(name: String, run: fn(i, EffectKey) -> Result(o, e)) -> Step(i, o, e, u)
  pub fn undo(step, run: fn(UndoRequest(i, o)) -> Result(Nil, u)) -> Step(i, o, e, u)
  pub fn compensate(step, max_attempts max_attempts: Int,
                    with decide: fn(FailedAttempt(i, e)) -> Recovery(o, e, u)) -> Step(i, o, e, u)
  ```

  `step`/`effect` stays the one pair: `effect` declares an external action,
  and an arity-1 `step` keeps `saga.step("load", load_order)` point-free.
  The records grow by label only.

- **Breaks:** every `undo` and `compensate` callback; the change is
  mechanical. **Effort:** S.

### SAGA-R7 Correlation and the durable id in events; rename to `saga/telemetry`

- **Problem.** Metadata holds `workflow` and a per-VM `run: Int` that
  changes on every `drive` (`observation.gleam:23-25, 57-58`). Checkout
  attributes events by pid through a hook in its storage's `claim` (CHK-5);
  research_agent and support_desk leave them unattributed (RA-7, SD-3).
  `OutcomeKind` folds `CompletedWithUnknownEffects` into `OutcomeCompleted`
  (`:38-43`).
- **Sketch.** Add `execution.with_correlation(config, String)`. Every
  metadata record gains `correlation: Option(String)` and
  `execution: Option(String)`, the durable id. Add
  `OutcomeCompletedWithUnknownEffects`. Use the field name Sinal defines for
  theme 1.
- **Breaks:** positional matches in handlers, and the module rename.
  **Effort:** S.

### SAGA-R8 Opaque `Config`, explicit unbounded values, a capped retry delay

- **Problem.** `execution.Config` is a public record
  (`execution.gleam:46-54`), and R4, R7 and the retry cap all add fields.
  The fix round showed that an added field breaks positional construction.
  "Unbounded" is spelled `None`. `RetryAfter(ms)` is uncapped
  (`coordinator.gleam:1298-1306`).
- **Sketch.**
  `config() |> with_max_concurrency(4) |> with_deadline(5000)`. Add
  `without_step_timeout(config)` as the explicit opt-out, and
  `with_max_retry_delay(config, ms)` with a 300 s default. A larger delay is
  clamped and reported in the decision event. `start`, `run` and `drive`
  validate, with typed `ConfigError`s.
- **Breaks:** record-update callers (README and two apps). **Effort:** S.

### SAGA-R9 Persistence modifiers in `durable`; order-independent mapping

- **Problem.** The core module carries 4 durable-only modifiers and 3
  status unions (`saga.gleam:1729-1913`), two undocumented.
  `map_step_errors` sets `persistence: None` (`:403`), so modifier order
  matters silently (card concern 5; probe). `UndoFailed` exists in both
  `saga` and `execution`.
- **Sketch.** Move the four modifiers to `durable` with labels
  (`recoverable(step, version:, input:, output:, resolve:)`). Give the effect
  and undo resolvers one theme-3 type,
  `Evidence(o, e) { Completed(o)  Failed(e)  NotSent  MaybeSent }`, where
  `NotSent` authorizes a replay. `map_step_errors` maps resolver results
  forward instead of dropping them.
- **Breaks:** durable authoring only. **Effort:** S.

### SAGA-R10 Supervision and adapter lifecycle

- **Problem.** `memory.new()` is a bare unlinked `spawn`
  (`saga_storage.erl:6`), and its calls wait without a timeout
  (`:13-17`). Saga has no child specification, and nothing re-drives
  suspended or orphaned durable executions (card concern 7, theme 7).
  Local runs are owner-bound by design and need none.
- **Sketch.** `memory.start() -> Result(Memory, StartError)`,
  `memory.supervised(name: process.Name(..)) -> ChildSpecification(Memory)`
  (a name-based handle that stays valid across restarts), and
  `memory.stop`. Bound each call to 5 s. Add a durable sweeper only after
  open question 4; it needs a `pending` storage operation.
- **Breaks:** renames `new`/`close`. **Effort:** M; adds gleam_otp.

### SAGA-R11 Stable classification for growing unions; hide machinery

- **Problem.** `Cause` already grew `RetrySuperseded` (`execution.gleam:170`),
  and `DefinitionError` will grow with the design's cycle and
  duplicate-writer checks. Callers match both exhaustively
  (`apps/checkout/src/checkout/jobs.gleam:58-66`). `CrashOrTimeout`
  (`saga.gleam:247`) is public, unused, and collides with
  `execution.StepCrashed`/`StepTimedOut`. `execution.Action` and
  `reconciliation.Action` name one concept twice, and `InvalidConfig` exists
  in both `execution` and `durable`.
- **Sketch.** Add `execution.kind(outcome) -> OutcomeKind` (shared with
  telemetry), `execution.describe_cause` and `saga.describe_definition_error`.
  Document that `Cause`, `DefinitionError`, `durable.Error` and
  `storage.Error` may grow, and that `Recovery`, `AttemptFailure`,
  `CancelReason` and `Phase` are closed. Apply the deletions in §3.
- **Breaks:** barely; no app uses the hidden names. **Effort:** S.

### SAGA-R12 Docs that render and match behavior

- **Problem.** All 11 modules write their module doc as `///` before the
  imports, so `gleam docs build` renders none (probe). Five `durable`
  functions and every `codec` function have no docs. Comments narrate
  history (`saga.gleam:49`, `:1244-1253`). The README common path defines a
  workflow per `order_id` (`README.md:26-44`), and defaults live in three
  files.
- **Sketch.** `////` module docs, the §5 table in the README, define once and
  run per order, the durable example in the README, no history narration.
- **Breaks:** nothing. **Effort:** S.

### SAGA-R13 Dependencies ready for Hex

- **Problem.** The `sinal` path dependency (`gleam.toml:13`) blocks
  publication and CI (fix round). R5 adds gleam_json and R10 gleam_otp.
- **Sketch.** Hex ranges `sinal >= 0.1.0 and < 1.0.0`,
  `gleam_json >= 3.0.0 and < 4.0.0`, `gleam_otp >= 1.0.0 and < 2.0.0`. Sinal
  stays required: the coordinator emits on the common path.
- **Breaks:** nothing. **Effort:** S, gated on publishing Sinal.

## 5. Defaults table

| Operation                                 | Current default                                          | Proposed default                                                         |
| ----------------------------------------- | -------------------------------------------------------- | ------------------------------------------------------------------------ |
| `execution.run` wait for outcome          | until the outcome (`execution.gleam:413`)                | unchanged; finite because every component is bounded; formula documented |
| `await`, `progress`, `testing.wait_until` | caller timeout (required)                                | unchanged                                                                |
| Coordinator startup handshake             | 5000 ms, hard-coded (`execution.gleam:540`)              | unchanged; documented                                                    |
| Run `deadline`                            | none                                                     | none; documented as a derived bound (§6); `with_deadline` opts in        |
| Per-attempt `step_timeout`                | 60 s; `None` opts out                                    | 60 s; `without_step_timeout` opts out                                    |
| `settle_timeout` / `cleanup_timeout`      | 5 s / 5 s                                                | unchanged                                                                |
| `max_concurrency` per run                 | scheduler count                                          | unchanged                                                                |
| `max_attempts`                            | 1 (`>= 1`, no upper bound); undo never retried           | unchanged; caller-chosen and finite                                      |
| `RetryAfter(ms)` delay                    | uncapped (`coordinator.gleam:1298`)                      | 300 s cap (`with_max_retry_delay`)                                       |
| `durable.drive` wait                      | infinite (`durable.gleam:177`)                           | required `timeout:`; stops the runner and keeps the checkpoint           |
| `drive` caller exit                       | runner detaches and continues                            | runner stops (linked)                                                    |
| Storage call from the coordinator         | unbounded synchronous call (`coordinator.gleam:2391`)    | 5 s; `storage.TimedOut` suspends the run                                 |
| Memory adapter call                       | infinite `receive` (`saga_storage.erl:13-17`)            | 5 s                                                                      |
| File adapter mutation lock                | `global:set_lock(.., infinity)` (`saga_storage.erl:110`) | 5 s, then `Busy`                                                         |
| Checkpoint size                           | unbounded; whole snapshot rewritten per commit           | 16 MiB, typed `CheckpointTooLarge`                                       |
| Decoding; unknown evidence on recovery    | `binary_to_term(.., [safe])`; suspends                   | unchanged (both fail closed)                                             |
| Conformance owner-loss window             | 500 ms, hard-coded                                       | `owner_loss_within:` parameter                                           |
| Sinal handlers                            | synchronous in the coordinator                           | unchanged; documented that a slow handler delays the run                 |

## 6. Convention feedback

- **1 contradicts the guidelines.** [PUBLIC-API-GUIDELINES.md](../../PUBLIC-API-GUIDELINES.md)
  prefers public records for straightforward settings ("Record updates need
  no duplicate builder"), and saga followed it. The fix round favors opaque
  configuration. Decide once and update the guidelines.
- **4 needs a derived-bound clause.** A default run deadline would cut
  healthy long workflows. Saga bounds a run through attempt timeouts,
  attempt budgets, capped retry delays and the settle and cleanup windows.
  Accept such a bound when its formula is in the defaults table.
- **5 is for services, not units of work.** `execution.start` starts one
  owner-bound run and needs no `supervised`. Only long-lived processes need
  `supervised`/`stop` (the memory adapter, a future sweeper). Name the
  distinction, or `start` means two things across packages.
- **6, 7, 8.** Prefer `<Thing>Error`, since `Error(durable.StorageError(..))`
  reads badly. Saga needs both a caller `correlation` and a package-owned
  `execution` id. JSON currency applies to user codecs, not to the checkpoint
  envelope inside opaque storage bytes.
- **9** needs a carve-out for an advanced form that declares a different
  meaning and keeps the ordinary form point-free (`step`/`effect`).
- **Missing:** theme 3's not sent / maybe sent / completed evidence
  vocabulary. R1 and R9 apply it; `Evidence` should match http_gun's names.

## 7. Open questions

1. On durable restart, does an attempt that `unknown_when` classified go to
   the effect resolver, as a crash does, or replay its journaled error?
2. Should one `Storage` serve a pool with the id per operation (R2), or stay
   one per execution with RA-6's `storage(settings, id)` factory?
3. With claims as values (R3), does a lease-based adapter need
   `renew(Claim)`, or is "every commit refreshes the lease" enough?
4. Who re-drives suspended or orphaned executions (theme 5): a saga sweeper
   (needs storage listing), the grind integration, or the app?
5. Should `saga/codec` depend on gleam_json (R5), or should a `saga_json`
   package carry the constructor?
6. In a local run, should `EffectKey.idempotency` derive from the per-VM run
   id or from the caller's correlation, so a whole run can be retried under
   the same provider keys?
7. Should `saga_postgres` ship with the first release? Two apps wrote one.
