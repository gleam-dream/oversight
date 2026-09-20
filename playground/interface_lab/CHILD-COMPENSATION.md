# Durable child compensation authority

## Question

- Can a parent claim compensation for a completed child, persist a receipt reference, and recover an admitted compensation request without treating completion as authority?
- This experiment extends the durable owner used for child admission and observation. It introduces no second runner or compensation scheduler.

## Claim and reference

- A parent attachment identifies the parent owner, parent run, and one stable attachment within that run.
- Those identifiers do not authenticate a parent or prove that an attachment belongs to its definition. The configured adapter owns authorization and consistent attachment identity.
- The owner admits a first claim only for a successful child with an available, retained journal before its retention deadline.
- The owner records the exact claim command and one issued reference. Another claimant cannot acquire the same child's journal.
- A native receipt retains the actual undo-error codec. Its persisted reference contains routing and compatibility data rather than closures or a native type parameter.
- Rebinding requires a configured owner, a compatible child contract, and a recorded claim. Constructing a reference does not grant compensation authority.
- Replaying or rebinding a claim recovers its identity. It does not extend retention or establish that the journal is currently usable.

## Compensation request

- A request names the exact receipt and a stable command. The owner records admission separately from execution.
- The owner admits at most one compensation operation for a claim. Changing the command identifier cannot redeem a copied receipt again; any operation retry belongs to the already admitted operation.
- Command replay precedes fresh-admission checks. An already admitted request recovers the same handle after the original retention deadline; it does not start another compensation.
- A new request checks current retention and journal availability. Expiry and pruning remain distinct from absence, ownership conflict, and storage failure.
- Unknown replies and invalid successful replies preserve the original owner route, exact command, and native codec for explicit reconciliation.
- A failed retry does not resolve the original uncertain admission.

## Observation

- Pending, running, successful, failed, and uncertain compensation outcomes remain separate from the child's historical output.
- Historical success remains representable after output pruning. The owner can retain its compensation journal independently of the original result.
- Undo failures decode only after reference and compatibility checks.
- Compensation does not rewrite a child's earlier successful result or imply that a business effect was perfectly reversed.

## Evidence boundary

- The consumer threads immutable claim and request records through replay, competing claimant, lost acknowledgement, expiry, and pruning cases. Request admission checks the retained claim before redeeming its reference.
- The public receipt and handle cannot establish single use because Gleam values are copyable. The owner must enforce exclusivity and command deduplication in storage.
- No compensator, queue worker, database transaction, crash recovery, or concurrent journal operation runs in this experiment.
- The former ownerless receipt placeholder is removed. Local compensation authority remains an unfinished interface family; this durable contract does not silently supply it.
