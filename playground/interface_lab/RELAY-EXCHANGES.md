# Relay exchange ownership

## Question

- Can a transport adapter interleave tool calls that reuse client identifiers without routing progress, completion, or cancellation to the wrong call?
- This experiment starts with parsed calls and the existing typed Relay registry. It does not parse JSON-RPC, admit HTTP headers, encode MCP messages, or open sockets.

## Identity and execution

- `ExchangeId` identifies one response destination. Fresh allocation occurs outside the pure reducer and supplies a unique value within the current Erlang VM.
- `InvocationId` identifies one admitted execution. The reducer derives it privately from the exchange identity; callers cannot substitute a wire request identifier.
- Client request identifiers and progress tokens remain payload metadata. They may repeat across independent exchanges without merging their execution state.
- An invocation retains the exact registry, request context, tool name, and arguments selected at admission. The explicit `perform` helper invokes that retained registry outside the reducer.
- Copying and performing an invocation twice can execute a handler twice. Suppressing duplicate completion messages does not establish exactly-once effects; the eventual owner must serialize and control execution.

## Lifecycle

- An admitted call emits an invocation once in one authoritative state history. Replaying its admission produces no second invocation.
- Progress requires the call's retained token and an increasing nonnegative value. The first experiment supports integer progress; the protocol also permits fractional values.
- Completion targets the retained exchange and wire request identifier, then closes the stream. Repeated completion produces no additional response.
- Closing an active exchange records cancellation and suppresses later progress and completion. Cancellation is an intent, not proof that an external effect stopped or was undone.
- Closure before admission leaves a tombstone without inventing client metadata. Later admission of that exchange produces no invocation.
- Closed and completed exchanges remain in the bounded model for stale-event checks. Production retention and resource limits remain unresolved.

## Evidence and limits

- The consumer interleaves two calls with identical client identifiers and different request contexts. It checks destination isolation, terminal suppression, and cancellation without creating a second tool registry.
- The model uses one authoritative sequence of state transitions. Gleam's copyable state values cannot enforce that ownership rule.
- Exchange identities do not need to survive a socket or VM restart in this prototype. A real adapter must prevent stale callbacks from aliasing a new exchange during its own lifetime.
- Tool results retain semantic dispatch errors. Protocol error classification, sanitization, modern result encoding, discovery, pagination, authorization, byte parsing, backpressure, and transport cleanup remain separate experiments.
- The [Relay server contract](../../research/relay-server-contract.md) records the larger protocol scope and pinned oracle requirements. This reducer does not establish MCP conformance.
