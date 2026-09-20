# Independent child lifecycle contract

## Question and status

- The experiment asks how an independently owned Saga run can be submitted, attached to a parent after submission or completion, recovered after the parent restarts, cancelled, and compensated through public interfaces.
- The current `Child` type separates ownership during graph construction, while `execute_child` has no runner and `CompensationReceipt` has no public owner.
- The current durable handle retains only a run identifier, and `ChildWait` persists only that identifier and one revision.
- Those values cannot establish definition compatibility, terminal codec compatibility, retention, or compensation authority after restart.
- This note proposes type and consumer work only. It does not claim a journal, queue, scheduler, or race behavior.

## Recommendation

- Keep a child as an independent Saga run whose owner controls its journal, scheduling, cancellation, and compensation.
- Put definition identity, definition version, and boundary codec versions in one typed `ChildContract(i, o, e, u)` built from the deployed `Definition(i, o, e, u)`.
- Let `saga_grind` expose a configured durable owner explicitly. Do not hide an ambient runner behind `request_child_compensation(receipt)`.
- Return a persistable `ChildLink` from submission or attachment. The link is routing and compatibility data that a Saga, Fabric continuation, or application checkpoint can store without importing child internals.
- Require a fresh compatible definition when attaching or reattaching. Generic types must be anchored in the retained contract codecs; persisted identity and codec versions decide whether stored data may be decoded.
- Keep local closure receipts and durable owner references as different types because only the latter can survive process loss.

## Proposed public shape

The names are provisional. The separation is the experiment.

```gleam
pub opaque type ChildContract(i, o, e, u)

pub type BoundaryVersions {
  BoundaryVersions(
    input: Version,
    output: Version,
    error: Version,
    undo_error: Version,
  )
}

pub fn child_contract(
  definition: Definition(i, o, e, u),
  versions: BoundaryVersions,
) -> ChildContract(i, o, e, u)

pub type CompensationRetention {
  DiscardCompensationOnCompletion
  RetainCompensationUntil(Timestamp)
}

pub type ChildRetention {
  ChildRetention(
    terminal_result_until: Timestamp,
    compensation: CompensationRetention,
  )
}
```

- `ChildContract` uses the definition's codecs rather than accepting a second set that could disagree with the graph.
- The four boundary versions describe the persisted input and terminal success, failure, and undo-failure values. Activity codec versions do not substitute for these run-boundary versions.
- The run record stores the definition identity, definition version, structural compatibility value once settled, and all four boundary versions.
- Terminal-result retention and compensation-journal retention are separate. A completed run may remain readable after compensation details have been discarded.

The durable integration should expose an owner on every operation:

```gleam
pub opaque type DurableOwner
pub opaque type DurableChild(o, e, u)
pub opaque type ChildLink
pub opaque type DurableCompensationReceipt(u)
pub opaque type DurableCompensationReceiptRef
pub opaque type CompensationHandle(u)

pub fn submit_child(
  owner: DurableOwner,
  contract: ChildContract(i, o, e, u),
  input: i,
  retention: ChildRetention,
  command: CommandId,
) -> Result(DurableChild(o, e, u), SubmitError)

pub fn attach_child(
  owner: DurableOwner,
  contract: ChildContract(i, o, e, u),
  run_id: RunId,
) -> Result(DurableChild(o, e, u), AttachError)

pub fn child_link(child: DurableChild(o, e, u)) -> ChildLink

pub fn reattach_child(
  owner: DurableOwner,
  contract: ChildContract(i, o, e, u),
  link: ChildLink,
) -> Result(DurableChild(o, e, u), AttachError)
```

- `submit_child` is asynchronous. Success means that the owner durably accepted one logical run and its delivery work; it does not return the child result.
- Repeating `submit_child` with the same command, contract, and encoded input must return the original child. Reusing that command for different admission data returns a conflict. This recovery rule does not make an external activity execute exactly once.
- `attach_child` attaches to an existing run by identifier and validates its stored contract before returning a typed handle. It works whether the run is active or terminal.
- `reattach_child` validates the link's owner identity, definition identity and version, and boundary codec versions against both the deployed contract and stored run.
- `ChildLink` needs a codec and must contain the owner namespace, run identifier, contract identity, and boundary versions. It is not a credential.

## Observation and typed result

