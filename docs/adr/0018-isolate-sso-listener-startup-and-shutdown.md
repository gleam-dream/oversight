# Isolate SSO listener startup and shutdown

<a id="adr-0018"></a>

## Decision

- The SSO application's server helper owns a Gleam actor around each Mist supervision tree.
- The owner traps linked startup exits without changing the caller's process flags.
- A refused bind returns the existing startup error. The application's bounded retry policy can then handle a transient refusal.
- Explicit shutdown and caller exit stop the Mist subtree before the owner exits. An abnormal Mist supervisor exit terminates the linked owner abnormally.

## Rationale and alternatives

- Validation on 16 October 2026 reproduced `Eaddrinuse` during the existing session restart consumer. Mist's failed linked supervisor startup terminated the caller before its retry could handle the returned error.
- A deterministic consumer holds the requested port, attempts startup from a separate process, and requires that process to recover by starting and stopping another listener. The original helper terminated that process; the owner returns the error.
- Waiting for the previous supervisor's termination remains necessary. That wait cannot prevent every competing bind or make a later startup failure safe for its caller.
- Changing the caller's exit-trapping flag would alter how it handles unrelated linked resources. A transient detached starter would leave the successful server without a live parent that owns its shutdown.

## Consequences

- Each listener has one additional owner process. The helper keeps the same start, address and stop interface; its PID identifies that owner.
- Restart retains the same address, cookie key and durable custody. No persisted format or authentication policy changes.
- Tests distinguish startup refusal, caller lifetime, listener rebinding and durable session restart. They use local listeners and disposable PostgreSQL.
