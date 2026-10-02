# saga — API card

Scanned 2026-10-01 against `/code/gleam-dream/saga` and sibling checkouts at
their current heads. Read-only scan; no package files changed.

## Health

- Git head: `23f0bdc feat: add optional workflow persistence and recovery`.
  Working tree clean before and after the gate.
- Repo gate (`AGENTS.md` "Gates", mirrored by `.github/workflows`), run inside
  `nix develop`. `nix fmt` was skipped because it rewrites files.

| Step                                                                  | Result                                         |
| --------------------------------------------------------------------- | ---------------------------------------------- |
| `gleam format --check src test`                                       | pass                                           |
| `gleam build --warnings-as-errors`                                    | pass                                           |
| `gleam test`                                                          | pass: 164 passed, 0 failures                   |
| `examples/order_consumer`: format, build -Werror, `gleam test`, `run` | pass: 14 passed; four scenarios ran to the end |
| `scripts/check_negative.sh`                                           | pass: 2 positive controls, 6 negative fixtures |
| `scripts/check_durable_restart.sh` (kills a VM, recovers in a new VM) | pass: both recovery probes                     |
| `nix flake check`                                                     | pass (aarch64-darwin only)                     |

- No external services needed. The Reactor oracle (`scripts/oracle.sh`) is
  outside the gate and was not run. No TODO/FIXME in `src/`.
- Pin drift: `sibling-revisions.txt` pins sinal at `13105bb`, while local
  `../sinal` is 7 commits ahead (`8acec45`). The local gate builds against the
  head; CI checks out the pin. The `sinal` path dependency blocks Hex publication.
- Open items (`CAPABILITIES.md`, `IMPLEMENTATION.md`): database adapters,
  checkpoint migrations, cross-VM file coordination and supervision. Checkpoints
  rewrite the whole snapshot.

## Purpose and scope delivered vs design

Saga is a typed saga/DAG orchestrator. Builders wire `Port(a, e, u)` values
through `perform`, `both`, `all`, `map`, `choose` and `embed`, and `define`
validates the graph once. `saga/execution` runs one coordinator per run. It
provides bounded concurrency, compensation deciders, reverse completion-order
undo, deadlines, timeouts, settlement and cancellation, and reports unknown
effects in every outcome. `saga/durable` adds optional persistence through a
pluggable `Storage` record, with memory and file adapters and a conformance
suite. Recovery uses explicit reconciliation callbacks and never replays blindly.
Within its static, closed-choice scope the delivery is strong and well
evidenced. Missing design capabilities:

- Value-dependent `and_then` and bounded `traverse`/`traverse_parallel`
  (only the binary `choose` exists).
- PostgreSQL checkpoint backend and OTP supervision (both in the design's
  "transferred durable scope", saga-design.md "Durable execution").
- `saga_grind` durable runner/outbox; independent children and compensation
  authority; post-success undo; durable approvals; halt/resume; undo retry.
- The whole runtime-authored graph surface: schema registry, publication,
  parametric nodes (`Identity`, `Choose`, `LLM<In,Out>`), structural
  compatibility, visualization, and historical review forks.

## Public modules

| Module                     | Responsibility                                                                                                                                                                                                                                                                   |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `saga`                     | Authoring: `Step`, `Port`, `Workflow`; `step`/`effect`, `undo`, `compensate`, `timeout`, `perform`, `map`, `both`, `all`, `choose`, `embed`, `define`, `map_errors`; persistence capability on steps (`recoverable`, `restore_undo`, `reconcile_undo`, `reconcile_compensation`) |
| `saga/execution`           | `Config` + `validate`, `run`/`start`/`start_reporting`/`await`/`cancel`/`progress`, `Outcome`, `Cause`, `Settlement`, `unknown_effects`                                                                                                                                          |
| `saga/durable`             | `prepare` (codecs + compatibility stamp), `start_or_reconnect`, `drive`, `read`, `cancel`; `Reference`, `Status`, `Error`                                                                                                                                                        |
| `saga/storage`             | The `Storage` contract (closure record), `Record`, `Error`                                                                                                                                                                                                                       |
| `saga/storage/memory`      | In-VM adapter backed by a dedicated process (`new`, `storage`, `close`)                                                                                                                                                                                                          |
| `saga/storage/file`        | Single-VM reference file adapter (`open(path)`)                                                                                                                                                                                                                                  |
| `saga/storage/conformance` | Reusable adapter protocol checks (`run(fresh_fixture, timeout_ms)`)                                                                                                                                                                                                              |
| `saga/codec`               | Versioned `String` codec (`new`, `text`, `bool`, `encode`, `decode`)                                                                                                                                                                                                             |
| `saga/reconciliation`      | `Required(step, action, key)` evidence for a suspended run                                                                                                                                                                                                                       |
| `saga/observation`         | Sinal event descriptors and typed measurements/metadata                                                                                                                                                                                                                          |
| `saga/testing`             | `wait_until(execution, matching:, within:)` progress polling                                                                                                                                                                                                                     |

