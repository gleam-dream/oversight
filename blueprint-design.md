# `blueprint` — typed JSON Schema contracts

## Scope and ownership

Blueprint owns JSON Schema descriptions, schema-aware values and bidirectional
codecs, and finite runtime validation. Its contract couples encoding and decoding
with a discoverable schema when a consumer needs JSON Schema. The original
Relay `Schema(a)` and Fabric schema-aware tool boundary move here;
Relay retains protocol declarations and revision-specific generation, while
Saga retains graph publication and workflow compatibility versions.

Blueprint is required only for JSON Schema-aware paths (schema declaration, schema-derived validation, or runtime schema contracts). Ordinary JSON serialization should use standard Gleam JSON encoders and decoders. Any optional reusable codec abstraction must remain independent of Blueprint and schema support; no new codec package or API is prescribed. Schema availability is an explicit capability, not a universal serialization constraint.

Blueprint does not register tools, authorize invocation, execute workflows, or
open provider transports. Sinal's native BEAM fields are a separate contract.
A consumer owns its policy and can reject a Blueprint schema its protocol or
provider cannot accept.

The [initial public API freeze](PUBLIC-API.md) selects values, codecs, schema
derivation, finite runtime contracts, validation, and checked combinators.
Source generation remains a future product capability outside that initial
facade. Open coverage is implementation backlog, not cancelled intent.
Refining the existing JSON Blueprint package remains preferred for evaluation;
the final package name and release/migration strategy are not settled by this
document.

## Values and exact numbers

`Value` is a closed immutable JSON algebra containing null, boolean, string,
number, array, and object values. It is not an arbitrary BEAM term or native
value erasure. Object entries must preserve duplicate keys until the boundary
can reject them; converting directly to a map loses that evidence.

Within Blueprint’s schema/value model, one opaque exact `Number` represents
every JSON numeric value. This is not a representation mandate for ordinary
Gleam JSON serialization outside that model. It retains a
normalized decimal coefficient and exponent; comparison and mathematical
integrality never pass through `Float`. Decimal or exponent spelling can denote
an integer. Canonical zero is positive and canonical rendering uses compact
scientific notation without expanding large exponents.

Parsing requires separate token-byte, significand-digit, and exponent limits.
Integer projection has its own output-digit limit. Invalid syntax, resource
rejection, schema rejection, and unsupported native representation are distinct
outcomes. NaN and infinity are not JSON numbers.

Native `Int` and `Float` remain useful through checked projections. Exact means
mathematical equality: decimal `0.5` can project exactly to binary64, while
exact decimal `0.1` cannot. Constructing a number from a finite binary64 value
preserves that value's exact rational meaning rather than its shortest printed
spelling. Float projection distinguishes overflow, underflow, and inexact
rounding; rounded conversion requires a separately named opt-in contract.

The [exact-number kernel](playground/interface_lab/EXACT-NUMBERS.md) has 62
independently checked cases and Erlang float-bit evidence. The shared laboratory
still uses `Value.Int`; migration into values, codecs, schema bounds, transports,
and generation is deferred. The kernel is not evidence that those boundaries
already preserve numbers. JavaScript acceptance and integers rounded before
native construction require separate tests.

## Native codecs and composition

An opaque `Codec(a)` retains decoding into the existing native type `a`, fallible
encoding from `a`, and a known schema or an explicit unavailable-schema result.
A runtime document cannot supply the missing native type parameter. Custom
encoder/decoder pairs remain usable through explicit construction without
fabricating a schema for their behavior.

Supported constructors compose primitives and products. `pair` preserves exact
tuple positions and length; `list` retains its element codec and located index
errors. `imap` requires both directions of a total mapping and retains the wire
schema. Types do not prove that caller mappings are inverse or deterministic.
A decoder-only mapping cannot become a bidirectional codec automatically.

`Properties(a)` composes typed required and optional properties. Combining
properties rejects duplicate declarations; `object` closes the resulting
record and rejects unknown or duplicate input keys. `empty` supports zero-field
records and zero-argument tools. `field` uses the same object implementation;
its legacy schema description normalizes to a singleton required object.

