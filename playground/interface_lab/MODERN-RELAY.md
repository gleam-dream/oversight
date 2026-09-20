# Modern Relay server composition

## Question

- Can modern MCP discovery, listing, and calls reuse one protected tool registry and the existing exchange owner?
- This experiment targets parsed JSON values for revision `2026-07-28`. It introduces no HTTP server or legacy initialization state.

## Request admission

- Requests retain string or integer identifiers, required protocol version and client capabilities, optional progress tokens, and extension metadata.
- Protocol members must have unambiguous names and valid shapes before dispatch. The laboratory has no floating-point JSON value, so numeric identifiers and progress remain an integer subset.
- Unsupported versions, invalid envelopes, unknown methods, and invalid parameters remain separate outcomes. Unknown identifiers are omitted from error responses.
- Valid unsupported notifications and inbound responses produce a non-wire disposition for the transport owner. They produce no ordinary JSON-RPC response or invocation.
- Tool arguments default to an empty object when absent. A supplied non-object value is a protocol error before domain decoding.
- Supplied continuation parameters and cursors are unsupported in this slice. They are rejected explicitly rather than discarded before executing an unrelated call.

## Registry and exchange ownership

- The protected registry remains the source of declarations and actual tool dispatch. Tool listing rechecks the admitted grant's resource and scopes. Protocol discovery describes the server.
- An invocation retains the selected dispatch callback with its actual grant and application context. Performing it calls protected dispatch again, so visibility and execution policy precede domain decoding.
- Hidden, unknown, and denied names have the same external classification. Internal causes remain separate from the sanitized protocol result.
- The existing exchange reducer owns immediate responses, invocation identity, progress, completion, and cancellation effects. Immediate replies consume the same exchange identity as tool calls; a closed or previously consumed exchange cannot answer again. Repeated wire identifiers do not identify a runtime task or transport destination.
- The optional server information field is omitted; the library does not invent an application identity.
- Application execution remains an explicit effect interpretation. Closing an exchange suppresses later wire output; it does not prove that an external business effect stopped.

## Response contract

- Every successful modern result includes `resultType: "complete"`. Tool errors remain successful JSON-RPC responses with `isError: true`.
- Output and error encoding failures become sanitized protocol failures rather than fabricated successful tool results.
- Discovery and listing emit `cacheScope: "private"` and `ttlMs: 0`. Listing returns one terminal page; this establishes no authorization-sensitive cursor or cache ownership.
- Structured tool output uses the current schema's general JSON value boundary. Rich content families and output-schema declarations remain separate work.
- The [frozen upstream schema](oracles/mcp_2026/README.md) supplies independent structural validation. Negative mutations check that required response fields are enforced by that validator.

## Remaining scope

- JSON byte parsing, general JSON numbers, HTTP headers and framing, bearer admission, body limits, SSE cleanup, live cancellation, and backpressure require transport work.
- Pagination, cache ownership, annotations, output schemas, remaining server families, client operations, continuations, and legacy revision compatibility remain in [API coverage](../../API-COVERAGE.md).
- Pure exchange histories and schema-valid response fixtures do not establish concurrent runtime ownership or complete MCP conformance.
