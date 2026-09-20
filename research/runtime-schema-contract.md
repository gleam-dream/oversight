# Runtime schema contract

## Question and status

- The experiment asks whether Blueprint can validate JSON-shaped values against a finite schema selected at runtime without claiming that the schema creates a native Gleam type.
- The current [`Codec(a)`](../playground/interface_lab/src/lab/blueprint.gleam) couples wire encoding and decoding to a type known at compilation. Its supported constructors also retain a public `Schema` description.
- The current laboratory has no value that records successful validation against a runtime-selected schema. The [API coverage](../API-COVERAGE.md) therefore keeps runtime schemas and opaque validated values open.
- This note proposes type and consumer work only. It does not claim a JSON Schema parser, generator, runtime graph, or production validator.

## Boundary

- `Codec(a)` remains the only Blueprint value that can decode wire data into a native `a`.
- A runtime contract contains one validated and normalized `Schema`. A runtime contract cannot be converted into `Codec(a)` because no runtime document can create a type that was absent during compilation.
- A validated value contains one immutable `Value` and the normalized `Schema` that accepted it. It is not Gleam `Dynamic`, an arbitrary BEAM term, or an erased native value.
- Runtime-contract construction enforces the explicit invariants of the finite validation language. It does not decide general schema satisfiability or detect every logical contradiction.
- Validation checks wire acceptance only.

## First type experiment

- Put the runtime boundary in a separate module so its `schema` function does not conflict with the existing `blueprint.schema(codec)` function.
- Keep the exact names provisional. The constructors and opacity are the experiment.

```gleam
pub opaque type RuntimeContract
pub opaque type ValidatedValue

pub fn from_schema(
  schema: blueprint.Schema,
) -> Result(RuntimeContract, ContractError)

pub fn from_codec(
  codec: blueprint.Codec(a),
) -> Result(RuntimeContract, ContractError)

pub fn schema(contract: RuntimeContract) -> blueprint.Schema

pub fn validate(
  contract: RuntimeContract,
  value: value.Value,
) -> Result(ValidatedValue, ValidationError)

pub fn encoded(value: ValidatedValue) -> value.Value

pub fn matches(
  contract: RuntimeContract,
  value: ValidatedValue,
) -> Bool

pub fn same_schema(
  left: RuntimeContract,
  right: RuntimeContract,
) -> Bool
```

- `from_schema` validates the declared subset invariants before it returns an opaque contract. It recursively normalizes unordered structures while preserving tuple positions and every other order that changes the wire language.
- `FieldSchema(name, schema)` normalizes to `ObjectSchema([PropertySchema(name, True, schema)])`. The legacy field description and the equivalent singleton required object therefore have one runtime identity.
- Object properties sort by the complete normalized property entry. Tagged alternatives sort as complete `(tag, normalized payload)` pairs, so a tag never moves without its payload.
- Tagged normalization retains only the wire alternatives. It does not preserve or promise a codec's native `Left` and `Right` ordering.
- `from_schema` rejects an integer range whose minimum exceeds its maximum, duplicate object property names, and duplicate tags in one tagged alternative. These checks enforce the listed subset invariants without claiming general contradiction detection.
- Empty property names and empty tag strings remain accepted because the static Blueprint constructors currently accept them. A later naming policy belongs at a protocol or application admission boundary.
- Objects remain closed because the current `ObjectSchema` renders `additionalProperties: false`. Validation rejects unknown properties; a future open-object policy requires an explicit schema variant rather than a permissive default.
- `from_codec` obtains the codec's retained schema and delegates to `from_schema`. It returns `UnknownSchema` for a codec built through `blueprint.new`, including when such a codec is nested inside a supported constructor.
- `schema` returns the normalized structure rather than the caller's original ordering. A consumer may therefore persist or compare the canonical finite description.

## Witness identity and matching

- A validated value records its normalized structural `Schema` rather than a fresh process-local token. A contract reconstructed after restart therefore matches an earlier value when both normalize to the same structure.
- `matches` compares the contract's normalized schema with the witness schema. `same_schema` applies the same comparison to two contracts.
- Exact normalized equality is the first compatibility rule. It does not prove semantic equivalence, backward compatibility, or subtype compatibility between different schemas.
- Object property order and tagged-alternative order do not affect exact equality after normalization. Tuple order, property requiredness, nullable structure, bounds, field names, and tag/payload associations remain significant.
- Normalization preserves nested nullable structure even though two nullable layers accept the same wire values as one layer. The first experiment performs no semantic collapses beyond the explicit `FieldSchema` conversion and unordered-entry sorting.
- A matching witness proves that the enclosed `Value` passed this validator for the same normalized structure. It does not prove that a separately implemented validator agrees or that a later implementation preserves the same normalization rules.

## Validation failures

