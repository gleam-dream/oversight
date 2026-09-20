# Finite native enums

## Question

- Can one finite table define a native enum's encoding, decoding, schema, and runtime validation without separate inverse callbacks?
- This profile uses JSON strings. It does not preserve the legacy JSON Blueprint `enum` object envelope.

## Native construction

- `string_enum` associates each wire label with one native value and returns the existing `Codec(a)`.
- An empty table is invalid. Duplicate wire labels and duplicate native values are configuration errors.
- Native values are compared with Gleam equality. The intended inputs are stable closed data values; the codec does not infer the constructors of an arbitrary type.
- Empty strings, quotes, and Unicode remain valid wire labels. Label comparison is exact and case-sensitive.
- The finite table drives both encoding and decoding. A native value omitted from the table fails encoding; an unknown wire label or nonstring value fails decoding.
- Aliases are outside this profile. Table order never selects a hidden canonical label for duplicate native values.

## Composition and schema

- Object properties, lists, nullable values, and optional fields reuse the same enum codec. Located errors retain the enclosing field and element index.
- The schema describes exactly the accepted string labels. Runtime admission rejects empty or duplicate label sets and normalizes their order.
- Rendering and loading preserve that finite accepted language. Native enum values remain different from runtime-validated wire strings.
- A tool declaration derives its nested enum schema from the same input codec used by invocation. No separate tool-specific enum registry is introduced.

## Generation boundary

- Source generation returns an explicit unsupported-schema result for enums in this wave. It must not replace the finite native type with an unrestricted `String`.
- Generated constructor names, name collisions, stable naming across schema changes, and native enum field references require a separate generation experiment.

## Evidence boundary

- Native roundtrips, configuration failures, nested error locations, tool composition, and runtime normalization belong to the consumer probe.
- The independent schema corpus compares actual native decoding, runtime validation, loaded documents, and Draft 2020-12 validation on identical wire values.
- Number policy, recursive schemas, aliases, legacy enum envelopes, and generated native enum types remain open families in [API coverage](../../API-COVERAGE.md).
