# Queue-bound worker registration

## Question

- Can an application register heterogeneous workers and select an exact deployed version without running callbacks or inventing native result types?
- This experiment reuses the canonical Grind worker. It adds no scheduler or claim authority.

## Registration and selection

- Registration binds a worker to a full queue route, worker identity, and worker version. A duplicate tuple rejects rather than replacing an existing handler.
- Multiple versions may coexist. Selection never silently falls back to a different version.
- Queue owner participates in route identity. Equal queue names under different owners remain independent.
- Selection returns an opaque erased worker that retains the original typed worker through a closure. Selection performs neither decoding nor handler execution.
- Explicit invocation uses the worker's existing codecs and preserves its input, output, business, and error-encoding outcomes.
- Read-only registration descriptors expose route and version identities without executable closures. An erased selection does not regain a caller-chosen native type.

## Consumer evidence

- Register heterogeneous workers, two versions of one worker, and two queue owners.
- Preserve ordinary typed invocation alongside erased dispatch.
- Connect an ordinary submission record to later exact selection. Submission itself must not execute the handler.
- Reject duplicate registration and unknown route, worker, or version before callback invocation.
- Preserve malformed payload, business failure, and output or error encoding failures.
- Compiler negatives reject an erased selection as a native worker and a worker identity as a version.
- A private-key process-local test adapter captures the actual submission record. The consumer reconstructs its typed worker identity and version, selects its full route, and invokes its exact payload. The handler count is zero after submission and one after explicit invocation.
- The coherent snapshot gate passes 57 isolated consumers, 84 intended compiler failures, 46 executable probe groups, and the existing independent schema, generation, and Relay checks.

## Remaining scope

- Registration establishes application configuration. It grants no permission to execute a scheduled job before its availability or without a current claim.
- Worker process lifetime, handler metadata, cancellation, deployed-code retention, codec migration, concurrent configuration replacement, and persisted storage remain separate obligations.
- The registry is immutable application configuration. The test adapter uses process-local storage; it supplies no concurrency or durability evidence.