## Common path

Adapted from `examples/order_consumer/src/order_consumer/workflows.gleam:133`
and README; all names match the source.

```gleam
let assert Ok(workflow) =
  saga.define("checkout", fn(input: Port(String, CheckoutError, UndoError)) {
    let order = input |> saga.perform(saga.step("load_order", load_order))
    let inventory =
      order
      |> saga.perform(
        saga.step("reserve_inventory", reserve)
        |> saga.undo(fn(_order, hold) { release(hold) })
        |> saga.compensate(max_attempts: 3, with: fn(_order, failure, _attempt) {
          case failure {
            saga.Returned(error) -> saga.Abort(error)
            _crash_or_timeout -> saga.RetryAfter(200)
          }
        }),
      )
    let payment = order |> saga.perform(saga.step("authorize_payment", authorize))
    saga.both(inventory, payment) |> saga.map(fn(p) { Checkout(p.0, p.1) })
  })

case execution.run(workflow, "ord-1", execution.config()) {
  Ok(execution.Completed(checkout)) -> Ok(checkout)
  Ok(execution.Failed(cause, settlement)) -> Error(Rejected(cause, settlement))
  Ok(other) -> Error(Uncertain(execution.unknown_effects(other)))
  Error(run_error) -> Error(NotRun(run_error))
}
```

Reusing the `order` port shares one node: `load_order` runs once.

## Configuration and advanced paths

- **Config** (`execution.gleam:46`): a public record with `max_concurrency`
  (default: scheduler count), `deadline: Option(Int)` (None),
  `step_timeout: Option(Int)` (60 s), `settle_timeout` (5 s) and
  `cleanup_timeout` (5 s). Callers update it with `Config(..execution.config(), ..)`;
  `run`/`start` validate it (`InvalidConfig`). This follows the guidelines.
- **Retries**: `saga.compensate(step, max_attempts:, with:)` returns a `Recovery`
  (`Retry`, `RetryAfter(ms)`, `Continue(output, undo)`, `Abort`,
  `AbortAfterCleanupFailure`, `Hold`). The decider also sees crashes and timeouts.
  No built-in backoff policy exists; the decider computes the delay. Undo is
  never retried.
- **Concurrency**: limited per run only. No pool is shared across runs.
- **Async**: `start` returns an `Execution`, which only the starting process can
  `await`. `start_reporting(.., to: Subject(Outcome))` delivers the outcome once
  to any subject. `progress`, `cancel` and `pid` complete the advanced path.
- **Persistence**: storage is pluggable. `storage.Storage` (`storage.gleam:18`)
  is a record of six closures for **one execution**: `create(bytes)`, `load()`,
  `claim()` (bumps the ownership generation), `commit(generation,
expected_revision, observed_cancelled, bytes)`, `release(generation)` and
  `cancel()`. A Postgres adapter via `pog` is feasible. It would be a `storage`
  factory that closes over a pool and an execution id: one row with
  `revision`, `generation`, `cancelled`, `data bytea`, conditional `UPDATE ...
WHERE revision = $ AND generation = $`, and a lease or advisory lock for
  `claim`, checked with `conformance.run`. Saga does not ship one (deferred).
  The adapter owns lease expiry after a worker dies.
- **Eligibility**: every step needs `saga.recoverable(step, version, in_codec,
out_codec, resolve)`. A compensating step also needs `restore_undo`. The
  workflow needs `durable.prepare(workflow, version, in, out, err, undo_err)`.
  Codecs are saga-owned `Codec(a)` over `String`.
- **Recovery**: saved outputs are reused. An interrupted effect, undo or
  compensation goes to its resolver (`recoverable`'s `resolve`, `reconcile_undo`
  or `reconcile_compensation`); "unknown" suspends the run as
  `Suspended(RecoveryRequired(..))`. Stable keys come from the `effect`
  variants.
