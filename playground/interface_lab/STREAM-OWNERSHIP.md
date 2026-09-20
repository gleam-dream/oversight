# Stream terminal transitions and provider continuation

## Question

- Can a stream boundary preserve terminal ownership, cleanup intent, and the original provider without exposing partial tool calls as completed work?
- This experiment composes the existing progress grammar with a pure owner transition model. It does not establish a shared live owner for copied stream handles.

## Terminal behavior

- Accepted progress continues through the existing grammar. Completed tool arguments alone do not publish a tool-request turn.
- Closing an open stream makes later provider events unable to create a new terminal result.
- A malformed event becomes a terminal protocol failure. The grammar's rejected input must not leave the owner silently open.
- Cleanup commands are emitted once per accepted terminal transition in a sequenced history. Repeated close does not repeat them in that history.
- A cleanup command is intent. Its presence does not establish that transport cleanup succeeded or that remote provider work stopped.
- Failures retain the distinction between before and after accepted progress. Neither classification itself authorizes retry.

## Provider continuation

- A pending tool turn retains its originating provider continuation and expected call identifiers.
- Result validation rejects missing, duplicate, and unknown identifiers before contacting the retained provider.
- Preparing a continuation validates results and retains the originating callback without opening a source. Opening the prepared value invokes that callback outside the reducer. Neither operation accepts a replacement provider, including when two providers use the same native continuation and source types.
- The callback returns an adapter-owned next-stream source. The experiment must consume a second scripted stream rather than force the continuation into an ordinary nonstream reply.
- Tool calls remain application dispatch candidates. They do not grant registry membership, schema validation, authorization, or execution permission.
- Copyable pending values do not enforce one-time continuation use. Replay protection remains an owner or durable-store responsibility.

## Evidence limits

- A pure transition history can establish terminal precedence, late-event handling, cleanup-command cardinality, and provider-bound callback selection.
- It cannot prove that copied capabilities share one process or that concurrent commands serialize.
- The [ownership work order](../../research/llm-stream-ownership-contract.md) requires an OTP probe for shared ownership, conflicting reads, owner death, and caller termination.
- Actual HTTP tests must establish socket cleanup, bounded buffering, backpressure, and provider-specific behavior.
- Final and output-limited continuations, usage, provider extensions, catalog admission, and persistent continuation formats remain part of the broader streaming scope.