Missing and null are different values. `Optional` distinguishes `Missing` from
`Present`, while `Nullable` distinguishes `Null` from `NonNull`. A required
nullable property must be present, and an optional nonnullable property rejects
explicit null. `NonNull` encoding must reject an inner value that encodes to
null because decoding would lose the native distinction.

Tagged alternatives retain typed branch payloads in the closed wire envelope
`{tag, value}`. Duplicate tags, unknown tags, missing payloads, unknown fields,
and invalid payloads fail explicitly. Nested binary alternatives have nested
wire envelopes; a flat registry is not implied. This envelope is different
from historical JSON Blueprint `{type, data}` encoding.

A finite string enum uses one nonempty label/native-value table for encoding,
decoding, schema, and runtime validation. Duplicate labels and duplicate native
values fail construction. Unknown labels and native values outside the table
fail their respective directions. Labels are exact case-sensitive data;
empty strings and Unicode are valid. Aliases and numeric enums remain retained
future families with explicit canonical-encoding policy still required.

Schema-expressible refinements check both directions. Inclusive integer ranges
reject reversed bounds at construction and out-of-range values during encoding
and decoding. String lengths, broader numeric bounds, `multipleOf`, additional
collection constraints, and broader unions remain requirements beyond this
subset. Arbitrary business predicates belong after decoding unless an equivalent
schema constraint can be supplied and independently verified.

## Errors and schema laws

Construction errors, encoding errors, decoding errors, schema unavailability,
invalid schema documents, validation failures, and native projection failures
remain separate. Value failures retain typed root-to-leaf locations (property,
index, tagged branch) and structured reasons. Applications must not parse error
prose to locate a failed field.

For accepted native values, successful encoding must decode back to the same
value and satisfy the declared schema. Invalid native values return encoding
errors. Accepted noncanonical wire values must re-encode successfully into a
schema-valid representation. Custom mappings and legacy adapters require their
own law tests; a retained schema does not certify executable callbacks.

Schema acceptance and native representability are separate. JSON Schema may
accept an exact number a requested native projection cannot represent. The
original decoder/schema agreement obligation therefore becomes agreement on
the declared wire language plus an explicit projection outcome, rather than
misclassifying native overflow or inexactness as schema-invalid input. The
current Boolean comparison corpus must change before claiming numeric agreement.

## Runtime contracts and document loading

A `RuntimeContract` contains a validated normalized finite schema. Successful
validation creates an opaque `ValidatedValue` containing the immutable wire
value and normalized schema that accepted it. Editing the value requires
validation again. Neither value substitutes for `Codec(Order)` or `Order`.
A pre-existing codec-owned adapter must perform native decoding.

Construction rejects reversed bounds, duplicate properties, duplicate tags,
and invalid enum tables. Normalization sorts unordered property entries,
tag/payload pairs, and enum labels without changing their associations. Tuple
order, requiredness, bounds, nullable structure, names, and tag/payload
association remain significant. Exact normalized equality is the first matching
rule; it is not general equivalence, subtyping, satisfiability, or migration
compatibility. A reconstructed equal contract can match a witness without a
process-local identity token.

Closed objects, exact pairs, lists, nullable values, bounded integers, tagged
alternatives, and finite string enums have runtime validation evidence.
Duplicate input keys reject before tagged dispatch or property validation.
Missing, unknown, duplicate, wrong-type, wrong-length, out-of-range, and invalid
tag failures retain locations. A witness establishes this validator's acceptance,
not the correctness of a custom codec or another validator.

The finite document loader accepts already parsed `Value` with a Draft 2020-12
root declaration. It accepts the supported renderer forms, preserving every
constraint. Unsupported keywords, references, dialects, and forms fail rather
than disappearing; malformed supported syntax and schema invariants have
separate located failures. Nested dialect declarations are unsupported.
Valid runtime schemas can still be unsupported by source generation.

Whole-document byte parsing remains required work with duplicate-key, UTF-8,
number, size, depth, and source-location policies. Recursive references, broader
JSON Schema syntax, hostile-input limits, performance, and schema evolution
remain future families. Arbitrary unmodelled schema data from Relay's original
escape hatch may be retained as raw metadata, but it must not acquire a validated
contract or claimed codec agreement without an explicit supported interpretation.