```gleam
pub type DurableChildState(o, e, u) {
  ChildQueued(revision: Int)
  ChildRunning(revision: Int)
  ChildWaiting(revision: Int, reason: ChildWaitReason)
  ChildCompleted(
    revision: Int,
    historical_output: o,
    compensation: ChildCompensationView(u),
  )
  ChildFailed(revision: Int, cause: e, undo_failures: List(u))
  ChildCancelled(revision: Int, undo_failures: List(u))
  ChildNeedsReconciliation(revision: Int, evidence: List(AmbiguousEffect))
}

pub type ChildCompensationView(u) {
  CompensationDiscarded
  CompensationClaimable(until: Timestamp)
  CompensationClaimed
  CompensationRequested(status: CompensationStatus(u))
}

pub fn observe_child(
  owner: DurableOwner,
  contract: ChildContract(i, o, e, u),
  child: DurableChild(o, e, u),
) -> Result(DurableChildState(o, e, u), ObserveError)
```

- `observe_child` rechecks stored contract metadata before decoding a terminal value. An opaque typed handle alone is insufficient after persistence or deployment changes.
- Definition mismatch, codec-version mismatch, unavailable retained result, corrupt terminal data, owner unavailability, and ordinary nonterminal state remain distinct outcomes.
- `ChildCompleted` reports that the forward run historically produced an output. Its compensation view states whether that effect remains uncompensated, is being compensated, was compensated, failed compensation, or needs reconciliation.
- A compensation success does not erase the historical output, while the observation no longer implies that the forward effect still holds.
- `ChildNeedsReconciliation` is neither a retryable failure nor a cancelled child. The parent remains suspended until an explicit resolution is committed by the child owner.
- A notification may wake a parent, while committed owner state is the control source. Reattachment must recover from a missed notification.

## Parent checkpoint and independent resume

- Replace the current string-only `ChildWait` with a persisted child attachment containing the parent step identity, `ChildLink`, last observed child revision, and any stable cancellation or compensation command identifiers already issued.
- The parent must commit that attachment before it treats child submission or adoption as a completed scheduling decision.
- A parent-submitted child can otherwise become an orphan if the parent crashes after admission but before recording its identifier. Replaying the stable submission command must recover the original link, after which the parent can commit it without creating another child.
- A shared owner may coordinate child admission and parent-link recording in one transaction or outbox. An external parent may use the idempotent public submission rule plus an explicit orphan-retention policy instead of sharing journal internals.
- A parent adopting an already completed child records the same link before decoding and committing the child's output to the parent step.
- After restart, `restore` returns a waiting parent plus its child attachment. The host calls `reattach_child`, observes committed child state, then compare-and-set commits the typed terminal outcome or a newer wait revision to the parent journal.
- The parent releases its Grind worker while waiting. Child completion never requires the original parent process, worker, or in-memory closure.
- A Fabric or application parent can store the same `ChildLink` in its own continuation and perform the same public reattachment sequence. Shared journal internals are not required.

## Cancellation ownership

```gleam
pub fn request_child_cancellation(
  owner: DurableOwner,
  child: DurableChild(o, e, u),
  command: CommandId,
) -> Result(CancelOutcome, CancelError)
```

- The parent owns the policy decision to propagate cancellation. The child owner owns the durable intent, stopping new admissions, settling running work, child compensation, and final outcome.
- The parent does not cancel a Grind delivery job directly and does not mark the child cancelled locally.
- A stable command makes a restarted parent repeat the same logical request.
- When terminal completion wins the race, cancellation returns `RunAlreadyTerminal`; the parent then applies its declared completed-child policy.
- When cancellation intent wins, the child may still finish, cancel with undo failures, or require reconciliation because an in-flight effect is ambiguous. Runtime race tests must establish those transitions.

## Compensation retention and receipts

- Completion alone does not grant compensation authority.
- `DiscardCompensationOnCompletion` makes receipt issuance impossible even when the definition contains compensators.
- `RetainCompensationUntil` asks the owner to retain the successful run's compensation journal through a deadline. The owner issues a durable receipt only after confirming that the run succeeded, the policy is still live, the journal remains usable, and compensation has not already been claimed incompatibly.
- Result attachment can be repeated by readers. Compensation claim should initially be exclusive to one parent run and child step, because two independent parents compensating one reused effect would give the result contradictory meaning.

```gleam
pub fn claim_child_compensation(
  owner: DurableOwner,
  child: DurableChild(o, e, u),
  claimant: ParentAttachment,
  command: CommandId,
) -> Result(DurableCompensationReceipt(u), ReceiptError)

pub fn compensation_receipt_ref(
  receipt: DurableCompensationReceipt(u),
) -> DurableCompensationReceiptRef

pub fn rebind_compensation_receipt(
  owner: DurableOwner,
  contract: ChildContract(i, o, e, u),
  reference: DurableCompensationReceiptRef,
) -> Result(DurableCompensationReceipt(u), ReceiptBindError)

pub fn request_child_compensation(
  owner: DurableOwner,
  receipt: DurableCompensationReceipt(u),
  command: CommandId,
) -> Result(CompensationHandle(u), ChildCompensationError)

pub type CompensationStatus(u) {
  CompensationPending
  CompensationRunning
  CompensationSucceeded
  CompensationFailed(undo_failures: List(u))
  CompensationNeedsReconciliation(evidence: List(AmbiguousEffect))
}

pub fn observe_child_compensation(
  owner: DurableOwner,
  handle: CompensationHandle(u),
) -> Result(CompensationStatus(u), CompensationObservationError)
```

