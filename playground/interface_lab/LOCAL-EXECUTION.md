# Local execution over a workflow definition

## Question

- Can the canonical Saga definition retain enough local execution evidence to compensate completed activities without introducing another workflow builder?
- The experiment uses serial, explicitly interpreted work. It supplies no scheduler, worker process, persistence, retry policy, or exception boundary.

## Definition and admission

- Direct activities, shared dependencies, pair adapters, and sequence adapters use the existing definition graph.
- An unsupported approval, child, or choice node rejects admission before application callbacks run.
- The obsolete local callback plan is removed. The durable adapter's unfinished local facade remains separate until its complete contract can be supported.

## Execution ownership

- A reducer selects work and accepts correlated completions. A separate interpreter runs input encoding, activity callbacks, adapters, final decoding, and compensation.
- Read-only work descriptors expose the kind of work and its node address so a host can label observations without inspecting closures.
- A completion belongs to one issued work item and one local execution. A foreign or repeated completion cannot advance the current execution.
- Shared dependencies execute once in a linear history. Cancellation between activities stops issuing further forward work.
- Opaque state remains copyable. These checks do not prevent an application from replaying an old state or interpreting the same effect twice.

## Compensation evidence

- A successful activity retains an undo closure over its actual native input and output before output encoding.
- If output encoding fails after the callback succeeds, the retained closure can still compensate that activity. A wire roundtrip is not required to recover its native output.
- Compensation follows reverse actual completion order. An undo failure is recorded and remaining compensators still run.
- The terminal report keeps the original business failure, boundary failure, or cancellation distinct from undo failures and uncompensated successes. Activity and compensation failures retain their node addresses.
- Compensation does not prove that an external effect happened exactly once or that its inverse restored the external world.

## Remaining scope

- Retry exhaustion, compensation of a failing activity, in-flight cancellation, parallel execution, exception containment, approvals, and child execution remain separate experiments.
- Local post-success compensation authority and durable compensation receipts retain different ownership requirements.
- Checkpoint restoration, definition migration, OTP supervision, durable journals, and fault tests remain in [API coverage](../../API-COVERAGE.md).