## Consumer schema admission

Supported codecs derive structured schemas and Draft 2020-12 documents.
Unknown custom schemas propagate through all enclosing constructors and return
`SchemaUnavailable`; discovery must not guess. Relay, Fabric, and LLM catalogs
derive declarations from their own retained input codecs, so invocation and
discovery can share a source without introducing reverse dependencies.

Admission inspects the full schema AST and retains the exact accepted entries.
Located structural requirements help diagnostics but cannot replace inspection
of combined or positional constraints. Duplicate names and unavailable schemas
fail catalog construction; a typed admitted catalog is distinct from an unchecked
catalog. Blueprint itself neither admits a tool for invocation nor binds a model.

[Scripted admission policies](playground/interface_lab/SCHEMA-ADMISSION.md)
exercise optional-property, tagged-alternative, and object-root restrictions.
They establish no actual provider profile. Provider adapters own configured
schema admission, dialect lowering where explicitly supported, and handling of
remote rejection. Generic local acceptance never guarantees provider acceptance
or transport numeric precision. Structured-output consumers must validate the
wire value against the retained accepted schema before invoking a native mapping
callback, including final output after tool continuation. LLM owns that sequencing
and provider outcome; Blueprint supplies validation and checked native decoding.

## Source generation and migration

Development-time generation consumes a runtime contract and emits reviewable
native source using ordinary Blueprint codecs. Compilation creates the native
type; runtime loading never does. Generated applications must not depend on the
generator. Unsupported shapes return located errors without dropping constraints.
A future command-line workflow, formatting, committed-output policy, and upgrade
fixtures remain required tooling rather than a hidden compile phase.

The experimental generator supports closed root objects with primitive, bounded
integer, nullable, optional, and finite string-enum fields. It uses fixed module
and record names, positional fields, and positional enum constructors. Sixteen
downstream modules and four compiler-negative cases provide compilation and
native-boundary evidence. Equal normalized inputs produce deterministic source;
wire labels are escaped data, including controls, keywords, and Unicode.

Positional names can change when earlier fields or labels are added. Stable
application-selected module/type/field/constructor names remain planned and
paused, not validated. Shared named definitions, nested objects, collections,
numeric enums, aliases, and recursive generation remain future capabilities.
Exclusion from the initial facade does not delete source generation or Relay's
separate official-protocol-schema generation and committed-output drift checks.

The [compatibility playground](playground/blueprint_compatibility/README.md)
runs actual pinned `json_blueprint` 1.7.1 and 1.1.0 projects. The 1.7.1 adapter
requires an explicit encoder, preserves tested legacy envelopes and permissive
record decoding, and deliberately reports unknown schema. Error-path parity,
recursive decoders, numbers, complete call-site migration, and schema conversion
remain unproven.

The exercised 1.1.0 empty constructor rejects nonempty objects, scalar inputs,
and null; 1.7.1 accepts them. The 1.7.1 closed-empty-object schema rejects those
values independently. Its tuple schema declares Draft 7 while using `prefixItems`,
so swapped element types pass that schema but fail its decoder. Updating the
dialect label alone does not prove compatibility. Source compatibility, wire
compatibility, and deliberate acceptance corrections require separate migration
records; legacy decoder accessors and explicit encoders remain migration goals.

## Verification and retained obligations

The [independent schema corpus](playground/interface_lab/SCHEMA-ORACLE.md) uses
`jsonschema` 4.26.0 from the locked development environment. It compares 61
instances across actual static decoding, runtime validation, emitted and
normalized schemas, and document loading. This is finite Draft 2020-12 evidence,
not general conformance. Duplicate-key tests run before export because native
maps would erase duplicates. Exact-number kernel cases are a separate oracle,
using Python Decimal/Fraction and independent float-bit inspection.

Retain generated valid/invalid cases per supported keyword, constructor
roundtrip properties, compiler negatives for native/runtime separation, and
schema-validation tests for optional/null, enums, ranges, collections, overlapping
unions, and future recursive values. Numeric expansion must compare exact
schema acceptance separately from native projection. Whole-document fuzzing,
resource limits, cross-target behavior, and upgrade fixtures remain necessary.
An unexplained disagreement in a claimed supported contract blocks acceptance.

