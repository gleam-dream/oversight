# `saga` — typed workflows and compensation

Saga is a native Gleam workflow engine. It preserves dependency scheduling,
concurrency, retry, compensation, and undo while replacing Reactor’s dynamic
named wiring with typed construction. The initial [public API freeze](PUBLIC-API.md)
limits delivery scope; it does not cancel the capabilities retained below.

Elixir Reactor is intentionally dynamic: step arguments are maps of `any`,
results are referenced by names, and steps can be added while execution is
underway. It turns those references into a DAG and executes independent steps
concurrently. [Reactor’s documentation](https://reactor.hexdocs.pm/readme.html)
describes it as a “dynamic, concurrent, dependency resolving saga orchestrator,”
and its step interface confirms the extensive use of `any`.
[Reactor.Step](https://reactor.hexdocs.pm/Reactor.Step.html)

A strongly typed Gleam equivalent should represent dependencies through typed
values and combinators—not names.

## The core abstraction

The intended authoring model has one canonical opaque workflow definition with
input, output, business-error, and undo-error types. Activities, approvals,
shared dependencies, sequential composition, and closed choices use that same
representation. The laboratory calls it `Definition`; the original `Reactor`
and `Plan` signatures below describe retained composition semantics, not a
second accepted public builder.

The [public API guidelines](PUBLIC-API-GUIDELINES.md) govern the implementation
facade. The codec and version arguments in the laboratory examples below
describe durable replay requirements; local activities do not require them
unless their values cross a persistence boundary.

[Unified workflows](playground/interface_lab/UNIFIED-WORKFLOWS.md) establishes
construction evidence. Its laboratory activity retains its execution function,
compensation policy, operation identity/version, and four versioned codecs
(input, output, error, undo error) for durable use. Ordinary workflow persistence uses standard
Gleam JSON encoders/decoders or an
optional schema-independent codec abstraction. Blueprint is needed only for the
runtime-authored JSON Schema surface below. Saga owns the versions and
compatibility of its persisted boundaries; laboratory Blueprint imports are
prototype convenience, not a production dependency requirement. A caller-supplied
structural signature is an assertion, not a computed compatibility proof.

### Current authoring example

Examples labeled current quote laboratory symbols, not a released package API.
Proposed sketches below retain unimplemented capabilities and are not compilable
modules. The laboratory's `Codec` is Blueprint-backed for convenience; ordinary
workflow serialization remains schema-independent in production intent.

Current laboratory signature/type excerpt from [`saga.gleam`](playground/interface_lab/src/lab/saga.gleam) (`ActivityContract`, `Compensation`, `activity`, `define`, `and_then`); consumer: [`unified_workflow`](playground/interface_lab/src/consumers/unified_workflow.gleam). Function bodies and imports are omitted; this is not a standalone module.

```gleam
pub type VersionedCodec(a) {
  VersionedCodec(version: Version, codec: Codec(a))
}

pub type ActivityContract(i, o, e, u) {
  ActivityContract(
    input: VersionedCodec(i),
    output: VersionedCodec(o),
    error: VersionedCodec(e),
    undo_error: VersionedCodec(u),
  )
}

pub type Compensation(i, o, u) {
  Uncompensated
  Compensate(fn(i, o) -> Result(Nil, u))
}

pub fn activity(
  id: StepId,
  step_version: Version,
  contract: ActivityContract(i, o, e, u),
  execute: fn(i) -> Result(o, e),
  compensation: Compensation(i, o, u),
) -> Activity(i, o, e, u)

pub fn define(
  id: DefinitionId,
  definition_version: Version,
  structural_signature: String,
  activity: Activity(i, o, e, u),
) -> Definition(i, o, e, u)

pub fn and_then(
  structural_signature: String,
  first: Definition(i, m, e, u),
  second: Definition(m, o, e, u),
) -> Definition(i, o, e, u)
```

`step_id`, `definition_id`, and `version` are checked constructors; invalid empty
identities or nonpositive versions return errors. `Uncompensated` records absent
compensation rather than a successful no-op. `and_then` above composes two
existing definitions; it is not the original value-dependent callback API.
The [contract-output negative](playground/interface_lab/negative/contract_output.gleam)
rejects disagreement between handler output and its contract codec.

## Typed DAG construction

Current laboratory signature/type excerpt from [`saga.gleam`](playground/interface_lab/src/lab/saga.gleam) (`begin`, `add_activity`, `pair`, `finish`); consumer: [`shared_graph`](playground/interface_lab/src/consumers/shared_graph.gleam). Function bodies and imports are omitted; this is not a standalone module.

```gleam
pub fn begin(
  input: Codec(i),
  error: Codec(e),
  undo_error: Codec(u),
) -> #(Builder(i, e, u), Port(i))

pub fn add_activity(
  builder: Builder(i, e, u),
  input: Port(a),
  id: NodeId,
  activity: Activity(a, b, e, u),
) -> Result(#(Builder(i, e, u), Port(b)), BuildError)

pub fn pair(
  builder: Builder(i, e, u),
  left: Port(a),
  right: Port(b),
) -> Result(#(Builder(i, e, u), Port(#(a, b))), BuildError)

pub fn finish(
  builder: Builder(i, e, u),
  output: Port(o),
  id: DefinitionId,
  definition_version: Version,
  structural_signature: String,
) -> Result(Definition(i, o, e, u), BuildError)
```

A `Port(a)` retains the native value relationship without exposing its constructor.
The updated builder returned by each operation must be passed onward. `finish`
rejects a foreign output or unreachable node; construction does not execute work.
The [shared graph consumer](playground/interface_lab/src/consumers/shared_graph.gleam)
constructs shared fan-out and joins. Production scheduling must execute a shared
producer once and run independent branches within the concurrency budget.
Diagnostic labels do not transport values or replace typed port connections.

The checkout requirement remains create-order → independent fraud/inventory →
charge-payment → receipt, with typed workflow errors and refund/release/cancel
compensators. Parallel execution and value-dependent construction remain retained
requirements rather than demonstrated by these signatures.

### Fabric graph requirements accepted by Saga

The [Fabric transfer](fabric-design.md#1-dag--typed-workflow-requirements-reassigned-to-saga)
retains pure graph authoring and validation without processes, clocks, I/O, or
OTP startup. Validation must reject cycles, missing producers, duplicate writers
without a declared reducer, and unreachable outputs. The original Kahn-style
check is a reference mechanism; equivalent validation and typed multiple-writer
reduction remain required beyond current shared-graph probes. Reducer
associativity is an application obligation, not a compiler guarantee.

Control-only edges and arbitrary cyclic control graphs remain excluded from
this transferred value-dependency contract. Bounded iteration belongs inside a
node, including a bounded Fabric agent loop. The loop's policy, tools, budgets,
and continuation remain Fabric-owned; Saga owns its activity or child boundary.
A side-effecting agent needs compensation or effect receipts, and an approval
pause must suspend through one continuation owner rather than fail or rerun the
agent. Suspended agents and concrete sub-agent integration remain unresolved
required consumers, not coverage supplied by ordinary function composition.

## Shared dependencies without `Dynamic`

Each typed dependency represents one memoized node per execution. Fresh
construction tokens separate repeated occurrences of a reused definition.
Stable addresses retain sequence occurrence and nested choice scope; tokens do
not enter persisted identities. Reassociating a sequence changes those addresses
and therefore requires compatibility handling for persisted state.

If the same plan is used twice:

Proposed semantic sketch, not a current laboratory API. Helper types and
functions are placeholders; scheduling, persistence eligibility, and checked
boundaries must be specified before implementation.

```gleam
let order = create_order(input)

let inventory = reserve_inventory(order)
let fraud = check_fraud(order)
```

`order` must execute once, not once per consumer.

Internally, each plan node can own:

- Its typed output state.
- Its dependency closures.
- A typed receiver for its result.
- A uniform, untyped-in-the-benign-sense lifecycle interface for the scheduler:
  start, cancel, status and metadata.

**Requirement, not a prescribed mechanism.** A node's output type must be
compiler-checked from the producer that creates it to every consumer that
reads it: no caller-visible value ever passes through `gleam/dynamic.Dynamic`,
and no step looks up a dependency by name against a shared, heterogeneously
typed map. If an implementation needs a type-erased value at all — for
example to store per-run results centrally instead of in one cell per node —
that erasure must be confined to a single internal module, never exposed to
callers or spread through the scheduler; that module must state the
soundness invariant that makes its one unsafe operation safe by construction
(not by caller discipline or convention); and that invariant must be tested
adversarially (attempting to read a stored value at the wrong type, or to
construct a reference to it outside the module that mints one, must be
impossible to express, or must be caught, not merely untested). Whether such
central storage exists at all, and how, is an implementation decision for
each execution mode to make and record — see "Decision: a central per-run
store in the delivered local coordinator" below for the local-execution
mode's own choice and evidence.

Consumers receive a node's result only through a typed interface — never a
name-keyed lookup against a heterogeneous map.

The central scheduler only sees events such as:

Proposed semantic sketch, not a current laboratory API. Helper types and
functions are placeholders; scheduling, persistence eligibility, and checked
boundaries must be specified before implementation.

```gleam
pub type NodeEvent {
  Started(NodeId)
  Completed(NodeId)
  Failed(NodeId)
  Retrying(NodeId, attempt: Int)
  Undone(NodeId)
}
```

It does not manipulate the actual `Customer`, `Order`, or `Payment` values.

### Decision: a central per-run store in the delivered local coordinator

The delivered `saga` package's local-execution coordinator (`saga/internal/
coordinator`, backing `saga/execution`) uses a per-run `Dict(Int, Native)`
in `saga/internal/store` — structurally the central `Dict(NodeId, Dynamic)`
shape the mechanism sketch above once ruled out — rather than one mailbox
cell per node. This is recorded here as a decision against the requirement
above, not a silent exception to it.

- **The mechanism.** `Native` is `saga/internal/store`'s own opaque,
  type-erased carrier — never `gleam/dynamic.Dynamic`, never inspected or
  decoded, only ever cast back to the exact type it was stored as. The store
  is read only through `store.get`, confined to that one internal module. A
  node id and its element type are bound together exactly once, in the same
  `perform` call that both allocates the id and returns the typed, opaque
  `Port` whose `fetch` closure reads that id back; no other code path can
  construct a `Port` for one node id typed differently than the `perform`
  call that created it. That is the invariant that makes `store.get`'s one
  native coercion sound by construction, not by caller discipline — see
  `saga/internal/store`'s own doc comment and `saga.gleam`'s `Port`/`perform`
  for the full argument, and `saga`'s compiler-negative fixtures
  (`fixtures/negative/`, run by `scripts/check_negative.sh`) for the
  adversarial tests: a `Port` cannot be constructed outside its owning
  module, and mismatched error types fail to compile before ever reaching
  the store.
- **Why.** The per-node design this replaced gave every node its own
  single-value mailbox cell, allocated fresh each time the workflow's
  builder ran, keeping the scheduler's own state free of any central
  heterogeneous map. That required two costs together: every dependency
  read was a selective receive whose cost grew with how many prior messages
  already sat in that mailbox (O(N) per read, O(N²) total per run for a
  workflow whose reads scale with N), and the workflow's builder had to be
  re-evaluated, side-effect-free, on every run to reconstruct those cells —
  a purity/determinism requirement on caller-authored code that a one-time,
  `define`-time build does not need.
- **The evidence.** `saga/bench/RESULTS.md` measured the per-node design
  directly: a 2000-step chain's median run time was ~392ms before, growing
  ~4x per doubling (quadratic). Moving to the central store (plus a
  companion min-heap admission fix that closed a second, separate O(N)
  scheduling cost the store change alone did not touch) took the same
  benchmark to ~8ms median, roughly 14x–49x faster across the three
  benchmarked shapes at N=2000 depending on shape, with growth flattening
  from ~4x per doubling to ~2x per doubling (linear). See `bench/RESULTS.md`
  in the `saga` package for the full before/after tables across all three
  shapes and every measured N.
- **What this keeps simple.** Confining the erasure to one internal module
  with one stated invariant, rather than threading `Dynamic` through the
  scheduler or exposing it to callers, keeps the future durable-journal
  boundary (still deferred; see `saga/CAPABILITIES.md`) simpler to reason
  about: a durable journal only ever needs to serialize the same typed,
  per-node values this store already carries, through the same one
  soundness invariant, not a caller-visible dynamic protocol.

This decision applies to the delivered local-execution coordinator. A future
durable execution mode may reach a different trade — for example, because a
durable journal's own persisted representation has different constraints —
and should record its own decision here rather than silently inheriting this
one.

## Execution ownership and evidence

Saga owns dependency readiness, bounded in-run concurrency, activity retry,
compensation, undo order, and undo-error accumulation. A direct activity belongs
to its enclosing workflow journal. An independent child owns its own execution
and journal; registering a child never silently flattens it into an activity.
Approval is suspension with retained input and an explicit answer boundary,
not a business failure or a blocked worker.

Current laboratory signature/type excerpt from [`saga.gleam`](playground/interface_lab/src/lab/saga.gleam) (`start_local`, `advance_local`, `perform_local`, `LocalTransition`); consumer: [`local_execution`](playground/interface_lab/src/consumers/local_execution.gleam). Function bodies and imports are omitted; this is not a standalone module.

```gleam
pub fn start_local(
  definition: Definition(i, o, e, u),
  input: i,
) -> Result(LocalExecution(o, e, u), LocalAdmissionError)

pub fn advance_local(
  execution: LocalExecution(o, e, u),
  control: LocalControl(o, e, u),
) -> LocalTransition(o, e, u)

pub fn perform_local(work: LocalWork(o, e, u)) -> LocalCompletion(o, e, u)

pub type LocalTransition(o, e, u) {
  LocalWorkIssued(LocalExecution(o, e, u), LocalWork(o, e, u))
  LocalExecutionPaused(LocalExecution(o, e, u))
  LocalExecutionFinished(LocalExecution(o, e, u), LocalReport(o, e, u))
  LocalControlRejected(LocalExecution(o, e, u), LocalControlError)
  LocalRetryScheduled(LocalExecution(o, e, u), LocalWake, RetryDelay)
  LocalRetryBlocked(LocalExecution(o, e, u))
  LocalExecutionUnresolved(LocalExecution(o, e, u), LocalUnresolvedReason(e, u))
}
```

The host interprets issued work with `perform_local`, then returns the resulting
completion through `CompleteLocal`; it supplies `WakeLocal` only after its timer.
`LocalExecutionFinished` carries a typed report, while unresolved and retry-blocked
states retain the execution. These are serial laboratory transitions, not durable
or concurrent scheduling.

The [local execution experiment](playground/interface_lab/LOCAL-EXECUTION.md)
executes direct activities, shared dependencies, pair adapters, and sequence
adapters serially. It rejects unsupported approvals, children, and choices
before application callbacks. A reducer issues work; a separate interpreter
executes callbacks and returns correlated completions. Foreign or repeated
completions cannot advance the current state, but copyable state does not
prevent replay or repeated external effects.

Sequential connections preserve decode-then-encode adapters when equal native
types have different wire representations. Shared construction, closed-choice
routing, typed ports, duplicate identities, foreign references, and orphan
rejection have separate construction probes. None establishes concurrent
scheduling, process ownership, or durable execution.

## Heterogeneous undo without `Dynamic`

A saga journal normally contains successful results of different types:

- `Order`
- `Reservation`
- `Payment`
- etc.

A naïve implementation would need `List(Dynamic)`. But closures remove that
requirement:

Proposed semantic sketch, not a current laboratory API. Helper types and
functions are placeholders; scheduling, persistence eligibility, and checked
boundaries must be specified before implementation.

```gleam
type UndoAction(undo_error) {
  UndoAction(fn() -> Result(Nil, undo_error))
}

type Execution(value, undo_error) {
  Execution(
    value: value,
    undo_actions: List(UndoAction(undo_error)),
  )
}
```

After an effect succeeds, the local runtime retains a closure before encoding its output:

Proposed semantic sketch, not a current laboratory API. Helper types and
functions are placeholders; scheduling, persistence eligibility, and checked
boundaries must be specified before implementation.

```gleam
let undo_action =
  UndoAction(fn() {
    undo(output, input)
  })
```

The closure privately captures the correctly typed `input` and `output`. The
journal only stores homogeneous functions:

Proposed semantic sketch, not a current laboratory API. Helper types and
functions are placeholders; scheduling, persistence eligibility, and checked
boundaries must be specified before implementation.

```gleam
List(UndoAction(UndoError))
```

The local native undo journal requires:

- No casts.
- No `Dynamic`.
- No encoded values.
- No central heterogeneous value map.

This is probably the most important architectural technique for a typed Gleam
Reactor.

## Compensation and retry

Successful direct activities undo in reverse actual completion order. An undo
failure does not stop remaining compensators. Terminal reports preserve the
original business failure, boundary failure, or cancellation separately from
located undo failures and uncompensated successes. The serial interpreter has
executable evidence for these rules, including output-encoding failure after a
successful effect. Parallel branch settlement remains required runtime work.

Reactor distinguishes:

- Compensation of the currently failing step.
- Undoing earlier successful steps.
- Retrying.
- Continuing with a replacement value.

Current laboratory signature/type excerpt from [`saga.gleam`](playground/interface_lab/src/lab/saga.gleam) (`RecoveryDecision`, `RetryCancellation`, `RecoveryPolicy`, `recover_activity`); consumer: [`activity_recovery`](playground/interface_lab/src/consumers/activity_recovery.gleam). Function bodies and imports are omitted; this is not a standalone module.

```gleam
pub type RecoveryDecision(o, e, u) {
  RetryAfter(RetryDelay, RetryCancellation(e, u))
  UseOutput(o, Compensation(Nil, o, u))
  AbortAndCompensate(cause: e, cleanup_failures: List(u))
  SuspendUnresolved(evidence: e, cleanup_failures: List(u))
}

pub type RetryCancellation(e, u) {
  CompensateOnCancel
  HoldOnCancel(evidence: e, cleanup_failures: List(u))
}

pub type RecoveryPolicy(i, o, e, u) {
  RecoveryPolicy(
    limit: AttemptLimit,
    recover: fn(i, e, RetryBudget) -> RecoveryDecision(o, e, u),
  )
}

pub fn recover_activity(
  activity: Activity(i, o, e, u),
  limit: AttemptLimit,
  recover: fn(i, e, RetryBudget) -> RecoveryDecision(o, e, u),
) -> Activity(i, o, e, u)
```

`attempt_limit` validates a positive total-attempt budget and `retry_delay`
validates a nonnegative relative millisecond delay. `UseOutput` needs the same
native output type and its own compensation; an absolute queue timestamp cannot
stand in for `RetryDelay`. The [recovery-output negative](playground/interface_lab/negative/recovery_output_type.gleam)
checks replacement typing.

The [activity recovery contract](playground/interface_lab/ACTIVITY-RECOVERY.md)
refines that sketch: recovery receives native input, business cause, and the
remaining attempt budget. A positive limit includes the first attempt. Recovery
still runs after exhaustion because the failed activity may need cleanup.

Retry permission and rollback permission are separate. Retry requires an
application-owned idempotency or reconciliation basis and an explicit
cancellation policy. Replacement output carries its own compensator, retained
before encoding. Abort permits prior-effect rollback explicitly; cleanup failure
alone grants no permission. An unresolved outcome retains typed evidence, the
failed activity, and the completed journal without authorizing retry or undo.

Delayed retry yields a relative duration and correlated wake token; the host
owns timers. Retry after exhaustion remains blocked rather than implying
rollback. Reconciliation authority, real elapsed-time enforcement, callback
exceptions, in-flight timeout/cancellation settlement, and parallel attempts
remain requirements. Provider retry, Saga activity retry, and Grind delivery
recovery must not multiply one effect through hidden policies.

## Dynamic branching is still possible

Strong typing does not mean the entire graph must be statically fixed.

`and_then` can choose the next typed plan based on a result:

Proposed semantic sketch, not a current laboratory API. Helper types and
functions are placeholders; scheduling, persistence eligibility, and checked
boundaries must be specified before implementation.

```gleam
order
|> saga.and_then(fn(order) {
  case order.total >. 10_000.0 {
    True -> manual_review(order)
    False -> automatic_approval(order)
  }
})
```

Both branches must ultimately produce the same output and error types:

Proposed semantic sketch, not a current laboratory API. Helper types and
functions are placeholders; scheduling, persistence eligibility, and checked
boundaries must be specified before implementation.

```gleam
Plan(Approval, CheckoutError, UndoError)
```

Dynamic homogeneous fan-out is also straightforward:

Proposed semantic sketch, not a current laboratory API. Helper types and
functions are placeholders; scheduling, persistence eligibility, and checked
boundaries must be specified before implementation.

```gleam
pub fn traverse_parallel(
  values: List(a),
  run: fn(a) -> Plan(b, error, undo_error),
) -> Plan(List(b), error, undo_error)
```

So you can create one step per order item at runtime without losing type safety.

Dynamic value-dependent branching and bounded homogeneous traversal remain
required capabilities beyond the demonstrated closed choice. The production
contract must define ordering, graph-size limits, cancellation, and concurrency
budgets. Arbitrary local closures remain a local authoring requirement; durable
branch selectors and transformations require stable identities and versions,
with selected branches recorded in the journal. The unified definition must
preserve that distinction without dropping the original local expressiveness.

## Durable execution and freeze/thaw

One canonical definition serves local execution and the optional `saga_grind`
durable integration. Eligibility for persistence is explicit: deployed factories
supply executable callbacks, while snapshots contain data and versioned
identities. Arbitrary closure-bearing local computations are not serializable.
The exact admission boundary for unrestricted local transformations remains
unresolved; it must retain local capability rather than silently constrain it
to the initial static facade.

The durable runner owns workflow progress, readiness, selected branches,
activity outcomes, revisions, child links, and compensation journals. Grind owns
job admission, capacity, claims, leases, delivery, and delivery recovery. Grind
also retains its separate dependency-only job workflows without Saga's typed
final result or compensation contract. Saga must not depend on Grind or Fabric;
the optional integration depends on Saga and Grind.

Running an entire local Saga inside one job restarts the whole local workflow
after delivery loss. It is not per-activity durability. Reported Saga success,
business failure, cancellation, and undo failure become terminal workflow
results by default; retrying a completed failed workflow requires explicit
policy. Durable per-activity execution instead commits outcomes and newly ready
job admission together, or uses a transactional outbox with idempotent admission.

The transferred durable scope includes single-node OTP supervision, memory and
PostgreSQL checkpoint backends, typed completion, review tickets, expected
revision commits, and explicit conflict outcomes. It does not assert distributed
coordination merely because Grind supports durable delivery. Historical review
forks remain required: resuming an earlier revision with a different answer
needs explicit ownership and treatment of already performed effects. Ordinary
restore or retry does not prove safe forking; that effect policy remains
unresolved jointly with Fabric's approval/continuation ownership.

Freeze requires checkpoint permission after quiescence. A data snapshot and a
fresh compatible definition are separate restore inputs. Snapshots contain no
executable closures, actors, sockets, or live worker leases; checkpoint
permission does not prove exclusive ownership of a copyable execution value. Restore validates
identities, codec versions, branch selections, completion order, wait state,
and revision before recovering typed results. It preserves waiting, terminal,
stale-signal, cancellation, migration failure, corrupt-state, and ambiguous-effect
outcomes. Approval signals require authentication, revision checks, and command
deduplication. Suspending execution commits its wait and releases worker capacity.

An external effect followed by worker loss before completion recording remains
ambiguous unless downstream idempotency, fencing, or an atomic transaction
settles it. Freeze/thaw cannot resolve that uncertainty. Snapshot codecs,
unfinished-command persistence, journal transactions, migration, timers, process
recovery, and a real durable runner remain backlog; the checkpoint and Grind
modules contain interface evidence and unfinished bodies, not runtime guarantees.

## Independent children and compensation authority

A child contract retains the definition and actual input/output/error/undo-error
codecs. A persistable child link contains routing and compatibility data, not
closures or credentials. Attachment, reattachment, and observation check owner,
run, definition, structural signature, and boundary versions before decoding.
Unavailable owner, missing run, pruned result, incompatible definition, and
corrupt result remain separate outcomes.

Submission is asynchronous. A prepared command retains exact encoded input,
contract metadata, retention, and command identity. Only a checked admission
receipt yields a typed child handle. Unknown or invalid replies preserve the
original owner route and exact request for reconciliation; a failed retry does
not resolve earlier uncertain admission. Cancellation acknowledges recorded
intent separately from child completion, rollback, or reconciliation.

The parent persists its child attachment and stable commands before treating
admission or adoption as committed. Restart reattaches and observes committed
child state; notifications and Sinal events are not control state. A waiting
parent releases capacity needed by the child. Cancellation and deadlines must
propagate through explicit owner policies, and nested concurrency must respect
one shared or partitioned budget.

Child success does not grant compensation authority. The child owner checks
successful completion, journal retention, claimant identity, and exclusive claim
before issuing a receipt. A durable receipt reference is rebound with a fresh
compatible contract and its actual undo-error codec. One claim admits at most
one logical compensation operation; request replay recovers that operation even
after the original admission deadline. Storage must enforce these rules because
Gleam handles are copyable.

Historical child output remains separate from compensation progress and from
result/journal retention. Compensation can be pending, running, successful,
failed with undo errors, or unresolved. Plain outer failure leaves successful
child effects in place unless the parent holds explicit compensation authority.
Local post-success authority remains required but unfinished; a closure receipt
cannot substitute for a durable owner-backed reference.

[Child attachment](playground/interface_lab/CHILD-ATTACHMENT.md),
[admission](playground/interface_lab/CHILD-ADMISSION.md), and
[compensation](playground/interface_lab/CHILD-COMPENSATION.md) exercise scripted
owner records and immutable command replay. They do not prove storage
atomicity, authorization, races, retention enforcement, process recovery, or
exactly-once remote effects. Parent recovery remains separate from child recovery.

## Where exact Reactor parity becomes impossible

The typed design cannot support every form of Reactor dynamism without some form
of type erasure. This table describes intended capabilities, not implemented
runtime coverage.

| Capability                                           | Strongly typed Gleam             |
| ---------------------------------------------------- | -------------------------------- |
| Typed step input/output                              | Excellent                        |
| Compile-time dependency validation                   | Excellent                        |
| Concurrent independent branches                      | Yes                              |
| Saga undo/compensation                               | Yes                              |
| Retry, timeout and backoff                           | Yes                              |
| Typed conditional branches                           | Yes                              |
| Runtime homogeneous fan-out                          | Yes                              |
| Nested/composed reactors                             | Yes                              |
| Add arbitrary known typed steps at runtime           | Yes, through `and_then`          |
| Load arbitrary step types from configuration         | No                               |
| Reference arbitrary results by names                 | Intentionally no                 |
| Serialize arbitrary workflow closures                | No                               |
| Store heterogeneous results centrally                | Requires `Dynamic` or unsafe FFI |
| Return arbitrary heterogeneous new steps from a step | Not generically                  |

The main incompatible feature is this Reactor result:

```elixir
{:ok, value, dynamically_created_steps}
```

If those new steps can have arbitrary output types, Gleam needs an existential
type, GADT-like encoding, `Dynamic`, or a closed application-specific ADT.

The typed replacement is:

Proposed semantic sketch, not a current laboratory API. Helper types and
functions are placeholders; scheduling, persistence eligibility, and checked
boundaries must be specified before implementation.

```gleam
and_then(current_plan, fn(value) {
  build_more_typed_plans(value)
})
```

That offers dynamic execution, but only through code whose types are known at
compile time.

## Reporting preserves the execution report

The owned-run reporting boundary returns the execution's full typed report. Reporting owns
receiver lifecycle and delivery; the application chooses how to classify or
render a delivered report.

```gleam
// Return type of reporting.run_owned:
Result(execution.Outcome(output, error, undo_error), reporting.Error)
```

- `Ok(report)` means that an execution report was obtained. The report can
  describe completion, failure, cancellation or unresolved effects; `Ok` does
  not imply that the workflow completed successfully.
- `Error(error)` describes a reporting or execution-admission failure for which
  no execution report is available. The reporting boundary retains typed
  operational causes instead of encoding them only in diagnostic strings.
- A reported workflow failure retains its typed business cause, undo errors
  and settlement evidence in `execution.Outcome`. Reporting does not introduce
  a second representation of those facts.
- The stopped-owner callback receives the same result shape as the synchronous
  caller. Its existing ownership, bounded notification and cancellation
  behavior remain required.
- Applications use `outcome.classify(report, explain)` when they need an
  application output or an effect classification. Safe summary rendering is a
  separate projection of the report; it does not replace typed evidence.
- Fabric's consumer-owned recipe performs this projection when mapping the
  report to `Explain` or `Uncertain`. Saga acquires no dependency on Fabric.

### Reporting errors and consumer mapping

- `run_owned` removes the `explain`
  parameter and the separate summary argument to `on_stopped`; both callers
  receive the full-report result specified above.
- One `reporting.Error` boundary retains invalid rollback bounds, receiver
  startup failure, execution admission failure and lost report delivery as
  distinct typed causes. Execution admission retains `execution.RunError`,
  including its configuration errors or `saga.Crash`, without copying their
  fields into a second error representation.
- Receiver startup distinguishes receiver exit from its readiness deadline.
  Delivery loss distinguishes receiver loss from coordinator loss; available
  process exit evidence remains typed, with absence represented explicitly.
- `reporting.error_kind` supplies stable categories for growing errors;
  `reporting.describe_error` renders a safe description. Typed causes are
  available through accessors, so a caller never parses those descriptions.
- `reporting.effect_status` returns `NotStarted` only when the boundary can
  prove that no workflow execution was launched; every other error returns
  `Unknown`. An `execution.ExecutionLost` during startup is `Unknown`, since
  the coordinator may have started work before its handshake was lost.
- `NotStarted` covers rejected configuration, invalid rollback bounds and
  receiver failure before workflow launch. It does not mean compensation
  occurred and does not authorize an automatic retry.
- The stopped-owner callback retains the existing cancellation, rollback and
  bounded notification rules. A callback crash or deadline does not establish
  successful delivery and cannot replace the execution report with a success.
- The Fabric recipe maps `Ok(report)` through `outcome.classify` with the
  application's `explain` and uses `outcome.summary` for settlement evidence.
  It maps reporting errors to `Explain` only for `NotStarted`, and to
  `Uncertain` for `Unknown`, using `reporting.describe_error` in either case.
- One consumer-local projection serves synchronous return and stopped-owner
  settlement. The verbatim recipe includes that projection in its line count;
  the API must not acquire a Fabric-specific helper merely to meet 50 lines.

### Complete safe outcome summaries

- Review finding 8 keeps `execution.Outcome` as the authority for execution
  evidence. An internal pure projection supplies facts used by both effect
  classification and safe rendering; no new public report type is introduced.
- `outcome.summary` includes the outcome and cause kinds, step addresses,
  successful undos, held steps, steps without undo, undo failures,
  compensation failures, interrupted steps and sibling failures. Unknown
  effects retain the action, attempt number where applicable, and ending kind.
- Completed outcomes with unknown effects retain those effects in the
  summary. Failed, cancelled and unresolved outcomes include the same
  settlement and unknown-effect categories whenever present.
- Overlapping categories preserve distinct facts: a step can have a failed
  undo and an earlier unknown attempt. Identical addresses within one category
  may be displayed once, but distinct attempts and actions must remain visible.
- Safe descriptions exclude application output, typed error payloads and
  crash payloads. Step addresses remain visible under the existing contract.
- Applications explicitly supply `explain` to expose selected business error
  details through classification. Safe summary rendering never invokes it.
- Existing completed, compensated and unresolved classification semantics
  remain unchanged. Evidence that no effects remain does not determine retry
  policy, which belongs to the caller.

### Reporting and summary acceptance evidence

- External consumer tests must preserve application-native business and undo
  error values through the report and preserve typed operational causes
  through reporting errors. Tests must distinguish an obtained failure report
  from an operational error without a report.
- Startup, owner-death and delivery-loss tests must verify effect status,
  bounded waits, callback behavior and monitor/mailbox cleanup. Existing
  completion, compensation, cancellation and uncertainty tests remain required.
- Table-driven summary tests must cover every evidence category for each
  outcome that can carry it, including overlapping categories and multiple
  attempts. Secret-shaped payload sentinels must remain absent from safe
  summaries and safe reporting descriptions.
- The revised recipe must compile from README and module documentation,
  include all helper lines in its 50-line gate, and retain the migrated apps'
  tests and attribution results. This design discussion has not run those
  future implementation checks.

## Error types must be deliberately unified

Different steps naturally have different error types. Before they can
participate in one reactor, map them into a workflow error ADT:

Proposed semantic sketch, not a current laboratory API. Helper types and
functions are placeholders; scheduling, persistence eligibility, and checked
boundaries must be specified before implementation.

```gleam
create_order_plan
|> saga.map_error(OrderCreationFailed)
```

Likewise:

Proposed semantic sketch, not a current laboratory API. Helper types and
functions are placeholders; scheduling, persistence eligibility, and checked
boundaries must be specified before implementation.

```gleam
reserve_plan
|> saga.map_error(InventoryReservationFailed)
```

This is some additional ceremony, but it produces a valuable property: callers
know every business failure the complete workflow can return.

Using `Dynamic` would explicitly give up that knowledge; Gleam’s documentation
defines `Dynamic` as data whose type is not yet known and which must later be
decoded. [Gleam Dynamic](https://hexdocs.pm/gleam_stdlib/gleam/dynamic.html)

## The real trade-off

The Gleam library would be less like a configurable workflow engine and more
like a typed effect-graph library.

That distinction matters:

- Elixir Reactor starts with a runtime graph and resolves runtime references.
- Typed Gleam starts with composable typed computations and derives execution
  dependencies from their composition.

You gain:

- Compile-time wiring validation.
- No missing result names.
- No incorrect argument keys.
- No runtime downcasts.
- Typed branches and compensation.
- Cycles largely unrepresentable by ordinary construction.

You give up:

- Completely open runtime graphs.
- Easy workflow serialization.
- Configuration-defined heterogeneous steps.
- Some generic introspection and graph rewriting.

## Feasibility verdict

The intended Erlang-target implementation includes concurrency, retries,
process isolation, and saga rollback. Their acceptance obligations remain
separate from the serial laboratory evidence.

The best implementation would use:

1. Canonical `Definition(i, o, e, u)` authoring with typed ports; unrestricted
   local fragments remain a retained capability whose admission is unresolved.
2. Typed composition through current `and_then` and `pair`; value-dependent
   branching and bounded traversal remain proposed capabilities.
3. Memoized nodes so shared dependencies execute once.
4. Node-owned typed results instead of a central heterogeneous result map.
5. Closure-packed undo actions for a homogeneous rollback journal.
6. Separate metadata for tracing and visualization.
7. A workflow-specific error ADT.
8. Erlang processes/tasks underneath for concurrent execution.

Saga preserves Reactor’s overlapping execution semantics rather than its DSL
or internal structs. Typed dependency construction replaces named runtime
wiring; scheduling, concurrency, retry, compensation, and undo still require
behavioral comparison.

## Runtime-authored graph scope

Runtime-authored graphs remain a distinct retained Saga capability. The initial
static facade does not represent types introduced after compilation. Blueprint
owns finite runtime data contracts, schema validation, and codecs; Saga owns
node registration, graph type checking, publication, and execution. The schema
and codec semantics below remain Saga requirements. Current schema examples use
Blueprint’s checked contracts; proposed graph-only sketches retain placeholders
where no runtime graph implementation exists. They are not a
second Saga-owned data-contract library. LLM execution composes the standalone
LLM client; Fabric is optional agent policy, not Saga's provider transport.

The key is a two-level type system:

1. Gleam types statically type the predefined node implementations.
2. JSON Schemas type the values and connections created at runtime.

A runtime schema cannot become a new native Gleam type—the compiler has already
run—but it can produce an opaque, schema-validated runtime value with equivalent
safety inside the graph engine.

Assuming “no recursion” means no cyclic `$ref`: arrays and nested objects are
still finite schema trees. If you mean strictly flat JSON objects, the same
model becomes even simpler.

## Runtime type model and validated values

Current laboratory signature excerpt from
[`blueprint_runtime.gleam`](playground/interface_lab/src/lab/blueprint_runtime.gleam)
(`from_schema`, `validate`, `encoded`); exercised by the
[runtime-schema consumer](playground/interface_lab/src/consumers/runtime_schemas.gleam).
Bodies/imports are omitted; `blueprint.Schema` and `Value` refer to the existing
laboratory modules, not new Saga-owned types.

```gleam
pub fn from_schema(
  schema: blueprint.Schema,
) -> Result(RuntimeContract, ContractError)

pub fn validate(
  contract: RuntimeContract,
  value: Value,
) -> Result(ValidatedValue, ValidationError)

pub fn encoded(value: ValidatedValue) -> Value
```

The opaque runtime contract and validated value replace the original Saga-local
`Schema`, `JsonValue`, and `TypedValue` constructors. The implemented finite
language covers the documented Blueprint subset. General `OneOf`, arbitrary
number constraints, nested runtime graph accessors, and broader schema families
remain requirements beyond that subset; declarations must reject unsupported
forms explicitly. The exact-number leaf is still not integrated into laboratory
`Value.Int`.

Runtime graphs must pass validated values between nodes. Checked field access
must derive the field contract and return a located access failure; the original
`get_field` sketch is not an implemented Blueprint export. Static domain values
still require their retained native codec after schema validation.

## Parametric node definitions

The following graph-only sketches are proposed and unimplemented. `Schema`
means Blueprint’s `RuntimeContract`, `JsonValue` means its wire `Value`, and
`TypedValue` means its opaque `ValidatedValue`; these are explanatory aliases,
not Saga exports. Node/port IDs, registry errors, and runtime context still need
concrete ownership and checked constructors. The examples describe type
relationships without asserting a compilable adapter.

Predefined node kinds can have type parameters:

```text
Identity<T>       : T → T
Delay<T>          : T → T
Choose<T>         : Bool × T × T → T
Collect<T>        : T... → Array<T>
Constant<T>       : () → T
Validate<T>       : Json → T
Map<A, B>         : Array<A> × Graph<A, B> → Array<B>
LLM<Input, Output>: Input → Output
```

Represent their signatures with a small type-expression language:

Proposed, unimplemented sketch (the schema leaf in this expression language is a Blueprint runtime contract):

```gleam
pub opaque type TypeVariable {
  TypeVariable(Int)
}

pub type TypeExpression {
  Concrete(Schema)
  Variable(TypeVariable)
  ArrayOf(TypeExpression)
  OptionalOf(TypeExpression)
  ObjectOf(List(TypeField))
}
```

Proposed, unimplemented sketch (the stored contract references below are owned by Blueprint):

A node definition could be:

```gleam
pub type NodeDefinition {
  NodeDefinition(
    kind: NodeKind,
    version: Int,
    inputs: List(PortDefinition),
    outputs: List(PortDefinition),
    configuration_schema: Schema,
  )
}

pub type PortDefinition {
  PortDefinition(
    port: PortKind,
    value_type: TypeExpression,
  )
}
```

For `Identity<T>`:

Proposed, unimplemented sketch:

```gleam
NodeDefinition(
  kind: IdentityNode,
  version: 1,
  inputs: [
    PortDefinition(InputPort, Variable(TypeVariable(0))),
  ],
  outputs: [
    PortDefinition(OutputPort, Variable(TypeVariable(0))),
  ],
  configuration_schema: empty_object_schema(),
)
```

## Instantiation and unification

When a user connects an `Order` output to `Identity<T>`:

```text
CreateOrder.output: Order
          ↓
Identity<T>.input: T
```

The graph validator unifies:

```text
T = OrderSchema
```

The instantiated node becomes:

```text
Identity<Order> : Order → Order
```

Its output schema is now automatically `OrderSchema`.

If another consumer expects `CustomerSchema`, the connection is rejected before
execution.

Proposed, unimplemented sketch. `TypedValue` is explanatory shorthand for
Blueprint’s opaque `ValidatedValue`; it is not a Saga export. `Schema` and
`JsonValue` retain the `RuntimeContract` and `Value` aliases defined above:

```gleam
pub fn instantiate_node(
  definition: NodeDefinition,
  incoming: List(ConnectedPort),
  configuration: TypedValue,
) -> Result(InstantiatedNode, List(TypeError))
```

Proposed, unimplemented sketch (schema bindings are references to Blueprint contracts):

Internally:

```gleam
pub type TypeBindings {
  TypeBindings(Dict(TypeVariable, Schema))
}
```

The unifier handles cases such as:

```text
T                    = Order
Array<T>             = Array<Order>
Optional<T>          = Optional<Order>
Object { value: T }  = Object { value: Order }
```

Because schemas cannot be cyclic, unification and assignability checks are
bounded by the finite schema trees.

## Runtime node interface

Once instantiated, every node has concrete input and output schemas:

Proposed, unimplemented sketch. `TypedValue` is explanatory shorthand for
Blueprint’s opaque `ValidatedValue`; it is not a Saga export. `Schema` and
`JsonValue` retain the `RuntimeContract` and `Value` aliases defined above:

```gleam
pub opaque type InstantiatedNode {
  InstantiatedNode(
    id: NodeId,
    kind: NodeKind,
    input_ports: List(InstantiatedPort),
    output_ports: List(InstantiatedPort),
    run: fn(NodeInputs, RuntimeContext) ->
      Result(NodeOutputs, NodeError),
  )
}
```

Proposed, unimplemented sketch. `TypedValue` is explanatory shorthand for
Blueprint’s opaque `ValidatedValue`; it is not a Saga export. `Schema` and
`JsonValue` retain the `RuntimeContract` and `Value` aliases defined above:

The execution interface can be homogeneous:

```gleam
pub type NodeInputs {
  NodeInputs(Dict(PortId, TypedValue))
}

pub type NodeOutputs {
  NodeOutputs(Dict(PortId, TypedValue))
}
```

Although this uses dictionaries, it is not stringly typed:

- `PortId` is opaque.
- Every port has a validated schema.
- Values are opaque `TypedValue`s.
- The graph was type-checked before execution.
- Node outputs are validated against the declared output schemas.

A node cannot successfully emit an invalid value:

Proposed, unimplemented sketch (validation and codec errors use Blueprint's checked APIs):

```gleam
pub fn output(
  port: InstantiatedPort,
  value: JsonValue,
) -> Result(TypedValue, NodeError) {
  validate_value(port.schema, value)
  |> result.map_error(InvalidNodeOutput(port.id, _))
}
```

## Predefined generic implementations

Many parametric nodes do not need to understand the concrete type.

### Identity

The proposed node must use the checked runtime contract, preserve located errors,
and return validated output. No executable runtime-node adapter exists for this
operation; its native implementation and publication checks remain required.

### Choose

The proposed node must use the checked runtime contract, preserve located errors,
and return validated output. No executable runtime-node adapter exists for this
operation; its native implementation and publication checks remain required.

The node has signature:

```text
Choose<T>: Bool × T × T → T
```

Validation ensures both branches have compatible schemas.

### Constant

The user configures both a schema and a value:

```json
{
  "schema": {
    "type": "object",
    "properties": {
      "currency": { "type": "string" },
      "amount": { "type": "number" }
    },
    "required": ["currency", "amount"],
    "additionalProperties": false
  },
  "value": {
    "currency": "BRL",
    "amount": 100
  }
}
```

At graph publication time:

1. Parse the schema into `Schema`.
2. Validate the configured value.
3. Bind `T` to that schema.
4. Instantiate `Constant<T>: () → T`.
5. Store the normalized schema and value.

### LLM structured output

An LLM node could be parameterized by arbitrary finite schemas:

```text
LLM<Input, Output>: Input → Output
```

Its configuration supplies:

- Input schema.
- Output schema.
- Prompt template.
- Model configuration.

The model response is not trusted. The proposed adapter must compose Blueprint’s
checked runtime contract and the standalone LLM boundary:

Proposed, unimplemented sketch:

The proposed node must use the checked runtime contract, preserve located errors,
and return validated output. No executable runtime-node adapter exists for this
operation; its native implementation and publication checks remain required.

## Domain-specific nodes remain statically typed

The current schema-aware boundary uses the existing opaque Blueprint codec,
not the original public record with an infallible encoder. Its concrete operations
are documented in [Blueprint](blueprint-design.md#native-codecs-and-composition)
and implemented by [`blueprint.gleam`](playground/interface_lab/src/lab/blueprint.gleam)
(`encode`, `decode`, `schema`). Encoding returns `Result(Value, EncodeError)`;
schema discovery returns an explicit unavailable outcome for custom codecs.

A native `fn(Order) -> Result(Reservation, InventoryError)` remains the target
node implementation. The proposed runtime-node adapter must retain the actual
input/output codecs, validate schema compatibility, decode before invocation,
check encoding failure, and validate the encoded output. No `typed_node` runtime
graph adapter exists yet; static Saga activities are different evidence.

## Graph publication

I would distinguish drafts from executable graph versions:

Proposed semantic sketch, not a current laboratory API. Helper types and
functions are placeholders; scheduling, persistence eligibility, and checked
boundaries must be specified before implementation.

```gleam
pub type GraphStatus {
  Draft
  Published
  Retired
}
```

A draft may temporarily contain incomplete or invalid wiring. Publishing
performs the full compilation:

Proposed semantic sketch, not a current laboratory API. Helper types and
functions are placeholders; scheduling, persistence eligibility, and checked
boundaries must be specified before implementation.

```gleam
pub fn publish(
  draft: DraftGraph,
  registry: NodeRegistry,
) -> Result(PublishedGraph, List(GraphError))
```

Publication should:

1. Decode every configuration.
2. Resolve node definitions and versions.
3. Instantiate type parameters.
4. Unify all connected ports.
5. Derive output schemas.
6. Detect cycles.
7. Validate constants and defaults.
8. Check required inputs.
9. Validate graph-level input/output schemas.
10. Produce an immutable `PublishedGraph`.

Execution only accepts `PublishedGraph`.

## Schema compatibility

Connections do not necessarily require structural equality. Define assignability
deliberately.

For example, an output with additional fields might be acceptable:

```text
Producer:
{
  id: String,
  email: String,
  name: String
}

Consumer:
{
  id: String,
  email: String
}
```

That can be accepted if object values use width subtyping:

```text
producer output <: consumer input
```

Useful rules include:

- Exact primitive types.
- Required consumer fields must exist in producer.
- Producer constraints must be at least as strict where necessary.
- `T` assignable to `Optional<T>`.
- Arrays are covariant only if values are immutable.
- Closed objects reject unexpected fields when values are reconstructed.
- Numeric coercions should be explicit nodes, not implicit conversions.
- `OneOf` compatibility requires careful exhaustive checking.

Keep the first implementation conservative: exact structural equality plus
explicit transformation nodes. Subtyping can be added later.

## Important limitation

A schema-typed runtime value is not the same as a native type parameter:

Proposed semantic sketch, not a current laboratory API. Helper types and
functions are placeholders; scheduling, persistence eligibility, and checked
boundaries must be specified before implementation.

```gleam
Plan(Order)
```

A schema loaded from the database cannot cause Gleam to manufacture a new static
type such as:

Proposed semantic sketch, not a current laboratory API. Helper types and
functions are placeholders; scheduling, persistence eligibility, and checked
boundaries must be specified before implementation.

```gleam
Plan(UserCreatedAtRuntime)
```

Instead, it becomes:

Proposed semantic sketch, not a current laboratory API. Helper types and
functions are placeholders; scheduling, persistence eligibility, and checked
boundaries must be specified before implementation.

```gleam
Plan(TypedValue)
```

with an opaque guarantee that the value conforms to a particular runtime schema.

That is not weak typing. It is essentially a small runtime type system
implemented in Gleam. The graph validator acts as its type checker.

## Recommended model

The resulting architecture would be:

```text
Predefined node implementation
    ├── static Gleam implementation types
    ├── parametric port signature
    ├── configuration schema
    └── version

User-created node instance
    ├── selected predefined node kind
    ├── concrete configuration
    ├── inferred/concrete port schemas
    └── graph connections

Published graph
    ├── all type variables resolved
    ├── all connections checked
    ├── all values validated
    └── executable later without type discovery
```

So yes: finite JSON Schemas plus predefined parametric nodes give you
user-created, serializable, runtime-typed Reactor graphs without `Dynamic`,
without string-encoded dependency types, and without allowing arbitrary untyped
code into the system. This is likely the best balance between a flexible visual
workflow builder and Gleam’s strong static core.

## Oracle and acceptance obligations

Reactor `v1.0.6` is the pinned behavioral oracle for overlapping scheduling,
retry, compensation, undo, and in-memory halt/resume scenarios. Its
[source and tests](https://github.com/ash-project/reactor/tree/v1.0.6) were
inspected in [workflow research](research/workflow-boundaries.md); the upstream
suite was not run locally. Native typed construction deliberately replaces its
dynamic DSL. Durable checkpoints and runtime schema graphs need original
contracts; Reactor halt is not process-loss durability. Exact parity applies
only to explicitly mapped scenarios, never the whole Reactor API.

The retained test strategy requires equivalent public differential scenarios
against that tag plus native compiler-negative, transition, concurrency, and
fault tests. Prove one execution per shared dependency, bounded concurrency,
typed failure mapping, failed-step compensation versus completed-step undo,
reverse completion order, accumulated undo failures, and cancellation with
active siblings. Test timeout/retry timing, branch settlement, resource limits,
and ambiguous effects independently of representation checks.

Durable tests must restart after commit boundaries, reject stale revisions and
incompatible codecs, recover missed wakes, coordinate parent/child admission,
release capacity in a single-slot queue, resolve cancellation/completion races,
enforce exclusive claims and command deduplication, and resume compensation
through retention and pruning. Runtime graphs require hostile-input publication,
cycle/resource limits, registry version, persistence, and execution tests.

Stable read-only introspection must retain labels, scoped identities,
dependencies, realized branches, and progress without exposing executable
closures or control over child internals. Sinal receives package-owned facts
after transitions; terminal local-report descriptors are demonstrated, while
native delivery and durable event ordering remain runtime obligations.

## Capability disposition

This inventory preserves the original design in commit `9194f02`. “Deferred”
means required implementation backlog, not removed product intent. The
[coverage matrix](API-COVERAGE.md#saga) and
[refinement status](playground/interface_lab/REFINEMENT-STATUS.md) record evidence.

| Original capability                                                                      | Disposition and owner                                                           | Required evidence                                                                                         |
| ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| Typed input/output, dependency validation, unified business and undo errors              | Retained in Saga canonical definitions and typed ports                          | Compiler negatives, codec-edge and native error probes; runtime boundary failures                         |
| `map`, `zip`, sequential composition, shared memoized dependencies                       | Retained; construction and serial subset demonstrated                           | One execution per dependency, adapters, bounded parallel Reactor scenarios                                |
| Fabric pure graph validation and associative multiple-writer reducers                    | Reassigned to Saga; retained beyond demonstrated composition                    | Cycles, missing producers, undeclared duplicate writers, unreachable outputs; reducer mapping unresolved  |
| Fabric historical review forks and checkpoint backends                                   | Reassigned durable execution to Saga integration; approval policy stays Fabric  | Memory/PostgreSQL revision fixtures, explicit prior-effect policy, restart and fork tests pending         |
| Bounded agent loops as workflow nodes and suspending agents                              | Retained integration; Fabric owns agent execution policy                        | Bounded iteration without graph cycles; one suspension owner, effect receipts, sub-agent consumer pending |
| Concurrent execution, process isolation, cancellation, timeout and backoff               | Retained, runtime work deferred in Saga                                         | OTP supervision, active-sibling cancellation, timers, resource and fault tests                            |
| Failed-step compensation, typed replacement, retry, reverse-order undo and undo failures | Expanded with explicit rollback permission and unresolved effects               | Serial recovery evidence; Reactor differential scenarios and concurrent settlement still required         |
| Value-dependent `and_then` and runtime homogeneous fan-out                               | Retained, deferred beyond closed choice                                         | Bounded traversal, ordering, cancellation, durable branch/version policy                                  |
| Arbitrary local transformations and closure-owned native results/undo                    | Retained; reconciliation with canonical authoring remains unresolved            | Local capability admission, no silent persistence of closures; do not lose expressiveness                 |
| Nested/composed reactors                                                                 | Expanded into direct composition and independent children                       | Typed construction and scripted owners; local authority, races, restart and compensation runtime tests    |
| Diagnostic labels, metadata, tracing and visualization                                   | Retained in Saga; observation transport belongs to Sinal                        | Stable read-only descriptors and runner facts without control-channel use                                 |
| Finite schemas, validated JSON values, codecs, parametric runtime nodes                  | Data contracts reassigned to Blueprint; graph typing retained in Saga, deferred | Schema/codec laws, exact-number boundaries, node instantiation and unification                            |
| Draft/publication/retirement, immutable executable graphs, registry versions             | Retained in Saga runtime-authored surface, deferred                             | Publication's ten validation checks, hostile graphs, persistence and execution                            |
| Exact structural compatibility with explicit transforms                                  | Retained; width subtyping and broader assignability deferred                    | Conservative connection tests; no implicit coercion or unchecked `OneOf` inclusion                        |
| Serialization of runtime-authored graphs                                                 | Retained; expanded with explicit durable definitions and freeze/thaw            | Snapshot codecs, fresh factory compatibility, crash recovery; never closure serialization                 |
| Arbitrary heterogeneous runtime steps and named native-result lookup                     | Original intentional exclusions retained                                        | Native typing negatives; schema-typed registered graphs are a separate surface                            |

The initial facade leaves these obligations open. No unrun Reactor conformance,
production scheduler, durable runner, or schema-graph implementation is claimed.
