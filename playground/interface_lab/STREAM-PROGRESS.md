# Stream progress and tool completion

## Question

- Can interleaved tool-argument progress remain distinct from a completed tool-dispatch candidates, while failures retain whether progress was already accepted?

## Result

- The pure `llm_stream_events` reducer retains separate buffers under actual tool-result correlation IDs.
- `TextBlockId` and `CallId` are different types. A compiler fixture rejects exchanging them.
- Argument fragments remain strings until an injected decoder accepts the completed buffer.
- Completing one tool's arguments does not emit assembled dispatch candidates. `ToolsRequested` succeeds only after all declared calls have decoded arguments.
- Completed calls retain their declaration order even when their argument streams finish in the opposite order.
- Unknown calls, duplicate starts, deltas after argument completion, incomplete terminal calls, and events after termination are rejected.
- Failure classification records whether any progress event was accepted. This is a conservative retry signal, not automatic retry authorization.
- Local closure is idempotent and does not change a previously completed or failed outcome.
- Output-limited completion yields partial text without emitting partial tool calls.

## Evidence

- `stream_progress` exercises two interleaved calls, malformed and incomplete arguments, both failure classes, local closure, terminal rejection, and final text.
- The consumer uses a small scripted argument decoder. It does not test a JSON parser.
- The ordinary interface gate and the independent schema corpus still pass against the coherent committed baseline plus this wave.

## Limits and ownership

- This module represents a pure grammar. It does not implement `StreamingProvider`, a stream actor, transport, usage aggregation, provider event routing, or provider-bound continuation.
- A protocol error rejects the current input and leaves the old immutable state available. A production adapter must choose a terminal protocol failure and close its owned resource rather than ignoring malformed input.
- Gleam state values are copyable. Terminal rejection applies to transitions from the returned state; it cannot prevent use of an earlier copy.
- Accepted progress does not prove that an external consumer observed it. Classifying it conservatively prevents treating a later failure as definitely unobserved.
- The initial text outcome concatenates text deltas in event order. A richer content-block transcript remains separate work.
- Provider routing-key maps, a real argument decoder, capacity limits, backpressure, concurrent reads, cleanup, and full multi-turn continuation remain the [next streaming work order](../../research/llm-streaming-contract.md).

- Terminal calls remain dispatch candidates. Their public constructor and generic argument values do not grant schema validity, registry membership, authorization, or execution permission.
- Text block IDs are distinct from call IDs but are not retained in the concatenated text outcome. Multiple-block routing needs a separate adapter experiment.
- The reducer is pure when its injected decoder is pure; Gleam does not enforce purity for that callback.