- **Extension**: `embed` (shares the run and journal), `map_errors`/
  `map_step_errors` (caller-owned errors), `describe`, `conformance.run`.

## Lifecycle and supervision

- `execution.start` spawns one **unlinked** coordinator per run
  (`internal/coordinator.gleam:386`). It traps exits and monitors the owner:
  owner exit becomes `Cancelled(OwnerExited, ..)` after rollback. Each attempt,
  compensation and undo runs in a fresh task process, which a timeout kills.
- `durable.drive` spawns an unlinked runner and blocks with
  `selector_receive_forever` (no timeout; `durable.gleam:153-177`). Caller loss
  is detachment: the runner keeps its claim and continues.
- `memory.new()` spawns a bare unlinked process (`saga_storage.erl:6`); the
  caller must `memory.close`.
- **No supervision integration**: saga has no `ChildSpecification`, supervised
  builder or recovery sweeper (deferred in `CAPABILITIES.md`). Local runs are
  short-lived and bound to their owner, so this matters little there. Nothing
  restarts a suspended or orphaned durable execution; an integration must call
  `drive` again. The owner handles cleanup (`await` after `cancel`); the caller
  owns adapters.

## Failure model

- `define` returns `Error(List(DefinitionError))` (empty names, invalid
  attempts/timeouts, `ForeignPort`, `OrphanStep`). `run` returns
  `Error(RunError)`: `InvalidConfig` or `ExecutionLost(Crash)`.
- `Outcome`:
  - `Completed(o)`.
  - `CompletedWithUnknownEffects(o, unknown)`: a crashed attempt's effect is
    unknown.
  - `Failed(Cause(e), Settlement)`: rolled back.
  - `Cancelled(CancelReason, Settlement)`.
  - `Unresolved(step, evidence, Settlement)`: a `Hold` leaves effects in place.
- `Cause` is `StepFailed`, `StepCrashed`, `StepTimedOut`, `RetryLimitReached`,
  `RetrySuperseded`, `OutputCrashed` or `DeadlineExceeded`.
- `Settlement` separates `undone`, `undo_failures`, `not_undoable`, `held`,
  `interrupted`, `compensation_failures`, `sibling_failures` and
  `unknown_effects`. `execution.unknown_effects(outcome)` is the single "is any
  effect uncertain?" check, for every outcome kind.
- `durable.Error` covers `StorageError(storage.Error)`, `IncompatibleDefinition`,
  `ReferenceMismatch`, `InputMismatch`, `RecoveryRequired(Required)`,
  `SuspensionNotSaved(cause, recording)` and `RunnerLost`, plus the string
  carriers `InvalidDefinition`, `CodecFailure` and `InvalidCheckpoint`.
  `AwaitError` is `AwaitTimedOut`, `NotOwner`, `AlreadyAwaited` or `Lost`.

## Composition seams

