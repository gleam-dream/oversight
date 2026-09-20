# Typed uniqueness admission

## Question

- Can a typed worker use full-input or projected-key uniqueness while callers distinguish insertion, conflict, replacement, contention, and uncertain admission?
- This experiment extends Grind admission. It does not turn uniqueness into execution serialization or exactly-once effects.

## Identity and matching

- The storage owner and queue name form the queue route. Reconciliation retains that original route independently of the uniqueness key.
- A uniqueness domain includes worker identity and version. Queue identity participates only when the policy requests queue-local matching.
- A projected key has an explicit policy identity and version, and retains its actual encoder until preparation. Equal strings from different key policies do not share meaning implicitly.
- Full-input and projected keys are separate key contracts.
- A projected candidate must retain material for the same key-policy identity and version. An arbitrary projection closure cannot be reconstructed from a later incoming policy; ordinary jobs without that material need an explicit backfill or adapter strategy.
- The typed profile compares JSON-shaped values recursively. Object field order does not matter; duplicate fields are rejected recursively. Array order and multiplicity matter, and scalar constructors remain distinct.
- This equality is a deliberate profile choice. It does not claim parity with PostgreSQL containment or Oban Basic's selected-field behavior.
- The incoming period and state policy select eligible stored jobs. They do not silently create another uniqueness namespace.

## Admission and recovery

- Preparation encodes input and the selected key before calling storage. The prepared command retains the exact worker contract, route, policy, availability, and conflict action.
- Command receipt equality compares the exact retained request. JSON key equivalence does not imply that a reconstructed command is the same request.
- Stable submission identity provides command reconciliation even after a uniqueness period expires or a matching job changes state.
- The adapter owns current rows, authoritative time, command lookup, matching, insertion or replacement, and commit as one atomic operation.
- Across-queue matching remains within one storage owner. A conflict retains its actual queue route, which can differ from the submitting queue.
- An existing conflict is not a typed result handle. Binding requires compatible worker identity and version before retaining the worker's output and error codecs.
- Rescheduling requires an explicit requested timestamp. A reply must substantiate the eligible prior state, unchanged job and contract identity, and the requested new timestamp.
- The conservative replacement profile changes scheduled availability only. It does not replace worker identity, input, or an executing attempt's payload.
- A lock-contention result does not claim that an existing job was found.
- Unknown replies and invalid successful replies preserve the original route and command for reconciliation. Neither outcome proves that storage rejected admission.

## Evidence boundary

- The consumer derives matching, replacement, and command replay from immutable prior records. Recovery reuses the original decision timestamp and stored snapshots after the current row and matching window have changed.
- Pure cutoff arithmetic does not establish database timestamp precision, clock synchronization, transaction isolation, or concurrent uniqueness.
- Backend route labels do not authenticate storage or prove that two configured adapters share a database.
- Matching declared worker and key-policy versions does not prove semantic equivalence between independently supplied codecs. Applications must change those versions when their contracts change.
- Arbitrary state profiles, general replacement, cross-worker policies, bulk uniqueness, backend-specific optimizations, and the runtime oracle remain separate work in the full coverage inventory.
- The [pinned Oban study](../../research/grind-uniqueness-contract.md) records source behavior and the deliberate boundaries of this profile.