- A validation failure carries a root-to-leaf path so forms, tools, and graph diagnostics can locate the rejected value without parsing prose.

```gleam
pub type PathSegment {
  Property(String)
  Index(Int)
  TaggedBranch(String)
}

pub type ValidationReason {
  ExpectedText
  ExpectedInteger
  ExpectedBoolean
  ExpectedArray
  ExpectedObject
  MissingProperty(String)
  UnknownProperty(String)
  DuplicateProperty(String)
  WrongTupleLength(expected: Int, actual: Int)
  IntegerOutsideRange(minimum: Int, maximum: Int, actual: Int)
  MissingTag
  NonTextTag
  UnknownTag(String)
}

pub type ValidationError {
  ValidationError(path: List(PathSegment), reason: ValidationReason)
}
```

- The reason vocabulary must cover every current `Schema` constructor. A tagged value has the fixed closed shape `{tag: Text, value: payload}` and distinguishes a missing tag, a non-text tag, and an unknown tag.
- Duplicate input object keys remain observable because the laboratory `Value.Object` retains a list of pairs. Validation rejects duplicates before tag dispatch and before unknown-property, missing-property, or payload validation.
- An optional property accepts absence and validates its inner schema when present. `null` is accepted only when the inner schema is `NullableSchema`; a required nullable property must still be present.
- `encoded` returns the accepted immutable wire value. Editing or reconstructing that value loses the witness and requires validation again.

## Codec-law limit

- `from_codec` reuses a codec's declared wire schema. It does not certify the codec's encoder, decoder, or caller-supplied `imap` functions.
- A validated value proves acceptance by the runtime schema validator. It does not prove that `blueprint.decode(codec, encoded(value))` succeeds or that decoding and encoding round-trip.
- The existing independent schema corpus remains the appropriate behavioral check for agreement between supported codecs and schema validation. Custom codec laws require separate property and differential tests.

## Decisive consumer

- Construct one runtime contract from a closed object containing a required text property, a bounded integer, an optional boolean, and a tagged alternative.
- Validate one accepted value and retain its witness. Reconstruct the same contract with object properties and tagged alternatives in a different order; require `matches` and `same_schema` to succeed.
- Construct one `FieldSchema` contract and one equivalent singleton required-object contract; require exact matching after normalization.
- Construct contracts that change requiredness, one bound, one tag, and one tuple position; require each comparison to fail.
- Reject schemas with duplicate properties, duplicate tags, and reversed integer bounds before any value validation occurs.
- Check an optional nullable integer with absent, `null`, and integer values; require all three to succeed. Check a required nullable integer with absence; require a missing-property failure.
- Reject values with a nested wrong type, a missing property, an unknown property, a duplicate property, a wrong tuple length, an out-of-range integer, a missing tag, a non-text tag, and an unknown tag. Require each failure to retain its exact path and closed reason.
- Derive the same contract through one supported static codec. Require a custom `blueprint.new` codec to fail with `UnknownSchema` and add a compiler-negative fixture showing that `RuntimeContract` and `ValidatedValue` cannot substitute for `Codec(Order)` and `Order`.

## Subsequent experiments

- **Runtime document loading:** parse an untrusted Draft 2020-12-shaped `Value` into the finite `Schema` subset, reject unsupported keywords and references explicitly, then call `from_schema`. Parsing limits, numeric normalization, duplicate document keys, source locations, and hostile input remain obligations of this boundary.
- **External declarations:** render a runtime contract for a form or tool, validate submitted `Value`, and pass only `ValidatedValue` to a generic runtime handler. Rendering a schema does not register a handler or grant invocation authority.
- **Runtime Saga graph:** register compiled operations behind opaque adapters that retain their real input and output `Codec` values. A published graph stores named and versioned operation identifiers, normalized port schemas, and `Value` edges; exact schema equality admits the first connections, while private adapters recover native types only through their retained codecs.
- **Generation:** consume a schema document during development, emit a native type plus an ordinary `Codec(a)`, and compile the generated module with the application. The generated codec must normalize to the same schema as the runtime loader, while loading a later document still yields only `RuntimeContract` and `ValidatedValue`.
- Each subsequent experiment has a separate acceptance result. Success in the first type experiment does not establish document parsing, graph publication, code generation, schema evolution, or operational safety.

## Acceptance boundary

- The first experiment succeeds when only validated schemas construct runtime contracts, only successful validation constructs witnesses, reloaded normalized structures match, and runtime values cannot enter native typed functions without an existing codec-owned adapter.
- The experiment establishes exact structural identity for the supported finite schema language. It does not establish general JSON Schema equivalence, subsumption, migration safety, recursive references, provider-specific admission, validator performance, or resource bounds.
- No permanent package boundary follows from this experiment. The result decides whether the runtime contract belongs beside Blueprint's static codec without weakening `Codec(a)` or creating a universal dynamic-value abstraction.