- **Dependencies**: `gleam_stdlib`, `gleam_erlang` and `sinal` (a hard path
  dependency). Saga does not couple to grind, fabric, llm_wire, http_gun or
  json_blueprint, which matches the design ("Saga must not depend on Grind or
  Fabric").
- **Sinal**: saga emits `[saga, run, start|stop]`, `[saga, step, start|stop]`,
  `[saga, step, compensate, stop]` and `[saga, step, undo, stop]`. Metadata is
  typed: `workflow`, `run: Int`, `step` as a rendered `String`, `attempt`, and
  kind enums. Durable runs emit the same events, but the metadata has no durable
  `Reference` id and no caller correlation id (`observation.gleam:23-25`). One
  durable execution cannot be joined across restarts or to its http_gun spans
  (compare `http_gun.with_correlation`, `http_gun.gleam:200`). `OutcomeKind`
  folds `CompletedWithUnknownEffects` into `OutcomeCompleted`.
- **A step calling llm_wire, http_gun or grind**: no adapter is needed. A step is
  any `fn(i) -> Result(o, e)` (`saga.gleam:263`), so it can capture a shared
  `http_gun.Client` (supervised by the app via `http_gun.child`) or llm_wire
  config, and `map_step_errors` maps failures into `e`. Caveats:
  - Each attempt runs in a fresh process that a timeout kills, so siblings must
    clean up when the caller dies.
  - A durable HTTP or LLM effect needs a resolver; the `saga.effect` key serves
    as the idempotency key.
  - Enqueueing a grind job atomically with a checkpoint needs an outbox, which
    saga does not provide.
- **A grind worker running a saga durably**: this works through public APIs.
  `perform` (`grind/worker.gleam:147`) calls `durable.start_or_reconnect` and
  then `durable.drive`. On redelivery, `Busy` or a saved outcome short-circuits.
  Frictions:
  - `drive` has no timeout, so a job timeout only detaches the runner.
  - Grind's `worker.Codec` (`json.Json` + `Decoder`) and saga's `codec.Codec`
    (`String`, `Result(String, String)`) need a bridge per value type.
  - A pog `Storage` adapter would belong in `saga_grind`/`saga_postgres`.
- **A fabric tool starting a saga**: `fabric/tool.bind(def, handler, classify)`
  takes `fn(context, input) -> Result(output, error)`, so the handler can call
  `execution.run`. A non-empty `unknown_effects` maps cleanly onto fabric's
  `Uncertain`, and a clean `Failed` onto `Explain`. The tool task owns the run,
  though: if fabric stops it, the saga rolls back and `run`'s result is lost.
  Use `start_reporting`, or store a durable `Reference` in fabric's store.
- **Codec fragmentation**: saga (`String`), grind (gleam_json) and fabric
  (Blueprint) each own a codec type, so every integration needs a bridge.

## Ergonomics concerns

1. **Overlapping keyed/unkeyed pairs.** `step`/`effect`, `undo`/`undo_effect`
   and `compensate`/`compensate_with_key` (`saga.gleam:263,268,297,306,339,351`)
   differ only by an extra `String` key, under two naming schemes. One keyed
   form, or one `_with_key` convention, would halve the surface.
2. **Unlabeled lookalike positional arguments.**
   - `durable.prepare(workflow, version, in, out, err, undo_err)`
     (`durable.gleam:69`); the README calls
     `durable.prepare(workflow, "1", text, text, text, text)`.
   - `saga.recoverable(step, version, in, out, resolve)` (`saga.gleam:1747`).
   - `Storage.commit: fn(Int, Int, Bool, BitArray)` takes generation and
     revision as bare `Int`s (`storage.gleam:23`).

   Labels or opaque generation/revision types would prevent silent swaps.

3. **Stringly-typed errors callers must branch on.**
   - `durable.InvalidDefinition(String)` wraps `persistence_stamp`'s
     `Result(String, String)` (`saga.gleam:1795`). That one string merges
     missing codecs, missing `restore_undo` and an empty version, each with a
     rendered step.
   - Also: `CodecFailure(String)`, `InvalidCheckpoint(String)`,
     `storage.Io(String)`, codec errors as `String`, and
     `reconciliation.Required.step: String` (`reconciliation.gleam:10`), which
     is a rendered address rather than a `StepAddress`.
4. **Redundant, fragile durable arguments.** A `Storage` already addresses one
   execution (`storage.gleam:1`), yet `start_or_reconnect` also takes an `id`
   (`durable.gleam:101`). A mismatch surfaces later as `ReferenceMismatch`.
   Every durable call repeats `(storage, reference, persistence)`
   (`durable.gleam:101-160`); one bound handle would remove that wiring risk.
5. **Order-sensitive configuration.** `map_step_errors` silently drops
   `recoverable` codecs (`persistence: None`, `saga.gleam:403`). The mistake
   surfaces only at `durable.prepare`, as the string error in item 3.
6. **Name collisions across modules.**
   - `saga.StepCrashed`/`StepTimedOut` (`saga.gleam:247`) vs `execution.StepCrashed`/
     `StepTimedOut` (`execution.gleam:149`).
   - `saga.UndoFailed` vs `execution.UndoFailed`.
   - `execution.InvalidConfig` vs `durable.InvalidConfig`.
   - `execution.Action` (`StepAttempt`/`StepCompensation`/`StepUndo`) vs
     `reconciliation.Action` (`Activity`/`Compensation`/`Undo`) name one
     concept two ways.
7. **No supervision entry point.** Siblings ship one:
   - `http_gun.child` (`http_gun.gleam:51`), `warden.supervised`
     (`warden.gleam:173`) and `sinal/forwarder.supervised`.
   - `fabric.sweeper` (`fabric.gleam:936`), a supervised recovery sweeper, is
     exactly what durable saga lacks.

   Saga has none, and `memory.new()` is an unlinked bare process. The siblings'
   naming (`child` vs `supervised`) is itself inconsistent.
