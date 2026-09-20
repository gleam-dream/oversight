# Provider-bound structured turns

## Question

- Can one configured provider own schema admission, the transmitted output contract, and continuation without requiring Fabric?
- The earlier one-call helper decodes structured output locally but does not pass the requested output schema to its provider callback.
- A catalog admitted by an arbitrary policy does not establish compatibility with the provider later called.

## Configured turn boundary

- A configured adapter retains its model selection, native options, full-schema policy, and call callbacks. Policy receives the schema location, so a tool-input restriction need not apply to structured output.
- Preparation validates request limits and schema availability before calling the adapter. It distinguishes invalid local input from valid schema that the configured profile does not support.
- A prepared turn retains the native output codec and admitted tool and output schemas. Starting the turn supplies those schemas to the retained adapter.
- A pending tool turn retains the same adapter continuation and output codec. Resuming accepts results without accepting a replacement provider.
- Final values are decoded through the original output codec both before and after tool use.

## Consumer evidence

- Two scripted model profiles have different native configuration types and schema policies. These profiles make no claim about a commercial provider.
- Unknown model, unavailable or invalid schema, invalid local request, and unsupported nested finite enum fail before a sentinel transport callback. Located rejections distinguish output fields from each tool input.
- The adapter observes the actual admitted schemas. A second provider with the same continuation type cannot replace the originating callback.
- Empty call batches, duplicate call identities, and names absent from the admitted catalog reject before a pending turn is returned. Missing, unknown, or duplicate result identities reject before continuation. Invalid final output remains distinct from remote call failure.
- Standalone LLM owns generic call and result correlation. Fabric delegates to those checks. Both boundaries use the existing provider reply type.

## Remaining scope

- Streaming admission, production provider policies, live transport, persistence, model discovery, usage accounting, retry policy, and provider-specific remote rejection remain open.
- Runtime schema validation runs before the output codec. Schema-invalid output cannot enter its mapping callback; schema-valid values still pass through the retained native decoder.
- Prepared and pending values remain copyable. Retaining the provider prevents accidental substitution; it does not serialize calls or provide durable exactly-once execution.