Legacy releases are pinned behavioral comparators, not proof of complete
migration. Their archives omit upstream tests; test reuse needs a pinned source
checkout. Source-only references such as glon and castor do not establish an
adopted backend or executed oracle. Relay retains protocol revision snapshots,
official-schema checks, and protocol codec roundtrips; Blueprint supplies the
schema-aware codec-law tests without claiming MCP conformance. Ordinary protocol
codecs retain their own roundtrip tests without requiring Blueprint.

## Capability disposition

The baseline is Relay's schema/codec contract and Fabric's typed wire boundary
in commit `9194f02`, expanded by the shared-foundation and Blueprint research.
Deferred capabilities remain requirements; the initial facade is delivery scope.

| Original or agreed capability                                      | Disposition and owner                                                             | Evidence and remaining obligation                                                                              |
| ------------------------------------------------------------------ | --------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| One definition yields encoder, decoder, and schema                 | Reassigned from Relay to Blueprint; retained as `Codec(a)`                        | Typed combinator probes; constructor and mapping laws remain required                                          |
| Fabric native/wire agreement and schema identity                   | Schema-aware contract belongs to Blueprint; ordinary serialization is independent | Codec-edge consumers; version labels do not prove wire compatibility                                           |
| JSON null/bool/string/number/array/object without public `Dynamic` | Retained; number design expanded to exact `Number`                                | Kernel oracle only; `Value.Int`, parser, transport and schema migration pending                                |
| Primitive/product codecs, fields, optionality, null, collections   | Retained and expanded in Blueprint                                                | Constructive native/runtime/schema corpus; parser and resource tests pending                                   |
| Constraints, enums, `oneOf`, broader schema AST                    | Retained; finite subset demonstrated, broader families deferred                   | Bounds, tagged and string-enum cases; string lengths, numeric enums, general unions and constraints pending    |
| Unmodelled schema escape hatch                                     | Retained as unverified raw data boundary; validation unresolved beyond subset     | Must not silently discard keywords or certify unavailable schema                                               |
| Runtime-created schema values                                      | Expanded into finite contracts and opaque witnesses                               | Normalization, loader and native-boundary negatives; forms/Saga graph consumers and hostile-input work pending |
| Native type/codec generation                                       | Retained future tooling; excluded initial facade                                  | Positional records/enums compiled; named generation paused, broader and recursive profiles pending             |
| JSON Blueprint 1.1.0 and 1.7.1 migration                           | Retained, partial compatibility                                                   | Actual release probes; full source, wire, error, recursive and numeric migration unresolved                    |
| Provider/protocol schema restrictions                              | Consumer-owned admission using Blueprint AST                                      | Scripted policy evidence only; real profiles and dialect lowering pending                                      |
| Recursive schemas and references                                   | Retained deferred family                                                          | Needs finite/resource policy, recursive codec laws, independent validator and generation fixtures              |
| Protocol generation, snapshots and conformance                     | Relay retains protocol tooling; Blueprint supplies schema-aware codec support     | Original Relay test obligations remain outside generic Blueprint conformance claims                            |

## Sources and unresolved friction

The controlling evidence is [PUBLIC-API](PUBLIC-API.md),
[Blueprint coverage](API-COVERAGE.md#json-blueprint),
[refinement status](playground/interface_lab/REFINEMENT-STATUS.md),
[shared foundations](research/shared-foundations.md),
[runtime contracts](research/runtime-schema-contract.md),
[number policy](research/blueprint-number-policy.md),
[generation contract](research/blueprint-generation-contract.md), and
[compatibility investigation](research/blueprint-compatibility-contract.md).
Their linked experiment notes distinguish current evidence from earlier proposals.

Potential capability loss remains visible at three boundaries: the finite
schema profile cannot yet cover the original broader schema AST; positional
generation does not supply stable application names; exact wire validity cannot
be collapsed into native decoder success. Retain each requirement while its
implementation or migration contract is unfinished. No production parser,
full JSON Schema conformance, complete legacy compatibility, or promoted
generation API is claimed.
