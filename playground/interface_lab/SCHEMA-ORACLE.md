# Independent schema agreement

## Question

- Does the actual schema emitted by a supported Blueprint codec accept the same representative JSON values as that codec's decoder?

## Method

- `schema_corpus` derives each schema from the actual codec and obtains each acceptance result by invoking its decoder.
- A test-only Erlang adapter exports those values as JSON using OTP's JSON encoder.
- The same codec creates a runtime contract. The corpus invokes its validator and renders its normalized schema.
- `schema_check.py` checks both generated documents with `jsonschema.Draft202012Validator` and compares acceptance with the static decoder and runtime validator results.
- The development shell provides Python and jsonschema from the existing Nix lock. The exercised jsonschema version is 4.26.0.
- The normal interface gate runs this comparison after the pure composition probes.

## Evidence

- Thirty-eight accepted and rejected instances agree across text, integer, boolean, exact tuples, nullable lists, empty objects, optional nullable records, inclusive integer bounds, and tagged decisions.
- The records and decisions come from the same consumer codecs used for Relay integration.
- Each original and normalized schema also passes the validator's schema-document check. Normalization preserves acceptance for these instances.

## Limits

- A finite corpus is differential evidence, not a proof of schema equivalence or full JSON Schema conformance.
- The laboratory Value type has no floating-point case. Integral floating-point JSON numbers and numeric normalization remain outside this comparison.
- Duplicate object keys are excluded from JSON export because native maps cannot retain them. Separate Gleam probes check their rejection before export.
- The test adapter is not the proposed production parser, encoder, or Blueprint FFI.
- This wave does not establish provider-specific schema subsets, performance, recursive schemas, or code generation.
