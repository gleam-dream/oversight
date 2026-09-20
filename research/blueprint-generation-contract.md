# Blueprint document loading and source generation

## Question and status

- The experiment asks whether one finite schema document can support runtime validation and development-time generation of a native Gleam type with its codec.
- Blueprint's existing `schema_value` and `schema_document` functions render schema descriptions as `Value`. They do not generate Gleam source.
- The [runtime schema contract](runtime-schema-contract.md) defines normalized schema identity and opaque validated values. This note proposes two subsequent experiments without claiming that runtime schemas manufacture native types.

## Document-loading boundary

- Add `blueprint_document.load(Value) -> Result(RuntimeContract, DocumentError)`. The loader accepts an already parsed document and delegates schema invariant checking and normalization to `from_schema`.
- The root document requires `$schema` equal to `https://json-schema.org/draft/2020-12/schema`. Nested schemas do not accept `$schema` in this first profile.
- The accepted syntax is the finite set of forms emitted by Blueprint's schema renderer. Semantically equivalent JSON Schema syntax outside those forms returns an unsupported-form error.
- Primitive forms contain exactly `type: "string"`, `type: "integer"`, or `type: "boolean"`. The bounded integer form additionally requires both integer-valued `minimum` and `maximum`.
- A closed object contains `type: "object"`, an object-valued `properties`, an array-valued `required`, and `additionalProperties: false`. Required names must be unique strings naming declared properties; property schemas are loaded recursively.
- A list contains `type: "array"` and one schema-valued `items`. A pair contains `type: "array"`, exactly two `prefixItems`, and `minItems` and `maxItems` both equal to two.
- A nullable form contains only `anyOf` with exactly one `{ "type": "null" }` alternative and one supported inner schema. Either alternative order is accepted; null alone is not a standalone form in this profile.
- A tagged form contains `type: "object"` and exactly two `oneOf` alternatives. Each alternative is a closed object with required `tag` and `value` properties; `tag` contains only one string-valued `const`, while `value` contains a supported payload schema.
- Tagged alternatives must have distinct tags. The loader preserves each tag's association with its payload schema when normalization changes alternative order.
- Optionality is determined by membership in `required`. A present optional value must satisfy its property schema; nullable properties accept null independently of requiredness.
- The loader rejects duplicate keys before interpreting each schema object's fields. The property-name map also rejects duplicate names, while treating names as data rather than schema keywords.
- Unsupported keywords and forms return located errors rather than being ignored. Examples include references, defaults, descriptions, open objects, arbitrary unions, and unbounded tuple forms.
- Malformed supported syntax, unsupported syntax, unsupported dialects, and schema invariant failures remain distinct error reasons. Paths use typed property and array-index segments into the input document.
- This boundary does not parse JSON bytes. Preservation of duplicate keys, numeric normalization, parsing limits, and byte-source locations remain responsibilities of a later parser experiment.

## Source-generation boundary

- Add `generate(RuntimeContract) -> Result(GeneratedSource, GenerationError)` as a development-time operation. `GeneratedSource` exposes source text without claiming that the text compiles.
- The first generation profile requires a root closed object. Its property schemas may be text, integer, boolean, bounded integer, or recursive nullable combinations of those forms; object requiredness determines native optionality.
- Other valid runtime schemas return a located unsupported-generation error. Lists, pairs, tagged alternatives, and nested objects remain outside this first generation profile.
- Generate one fixed module, `generated/document`, containing a native `Document` record and `codec() -> Codec(Document)`. An empty root object generates a zero-field record backed by Blueprint's empty-object properties.
- Assign labels `field_0`, `field_1`, and subsequent indices using normalized property order. Fixed module, record, and field naming are experimental choices pending a separate public API ergonomics decision.
- Preserve original JSON property names inside codec string literals. Property names never become unvalidated Gleam identifiers or source fragments.
- Generate the codec from existing Blueprint constructors and a total `imap` between the property representation and the record. Requiredness, integer bounds, and nullable structure must remain in the codec's retained schema.
- A required property maps to its generated native field type. An optional property maps to `Optional` of that field type; a nullable property maps to `Nullable` of its inner type.
- Source generation must use a total Gleam string-literal encoder. Compiler fixtures must cover property names containing quotes, backslashes, newlines, Unicode, and Gleam keywords.
- Generation must be deterministic for equal normalized contracts. Environment paths, timestamps, process identifiers, and caller object-property order must not alter the source.
- The harness writes generated source into an isolated temporary project and compiles it before running its native consumer. Loading a document in the running application still produces only `RuntimeContract` and `ValidatedValue`.

## Shared fixture and acceptance

- Use one closed object with required text `name`, required integer `quantity` bounded from one through ten, and optional nullable text `note`.
- Render the fixture's supported static codec with `schema_document`, load that document, and require normalized equality with the codec-derived runtime contract.
- Reorder document object properties and `required` names without changing their associations. Require the loaded contracts and generated source to remain equal.
- Reject duplicate document keys, undeclared required names, unsupported keywords, unsupported dialects, malformed supported forms, and reversed integer bounds with exact located reasons.
- Pass a valid runtime list schema to generation and require a located unsupported-generation result. Loading support and generation support must remain independently observable.
- Compile the generated module with a separately authored consumer that constructs its native record and calls its codec. Require the generated codec's normalized schema to equal the loaded runtime contract.
- Decode absent, null, and string-valued `note` inputs into distinct native values. Reject a missing required property, an out-of-range quantity, an unknown property, and a wrong property type.
- Compile escaping fixtures and verify that their codecs preserve the original property names. Source compilation alone does not establish that an escape preserved the intended wire name.
- Add a compiler-negative fixture passing `ValidatedValue` to a function requiring the generated `Document`. Add a separate fixture passing `RuntimeContract` where `Codec(Document)` is required.

## Work order and evidence limits

- Complete document loading and its pure parsed-value consumers first. Keep source generation absent until that acceptance result is recorded.
- Complete source generation, isolated compilation, native consumers, and negative fixtures as a separate change. The runtime loader remains usable without invoking the compiler.
- Reuse the independent schema oracle to compare representative accepted and rejected values with the rendered document. Finite agreement does not establish general JSON Schema conformance or codec laws.
- The experiments establish one path from a finite document to runtime validation and compiled native code. They do not establish arbitrary type naming, general schema equivalence, recursive references, runtime graph publication, schema migrations, hostile-input resource bounds, or production generation tooling.
