<!-- THROWAWAY: Can one typed registration supply invocation and discovery? -->

# Codec-derived catalogs

## Decision

- Blueprint remains independent of tool protocols.
- Supported codec constructors retain their accepted wire shape: string, integer, boolean, exact pair, and a closed object with one required field.
- `new` returns a usable codec with unknown schema. Schema discovery fails explicitly for that codec, including when it is nested inside a supported constructor.
- `imap` preserves the accepted wire shape under total user mappings. It does not prove inverse mappings, native roundtrip laws, or semantic refinements.
- `field("id", int())` accepts exactly one `id` property and preserves the native `Int` input type. Missing, extra, duplicate, and wrongly typed fields fail decoding.
- Relay rejects primitive and array input roots at discovery. Fabric's general declaration remains independent of provider restrictions.
- Each package derives declarations from its own registration's exact input codec. Context is supplied at invocation, not discovery.
- A package registry rejects duplicate names and unavailable declarations before it can be dispatched or advertised.
- The Fabric-to-LLM adapter derives model declarations from that registry. It introduces no reverse dependency into LLM or Blueprint.

## Evidence

- `derived_catalog` checks declaration agreement across adapters, typed dispatch with different request contexts, unknown names, duplicate names, object decoding failures, unavailable custom schemas, and Relay's object-root restriction.
- `registry_context` is a compiler-negative consumer: a string cannot replace the registry's integer context.
- The prior independent consumers remain valid. Invocation-only tools with custom codecs remain usable without discovery.
- `schema_value` emits Draft 2020-12 fragments; `schema_document` adds the dialect identifier. Exact tuples use `prefixItems`, `minItems`, and `maxItems` as described in the [JSON Schema array reference](https://json-schema.org/understanding-json-schema/reference/array).
- Relay's object-root check follows the [MCP release description](https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/).

- Validation on 2026-09-19: fifteen isolated consumers, fifteen intended compiler failures, and seven executable probe groups passed with Gleam 1.18.1.

## Limits and next pressure

- This is a small schema vocabulary, not JSON Schema conformance. No independent schema validator or upstream JSON Schema test suite ran.
- `Value` lacks floating-point numbers. JSON Schema treats mathematically integral numbers as integers; a future parser must establish the normalization contract before claiming wire-language equivalence over arbitrary JSON.
- Single-field objects demonstrate the boundary. General records, optional versus nullable fields, lists, tagged unions, and fallible refinements remain separate experiments.
- LLM providers can accept a narrower schema vocabulary. An adapter must reject unsupported features explicitly before sending a declaration; the current conversion only produces data.
- The model-turn experiment still accepts explicit declarations for low-level integrations. Application code must use the derived registry path when it wants declaration/dispatch consistency.
- Catalog visibility and authorization remain application policy. Having a declaration does not authorize invocation.
- Empty names and protocol-specific name syntax need admission validation before production. This wave checks identity uniqueness, not every protocol constraint.