- The parent persists the issued receipt reference before relying on it for later rollback.
- Repeating a claim with the same command and claimant returns the same logical receipt, so a crash between claim and parent persistence remains recoverable. Conflicting claim data returns a typed conflict.
- `DurableCompensationReceipt(u)` originates from a `DurableChild(o, e, u)` that was attached through a matching contract, so its failure type follows that contract's retained undo-error codec.
- `DurableCompensationReceiptRef` stores the owner, run, claim, definition, and codec identities as data without claiming a native `u`.
- After restart, the parent rebinds the nongeneric receipt reference with a fresh compatible child contract. The owner checks the run definition and retained undo-error codec version before returning `DurableCompensationReceipt(u)`.
- The owner validates retention, claim identity, current child state, and command deduplication on every request.
- A compensation request is asynchronous. Repeating the request command returns the same logical handle; observation reports pending, running, successful, failed with typed undo failures, or reconciliation-required state.
- The receipt and handle are copyable routing evidence. They do not authenticate the caller, prevent copied requests, or prove that a remote compensating effect executes exactly once.
- Application or transport authorization remains outside the opaque type. Store deduplication supplies one logical request, while downstream idempotency, fencing, transactions, or reconciliation address duplicate external effects.
- A local runner may instead return `LocalCompensationReceipt`, which retains an in-memory closure or local owner reference. It cannot be encoded, placed in `ChildLink`, or passed to the durable compensation function.
- A local receipt is also copyable. A local owner must still deduplicate requests if its API promises one logical compensation request.

## Decisive consumer

1. Submit an independent checkout child with versioned boundary codecs, retained terminal result, and retained compensation journal; let it complete before a parent exists.
2. Start a parent definition and attach that completed run with the matching contract. Make the scripted owner reject the same run when a contract has the same native Gleam types but the wrong definition identity, definition version, or output codec version.
3. Atomically record the `ChildLink` in the parent step, claim compensation for that parent attachment, checkpoint the parent, and discard all parent process state.
4. Restore the parent with a fresh deployed definition, reattach through the explicit owner, and recover the typed checkout output without rerunning the child.
5. Before the restored parent observes that the child already completed, race its stable cancellation command with terminal observation. Require the owner to return `RunAlreadyTerminal`; a separate active-child fixture may produce a recorded cancellation intent. Never let the parent fabricate `ChildCancelled` from its stale view.
6. Follow the completed-child branch, fail a later parent activity, rebind the persisted receipt reference with a fresh matching contract, and request compensation through the owner with a stable command.
7. Repeat that compensation request and require the same logical handle. Observe pending, running, and successful compensation, then require child observation to retain the historical output while reporting successful compensation. Also attach the result from another reader and require its compensation claim to fail as already claimed.
8. Expire or prune retention in a second fixture and require a typed unavailable outcome rather than a receipt reconstructed from the run identifier.

## Work order and evidence boundary

1. Add `ChildContract`, boundary versions, retention types, and separate local and durable receipt types without implementing execution.
2. Add conceptual owner-backed submit, attach, reattach, observe, cancel, claim, and compensation signatures; remove the ownerless compensation request.
3. Extend the concrete checkpoint envelope with an encodable `ChildLink`, nongeneric durable receipt reference, parent step identity, observed revision, and stable command identities.
4. Compile negative fixtures for incompatible native output or undo-error types, a local receipt at a durable API, and a child used as a parent-owned activity. Exercise same-native-type definition and codec identity mismatches as scripted owner rejection probes because the Gleam compiler cannot reject runtime version values.
5. Add pure scripted owner states to exercise the public outcome vocabulary. Label them type evidence rather than durable behavior.
6. Defer durability claims until one owner/store experiment proves admission and parent-link coordination, restart after every commit boundary, missed-wakeup recovery, result retention, cancellation/completion races, exclusive receipt claim, command deduplication, compensation recovery, and pruning.

- The type experiment can prove native input, output, error, and undo-error relationships, that local and durable receipts cannot be mixed, and that plain completion does not construct compensation authority.
- Only owner probes can show that the same native types with the wrong definition identity, definition version, or codec version are rejected before stored values are decoded.
- It cannot prove owner availability, store atomicity, authentication, exclusive use of a copyable handle, worker release, fair scheduling, or exactly-once external effects.
- This contract belongs to Saga plus its durable integration. It does not require a new universal child package or make Grind responsible for graph or compensation state.
