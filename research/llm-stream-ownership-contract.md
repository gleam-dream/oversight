# LLM stream ownership experiment

## Question and status

- The existing stream grammar models accepted progress and terminal outcomes. It does not own a live transport or serialize commands from callers.
- The next experiment asks whether one small ownership boundary can support early close, copied handles, late provider events, and continuation through the original provider.
- This note proposes the next experiment. It does not establish a new public API or prove a live streaming runtime.

## Proposed boundary

- Keep the existing `llm_stream_events` grammar. Add an opaque stream capability that names one authoritative owner instead of exposing the immutable reducer state.
- A read returns progress, a terminal turn, or a classified provider failure. Distinct owner errors represent a closed stream, a conflicting read, and an unavailable owner.
- Closing reports local closure or an already terminal owner. Local closure must not claim that the provider confirmed cancellation of remote work.
- A completed tool-request turn carries the validated calls and an opaque pending continuation. The pending value retains the original provider instance, its continuation, and expected call identifiers.
- Continuing the pending value accepts results without accepting a replacement provider. Two adapters using the same continuation type must not become interchangeable by accident.
- Validate exact tool-result call-identifier coverage before contacting the retained provider. Missing, duplicate, and unknown identifiers remain explicit failures, matching the existing Fabric continuation boundary.
- Exact public names and placement remain unsettled. Reuse the existing tool-call, tool-result, progress, and failure types where their semantics match.

## First pure experiment

- Model one owner transition function around the existing grammar. It returns delivery and cleanup commands, while its state remains internal to the proposed owner.
- Exercise text progress followed by close. A terminal close transition requests provider cancellation and transport cleanup once in that modeled history.
- Feed progress, completion, and failure after close. None may create a new terminal turn or dispatch a tool.
- Feed a malformed event while open. The existing grammar returns `ProtocolError` without changing its state; the proposed owner must turn that error into a terminal protocol failure and request cleanup instead of leaving the stream open.
- Repeat close after every terminal path. The reducer must not request duplicate cleanup for the same accepted transition history.
- Compare failure before accepted progress with failure after text or tool progress. Preserve the existing conservative classification: accepted progress is not proof that a consumer observed it, and failure before progress is only potentially retryable.
- Use two provider instances with the same continuation representation. A pending continuation from the first must route back to the first without accepting the second as an argument.

## Decisive ownership experiment

- Copy a stream capability, close through one copy, then read and close through the other. Both copies must observe the same terminal owner state.
- A pure reducer cannot prove this property. Two independent immutable state copies can diverge even when each transition function is correct.
- A small OTP owner probe must establish shared process ownership, serialized commands, conflicting-read behavior, owner death, caller termination, and cleanup under supported termination paths.
- Real transport tests must establish socket cleanup, buffering limits, backpressure, late-event handling, and the distinction between local disconnect and remote cancellation.
- Command cardinality in a pure history does not establish successful cleanup or exactly-once execution of a cleanup effect across process loss.

## Open decisions

- Decide whether accepted progress and delivered progress need separate tracked facts. Do not weaken retry safety merely because a buffered event has not reached the caller.
- Decide whether final and output-limited turns need reusable continuations in the first ownership experiment.
- Keep provider-specific cancellation acknowledgement optional unless a concrete adapter can establish it.
- Determine continuation-consumption and replay semantics explicitly; opaque immutable values alone cannot guarantee one-time continuation use.

## Existing evidence

- [Stream progress](../playground/interface_lab/STREAM-PROGRESS.md) covers the common grammar and partial versus terminal tool information.
- [API coverage](../API-COVERAGE.md) retains live resource ownership, provider adaptation, retry policy, and continuation persistence as separate obligations.
