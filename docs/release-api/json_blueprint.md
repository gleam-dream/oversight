# Release API review: `json_blueprint` 2.0

Repo `/code/gleam-dream/json_blueprint`, branch `main` at `129c963`. Hex has
1.7.1; 2.0 is unreleased, and `gleam.toml:2` still says 1.7.1. Design:
[blueprint-design.md](../../blueprint-design.md). API card:
[scan/json_blueprint.md](../composition/scan/json_blueprint.md). Reviewed on
2 October 2026 against the release rubric and the
[public API guidelines](../../PUBLIC-API-GUIDELINES.md).

Claims marked "measured" or "compiled" were run in a scratch consumer package
with a path dependency on the repo, on OTP 28 and Node 24.

## 1. Verdict

- The 2.0 API is not release-ready. Its capabilities are sound: one `Codec(a)`
  gives an encoder, a strict decoder and a Draft 2020-12 schema, and five apps
  shared one codec across Relay, fabric and llm_wire without drift.
- The surface is the first problem. 226 public functions in 12 modules serve
  three audiences (application authors, generated code, 1.x users), and a
  record above three fields needs `combine` chains with nested tuples written
  in both directions (EXT-6, SD-6, SMCP-8).
- Codecs have no bridge to `gleam/json` or `decode`, so every app that also
  used Grind or Saga kept a second codec by hand (theme 6), and the default
  10 MiB byte limit admits about 900 MB of heap per request (measured, R7).

## 2. First ten minutes

The main job: describe a record once, then encode it, decode JSON text
strictly, and publish its schema. The record has four fields (a bounded
integer, an optional string and a string enum).

**Today** (compiled):

```gleam
import gleam/option.{type Option}
import json/blueprint/codec

pub fn user_codec() -> codec.Codec(User) {
  let assert Ok(role) = codec.string_enum([#("admin", Admin), #("member", Member)])
  let assert Ok(age) = codec.integer_between(0, 150)
  let assert Ok(props) =
    codec.combine(codec.required("name", codec.string()), codec.required("age", age))
  let assert Ok(props) = codec.combine(props, codec.optional_option("email", codec.string()))
  let assert Ok(props) = codec.combine(props, codec.required("role", role))
  codec.object(props)
  |> codec.imap(
    fn(t) {
      let #(#(#(name, age), email), role) = t
      User(name:, age:, email:, role:)
    },
    fn(u) { #(#(#(u.name, u.age), u.email), u.role) },
  )
}
```

**Proposed** (the builder compiled and round-tripped on both targets as a
prototype over today's API):

```gleam
import gleam/option.{type Option}
import json/blueprint/codec.{type Codec}

pub fn user_codec() -> Codec(User) {
  let role = codec.string_enum([#("admin", Admin), #("member", Member)])
  use name <- codec.field("name", codec.string(), fn(u: User) { u.name })
  use age <- codec.field("age", codec.integer_between(0, 150), fn(u: User) { u.age })
  use email <- codec.optional_field("email", codec.string(), fn(u: User) { u.email })
  use role <- codec.field("role", role, fn(u: User) { u.role })
  codec.success(User(name:, age:, email:, role:))
}
```

Both are used the same way: `codec.encode_json(c, user)`,
`codec.decode_json(c, text)` and `codec.schema_json(c)`.

| Count                              | Today                     | Proposed  |
| ---------------------------------- | ------------------------- | --------- |
| Imports / package modules / types  | 2 / 1 / 1                 | 2 / 1 / 1 |
| Definition calls                   | 13                        | 9         |
| `let assert` on static definitions | 5                         | 0         |
| Tuple shapes written by hand       | 2                         | 0         |
| Lines for 6 fields (extractor)     | 57 (invoice.gleam:45-101) | about 12  |

- Each getter needs a type annotation (`fn(u: User)`). Without it the compiler
  reports "Unknown type for record access", because the record type is fixed
  only by `success`. A curried-pipeline builder has the same limit.

## 3. Target surface

### Modules

| Module                                          | Today                                | Fate                                                                      |
| ----------------------------------------------- | ------------------------------------ | ------------------------------------------------------------------------- |
| `codec`                                         | 82 fns, 45 of them generator helpers | **Keep** as the only module of the common path                            |
| `runtime`, `document`                           | 8 + 1 fns                            | **Merge** into a renamed `contract` module, with schema-document parsing  |
| `value`, `json_text`, `parser`, `parser_limits` | 6 + 1 + 6 + 8 fns                    | **Merge** into `value` (Value, parse, render, limits, bridges)            |
| `number`                                        | 13 fns                               | **Keep**, trimmed                                                         |
| `codegen`                                       | 20 fns, a second combinator set      | **Move** to a dev-only package `json_blueprint_codegen` (open question 3) |
| `json/blueprint` (root), `schema`               | 42 + 8 fns, the 1.x API              | **Keep frozen** for 1.x and recursive types; `Decoder` becomes opaque     |
| `dynamic`                                       | 31 fns, copy of the old stdlib API   | **Move** to `internal/`                                                   |
| new `internal/generated`                        | —                                    | Generator helpers, `from_json_parts`, native decoding                     |

All paths are under `json/blueprint/`.

### Key types and functions

- **`codec`**: `Codec(a)` (opaque).
  - Primitives and collections: `string`, `int`, `float` (new), `number`, `bool`, `list`, `pair`, `nullable -> Codec(Option(a))`.
  - Records: `field`, `optional_field`, `success`. Unions: `union`, `variant`, `unit_variant`, `match`.
  - Refinements and mapping: `string_enum`, `integer_between`, `number_between`, `describe`, `map`, `try_map`, `custom`.
  - Use: `encode`, `decode`, `encode_json`, `decode_json`, `decode_json_with_limits`, `to_json`, `decoder`, `schema`, `schema_json`, `schema_value`, `schema_document`, `check`.
  - Errors: `EncodeError(path, reason)`, `DecodeError(path, reason)`, `DefinitionError`, `SchemaError`, `PathSegment`; `describe_encode_error`, `describe_decode_error`, `describe_definition_error`, `is_limit_exceeded`, `decode_failure`, `encode_failure`.
  - Schema AST: `Schema`, `PropertySchema`.
- **`contract`**: `Contract`, `ValidatedValue` (opaque); `from_codec`, `from_schema`, `load`, `parse`, `schema`, `validate`, `value`, `same_schema`, `decode`, `value_codec`, `describe_validation_error`, `describe_load_error`.
- **`value`**: `Value`, `Limits` (opaque), `ParseError(location, kind)`; `object`, `parse`, `parse_bits`, `to_string`, `to_json`, `decoder`, `default_limits`, `with_max_bytes`, `with_max_depth`, `with_number_limits`, `describe_parse_error`.
- **`number`**: `Number`, `Limits` (opaque); `parse`, `to_string`, `compare -> order.Order`, `is_integer`, `from_int`, `to_int`, `from_float_exact`, `to_float_exact`, `limits`, `default_limits`.

### Counts

| Measure                                  | Before | After |
| ---------------------------------------- | ------ | ----- |
| Public modules                           | 12     | 6     |
| Public functions                         | 226    | 123   |
| … in the 2.0 modules                     | 145    | 73    |
| … in the 1.x modules                     | 81     | 50    |
| Public records (non-opaque, one variant) | 11     | 7     |
| Public unions                            | 42     | 22    |
| Opaque types                             | 12     | 10    |
| Type aliases                             | 4      | 1     |

Codegen keeps its 20 functions and 4 opaque types in its own package. If it
stays here, add 1 module and 20 functions to "After".

## 4. Proposals

Ranked by user impact. "Unreleased callers" means the gleam-dream siblings and
apps that use the 2.0 branch; "1.x callers" means users of the Hex release.

### JSONB-R1 Replace the arity family with a `use`-based record builder

- **Problem.** `record2`/`record3` stop at three fields (codec.gleam:1271,
  :1298); larger records use `combine` (:1230), `object` (:1256) and `imap`
  over nested tuples. Extractor paid 57 lines and nine `let assert`s (EXT-6),
  support_desk wrote a `record4` (SD-6, domain.gleam:186-208), secure_mcp
  nested `combine` pairs (SMCP-8), and fabric nested `pair`s
  (graph/llm.gleam:128-136). `required`, `optional` and `optional_option` are
  three ways to declare one property, and `Optional(a)` duplicates `Option(a)`.
- **After.** A field is an object codec with one more property; `success` is
  the closed object with no further properties.

  ```gleam
  pub fn field(name: String, of: Codec(a), get: fn(r) -> a,
    next: fn(a) -> Codec(r)) -> Codec(r)
  pub fn optional_field(name: String, of: Codec(a), get: fn(r) -> Option(a),
    next: fn(Option(a)) -> Codec(r)) -> Codec(r)
  pub fn success(value: r) -> Codec(r)   // codec.success(Nil) replaces empty()
  ```

  - `optional_field(name, nullable(c), ..)` keeps absent and present `null`
    apart (`None`, `Some(None)`, `Some(Some(a))`).
  - The builder needs a placeholder value per field to discover later fields,
    and R2's `decoder` needs one for failures. Built-in codecs derive it (`""`,
    `0`, range minimum, first enum value, `[]`, `None`); `map` maps it;
    `try_map` and `custom` take it as an argument, as `decode.failure` does.
  - Property discovery and the rest-of-record encoder are computed lazily once,
    so decoding stays linear in the field count. The prototype used a
    `codec.object({ .. })` wrapper over a `Fields(r)` type; without the wrapper
    the call site is one line shorter, and a continuation that ends in a
    non-object codec is a `DefinitionError` (R3).

- **Delete.** `record2`, `record3`, `combine`, `object`, `Properties`,
  `required`, `optional`, `optional_option`, `empty`, single-property `field`
  (:1329) with `FieldSchema`, `Optional`, `Nullable`, `PropertyError`.
- **Breaks:** unreleased callers. **Effort:** M.

### JSONB-R2 Bridge to `gleam/json` and `gleam/dynamic/decode` (theme 6)

- **Problem.** `encode_json` returns `String` and `decode_json` takes `String`
  (codec.gleam:174, :182), while Grind takes `fn(v) -> json.Json` and
  `decode.Decoder(v)`. Extractor stored Blueprint text inside a JSON string and
  needed a placeholder `Invoice` (EXT-5); secure_mcp kept a 38-line gleam_json
  twin (SMCP-8); research_agent has 96 lines of bridges (RA-8). llm_wire
  converts `Value -> json.Json` through `Float` and loses precision silently
  (llm_wire/internal/schema.gleam:17-60).
- **After.**

  ```gleam
  pub fn to_json(codec: Codec(a), value: a) -> Result(json.Json, EncodeError)
  pub fn decoder(codec: Codec(a)) -> decode.Decoder(a)
  // in value:
  pub fn to_json(value: Value) -> Result(json.Json, Number)  // Error: no exact gleam_json form
  pub fn decoder() -> decode.Decoder(Value)
  ```

  - `to_json` is exact. An integer becomes `json.int`; a decimal becomes
    `json.float` only when the printed float reads back as the same `Number`.
    The prototype emitted `[0.1,2.5,1.0e20]` on Erlang and
    `[0.1,2.5,100000000000000000000]` on Node, and refused `1e400`.
  - `decoder` accepts what the caller's parser produced; duplicate keys, exact
    numbers and size limits belong to that parser, and the doc must say so.
    The prototype round-tripped a record through `json.parse(text, decoder)`
    on both targets.
  - Grind then needs `worker.codec(version, fn(v) { codec.to_json(c, v) |> result.unwrap(json.null()) }, codec.decoder(c))`.

- **Breaks:** nothing. **Effort:** M (placeholder plumbing from R1).

### JSONB-R3 Infallible definitions with one typed definition error

- **Problem.** Static definitions return `Result` with five error types:
  `PropertyError` (:1172), `EnumError` (:1397), `UnionError` (:1510),
  `ConstraintError` (:1598) and `codegen.CompileError`.
  `runtime.ContractError` (runtime.gleam:18) repeats the same invariants.
  Callers write `let assert` on constants (EXT-6), which crashes at the moment
  a typed error would appear.
- **After.** Constructors return `Codec(a)`. An invalid definition yields a
  codec whose `schema`, `encode` and `decode` return
  `InvalidDefinition(DefinitionError)`. Relay, fabric and llm_wire call
  `schema` when a tool is registered at startup, so the error appears there.

  ```gleam
  pub type DefinitionError {   // replaces PropertyError, EnumError, UnionError,
    DuplicateProperty(name: String)    // ConstraintError and ContractError
    DuplicateTag(tag: String)  EmptyEnum  DuplicateEnumLabel(label: String)
    DuplicateEnumValue(first_index: Int, repeated_index: Int)
    ReversedIntegerBounds(min: Int, max: Int)  ReversedNumberBounds(min: Number, max: Number)
  }
  pub type SchemaError { UnknownSchema  InvalidDefinition(DefinitionError) }
  pub fn check(codec: Codec(a)) -> Result(Codec(a), DefinitionError)
  ```

  `check` serves tests and enums built from runtime data;
  `contract.from_schema` returns the same `DefinitionError`.

- **Breaks:** unreleased callers. **Effort:** M. Alternative: panic (open question 2).

### JSONB-R4 An N-ary variant builder instead of binary `tagged`

- **Problem.** `tagged` takes two branches over `Either` (:1505-1518) with
  `TaggedSchema(String, Schema, String, Schema)` (:107); a third case nests
  the envelope on the wire. Fabric dispatches on `pair(string, string)`
  instead (graph/llm.gleam:169-175). The design retains general unions.
- **After** (prototype compiled and round-tripped three variants on both
  targets). Each continuation receives the typed encoder of its variant, so no
  placeholder is needed, and Gleam checks the final `case` for exhaustiveness.

  ```gleam
  pub fn variant(tag: String, payload: Codec(p), construct: fn(p) -> t,
    next: fn(fn(p) -> Tagged(t)) -> Union(t)) -> Union(t)
  pub fn unit_variant(tag: String, value: t, next: fn(Tagged(t)) -> Union(t)) -> Union(t)
  pub fn match(encode: fn(t) -> Tagged(t)) -> Union(t)
  pub fn union(variants: Union(t)) -> Codec(t)

  let shape = codec.union({
    use circle <- codec.variant("circle", codec.int(), Circle)
    use square <- codec.variant("square", codec.int(), Square)
    use label <- codec.variant("label", codec.string(), Label)
    codec.match(fn(s) {
      case s { Circle(r) -> circle(r)  Square(x) -> square(x)  Label(t) -> label(t) }
    })
  })
  ```

  - The wire keeps one `{"tag", "value"}` envelope; a unit variant omits `value`.
  - `UnionSchema(List(#(String, Schema)))` replaces `TaggedSchema`. Contract
    normalization, validation, `document.load` (a two-branch `oneOf` today,
    document.gleam:336-339) and codegen need the N-ary form.

- **Delete.** `tagged`, `Either`, `UnionError`, `TaggedSchema`.
- **Breaks:** unreleased callers; Relay and llm_wire match `TaggedSchema`
  (relay/internal/schema.gleam:43, :61). **Effort:** L.

### JSONB-R5 Hide generator machinery

- **Problem.** 45 of 82 `codec` functions exist for generated modules
  (codec.gleam:384-1068); three take raw `Dynamic` (:861, :873, :903).
  `from_json_parts` (:144) and `decode_json_native` (:201) serve only
  generated codecs. They freeze generator internals as semver API and bury
  the 37 application functions. `codegen` mirrors the combinators a second
  time (`Definition(a)`, 20 functions), although the design calls generation
  future tooling outside the initial facade.
- **After.** Move the helpers, `from_json_parts` and native decoding to
  `internal/generated`. A scratch test confirmed that another package compiles
  against an internal module and an `@internal` function without an error, so
  checked-in generated code keeps compiling. Generated code lives in
  application repos, so that module doc must promise stable names and
  signatures within a major version. Move `codegen` to a dev-only package.
  Generated `decode_<name>_json_native` returns `json.DecodeError`, so
  `NativeJsonFailure` goes.
- **Breaks:** regenerate checked-in modules once. **Effort:** S (internal), M (package split).

### JSONB-R6 One `contract` module with `value_codec` and a typed mismatch

- **Problem.** Schema admission spans `runtime`, `document`,
  `parser.parse_schema_document[_from_string]` and `parser_limits`.
  `runtime` collides with `relay/runtime`. `runtime.decode` reports a
  codec/contract mismatch as `CustomDecodeReason("Schema mismatch")`
  (runtime.gleam:140, :144), which a caller's own custom reason can imitate.
  tool_hub built `Codec(Value)` over a contract by hand plus a 37-line error
  map (TH-6, remote_tools.gleam:135-184). Two `PathSegment` types exist
  (runtime.gleam:46, document.gleam:9) beside codec's nested `DecodeAtField`.
  Validation and document errors have no renderer, so llm_wire uses
  `string.inspect` (EXT-3).
- **After.**

  ```gleam
  pub fn load(document: Value) -> Result(Contract, DocumentError)
  pub fn parse(text: String) -> Result(Contract, LoadError)   // default limits
  pub type LoadError { InvalidJson(value.ParseError)  InvalidDocument(DocumentError) }
  pub fn value_codec(contract: Contract) -> Codec(Value)      // decodes by validating
  pub fn decode(codec: Codec(a), value: ValidatedValue) -> Result(a, DecodeError)
  // mismatch: DecodeError(path: [], reason: codec.ContractMismatch)
  pub fn describe_validation_error(error: ValidationError) -> String
  ```

  `ValidationError` stays separate from `DecodeError`, because the design
  separates schema rejection from native decoding failure. It uses
  `codec.PathSegment`, and `value_codec` reports validation failures with the
  typed path's text (`$["limit"]: integer outside range 1 to 10`). `encoded`
  becomes `value`; `matches` goes, because `decode` performs that check.

- **Breaks:** unreleased callers. **Effort:** M.

### JSONB-R7 Bound parsing by memory; one limits type

- **Problem.** The default admits 10 MiB, depth 128 and number bounds
  1024/800/1200 (parser_limits.gleam:27-31). Measured on OTP 28, 10 MiB of
  `1,` became a 503 MB `Value` (915 MB heap peak, 6.8 s); 10 MiB of 15-digit
  decimals became 176 MB (636 MB peak, 4.6 s); 10 MiB of short strings became
  61 MB (123 MB peak, 4.2 s).
  Each number stores its digits as a list of code points. Limits have two
  APIs: `parser.parser_limits`, `default_limits` and `LimitsError`
  (parser.gleam:11-30) duplicate `parser_limits.new`, `default` and
  `LimitsError` (parser_limits.gleam:8-31). Setters return `Result` only to
  reject non-positive values. The 1.x `blueprint.decode` calls `json.parse`
  with no limit (blueprint.gleam:149).

- **After.**

  ```gleam
  pub opaque type Limits                                         // in value
  pub fn default_limits() -> Limits          // 1 MiB, depth 128, numbers 1024/800/1200
  pub fn with_max_bytes(limits: Limits, bytes: Int) -> Limits    // below 1 rejects every input
  pub fn with_max_depth(limits: Limits, depth: Int) -> Limits    // 0 admits scalars only
  pub fn with_number_limits(limits: Limits, numbers: number.Limits) -> Limits
  ```

  Store the number coefficient compactly (opaque, no API change). Publish the
  worst-case heap per input byte beside the README defaults table. Give 1.x
  `decode` the same default byte check (fail closed).

- **Breaks:** unreleased callers; 1.x callers above 1 MiB raise the limit.
  **Effort:** S (limits), M (number representation).

### JSONB-R8 Flat, typed errors with renderers

- **Problem.** Errors nest `EncodeAtField`/`DecodeAtField` around a reason
  (codec.gleam:26-58), so callers recurse to branch. String payloads carry
  decisions: `EncodeInvalidNativeValue("UnsafeNativeInteger")` (:416-420),
  `DecodeMissingTagPayload("Missing payload")` (:1586) and
  `DecodeInvalidWireValue("invalid nullable value")` (:967); the library's
  own non-null rule uses `CustomEncodeReason` (:614, :803). Four encode reasons
  are never produced (`EncodeUnknownEnumLabel`, `EncodeUnknownTag`,
  `EncodeUnknownProperty`, `EncodeWrongTupleLength`). Three `BlueprintJson*`
  types (:66-89) duplicate `parser.ParseError`. No encode renderer exists, so
  fabric wrote one over `string.inspect` (fabric/internal/invocation.gleam:39-46).
- **After.**

  ```gleam
  pub type PathSegment { Field(String)  Index(Int) }
  pub type DecodeError { DecodeError(path: List(PathSegment), reason: DecodeReason) }
  pub type EncodeError { EncodeError(path: List(PathSegment), reason: EncodeReason) }
  // DecodeReason gains InvalidJson(value.ParseError), ContractMismatch, InvalidDefinition(_).
  // EncodeReason: IntegerOutsideRange, NumberOutsideRange, UnknownEnumValue,
  //   UnrepresentableInteger(number.IntegerConstructionError), NullInsideNullable,
  //   UnrepresentableNumber, InvalidDefinition(_), Custom(String)
  pub fn decode_failure(message: String) -> DecodeError   // for try_map and custom
  pub fn encode_failure(message: String) -> EncodeError
  pub fn describe_decode_error(error: DecodeError) -> String
  pub fn describe_encode_error(error: EncodeError) -> String
  pub fn is_limit_exceeded(error: DecodeError) -> Bool
  ```

  `decode_json` returns `DecodeError`, so `JsonDecodeError` goes. Renderers
  keep today's redaction (no input values, no custom text). Module docs say
  that reason unions and `Schema` may gain variants in minor releases and
  that a match needs a `_` branch; callers build errors through
  `decode_failure`/`encode_failure`, so a new record field breaks no one.

- **Breaks:** unreleased callers. **Effort:** M.

### JSONB-R9 Shrink and freeze the 1.x surface

- **Problem.** `json/blueprint/dynamic` is public (absent from
  `internal_modules`, gleam.toml:3); it exports `from(a: anything) -> Dynamic`
  (dynamic.gleam:53) and 30 decoders copied from stdlib 0.58. `Decoder` and
  `FieldDecoder` are public records whose `dyn_decoder` field uses that
  module's `DecodeError` (blueprint.gleam:14-28). The root module, the first
  name on HexDocs, holds the 1.x API.
- **After.** Move `dynamic` to `internal/`. Make `Decoder` and `FieldDecoder`
  opaque; `get_dynamic_decoder` returns
  `fn(Dynamic) -> Result(t, List(decode.DecodeError))`. Keep every 1.x
  combinator and add a module doc: "1.x API, frozen; use
  `json/blueprint/codec` unless you need recursive types". Do not mark it
  `@deprecated` while it is the only recursive path.
- **Breaks:** 1.x callers that import `dynamic` or construct or destructure
  `Decoder`/`FieldDecoder`. **Effort:** S.

### JSONB-R10 Smaller items

- **`value`.** `object(entries, policy: ObjectKeyPolicy)` (value.gleam:41)
  requires a policy with one variant (:13-15); after:
  `object(entries) -> Result(Value, DuplicateKey)`. Delete `null`, `bool`,
  `string`, `number` and `array`, which repeat the variant constructors. S.
- **`number`.** Make `FloatCandidate` (number.gleam:141) private and the three
  `integer_projection_limit_for_*` functions (:87, :101, :122) internal. Use
  `gleam/order.Order` instead of `NumberOrder` (:57). Rename `parse_number` to
  `parse` and `number_text` to `to_string`. Replace `IntegerProjectionLimit`
  with `to_int(number, max_digits: Int)`; `number.limits` is infallible. S.
- **Names.** `imap`/`try_imap` become `map(codec, from:, to:)` and
  `try_map(codec, from:, to:, placeholder:)`. `nullable` returns
  `Codec(Option(a))`, matching `json.nullable` and `decode.optional`. `new`
  and `from_parts` become one `custom(encode:, decode:, schema: Option(Schema), placeholder:)`. S.
- **`float`.** The design lists a missing `Float` codec. Exact projection
  rejects `0.1`, so the codec must round to the nearest binary64 on decode;
  the name `float` is the named opt-in the design asks for, and its doc must
  say so. Additive. S.
- **Docs.** No public module has a module doc, and `runtime`, `parser`,
  `document` and `value` have no doc comments. Start the README with the
  section 2 program and the defaults table. Today it opens with a target
  matrix, wraps each quickstart call in `result.map_error`, spends lines
  166-727 on 1.x examples, cites a missing `PUBLIC-API.md` (README.md:46), and
  names Node 24.19.0 while CI ran 24.15.0. S.

All rows break unreleased callers only, except `float` (additive).

### What 1.x users must migrate

With R9, 1.x code that only uses combinators compiles unchanged.

- **Required.**
  - Replace imports of `json/blueprint/dynamic` with `gleam/dynamic/decode`.
  - Build `Decoder` and `FieldDecoder` with combinators instead of record
    syntax; `get_dynamic_decoder` errors become `decode.DecodeError` (same fields).
  - `blueprint.decode` rejects input above the default byte limit (R7).
- **Optional: moving a type to `Codec`.** Each item changes wire format or
  acceptance and needs review against stored data.
  - Objects are closed, so unknown fields fail.
  - `optional_field` rejects `null` unless the inner codec is `nullable`; 1.x
    treated absent and `null` alike.
  - Unions use `{"tag","value"}` instead of `{"type","data"}` (open question 6).
  - String enums encode a bare string; 1.x `enum_type_encoder` wrote `{"enum": label}`.
  - Duplicate keys fail and numbers are exact.
  - Schemas use Draft 2020-12 instead of the Draft-07 label.
  - Recursive types stay on `Decoder`.
- **Unreleased-branch users** rewrite against R1-R10 and regenerate.

## 5. Defaults table

| Operation                                          | Current default                                   | Proposed default                                   |
| -------------------------------------------------- | ------------------------------------------------- | -------------------------------------------------- |
| `decode_json`, `value.parse` input bytes           | 10 MiB (915 MB heap peak measured)                | 1 MiB, worst-case heap documented                  |
| Nesting depth                                      | 128                                               | 128                                                |
| Number token bytes / significant digits / exponent | 1024 / 800 / 1200                                 | unchanged (800 digits admit exact subnormals)      |
| `int()` decode digits                              | 24, hard-coded and undocumented (codec.gleam:427) | 24, documented                                     |
| Generated native decoders, 1.x `decode`            | none (gleam/json parser)                          | default byte check before parsing                  |
| `codec.decoder` bridge                             | n/a (new)                                         | none; the caller's parser owns limits (documented) |
| `contract.parse`                                   | caller passes limits                              | default limits                                     |
| `contract.validate`, `document.load`               | none; walk an in-memory `Value`                   | unchanged; bounded by parse depth when parsed      |
| Duplicate keys, unknown object fields              | rejected                                          | rejected                                           |
| Error rendering                                    | omits input values and custom text                | same rule for encode and validation renderers      |

No operation blocks, waits, retries or starts a process; the package is pure,
and its README should say so (convention 5 does not apply).
Today the defaults appear only in README and migration-guide prose, and the
`parser_limits.default` doc names none of the numbers.

## 6. Convention feedback

- **1. Opaque configuration.** Fits `value.Limits`. A setter that can only fail
  on a non-positive value should not return `Result`, because a limit of 0 has
  a fail-closed meaning. Codec definitions follow the same rule: validate once
  and report a typed error at first use (R3).
- **2. Constructed data is opaque.** Two exceptions are needed. `Value` is a
  closed algebra (JSON has six kinds) and is safer transparent. `Schema` must
  stay transparent, because generated modules build it in `const`
  declarations, which cannot call functions. The convention should allow a
  transparent growing union whose docs require a rejecting `_` branch.
- **3. Growing unions get a classification.** For `DecodeReason`,
  `is_limit_exceeded` plus `describe_*` covers what callers branch on (bad
  input versus oversized input); a `kind` enum would repeat the reasons.
- **4. Bounded by default.** A byte limit does not bound memory: the parsed
  `Value` is up to 48 times the input here. Each default should come from
  measured heap and CPU per unit of input.
- **6. Errors.** `codec` owns three boundaries (definition, encode, decode), so
  one `describe_error` per module does not fit; use `describe_<boundary>_error`.
- **8. JSON currency.** Exporting to `json.Json` and `decode.Decoder` fits (R2).
  Building a Blueprint codec from them does not, because a gleam_json pair has
  no schema; `custom` with an explicit schema covers that case. The convention
  has a hidden cost: `decode.Decoder(a)` cannot fail without a value of `a`, so
  a bidirectional codec that offers `decoder` must carry a placeholder.
- **9. One ordinary path.** Fits; R1, R5 and R10 apply it.

## 7. Open questions

1. **1.x placement.** Keep the frozen 1.x API at the root (recommended: 1.x
   code keeps compiling), move it to `json/blueprint/legacy` so the root name
   serves new users, or drop it and lose recursive types until `Codec`
   supports `$ref`.
2. **Invalid definitions.** Report them at first use as typed errors with
   `check` (recommended), panic at construction, or keep `Result`.
3. **Codegen.** A dev-only package (recommended), an internal module, or a
   public module here.
4. **Numbers in `to_json`.** A typed error for numbers without an exact
   gleam_json form (recommended), or raw number text through FFI, which depends
   on gleam_json's private representation (iodata on Erlang; `JSON.rawJSON` on
   JavaScript, Node 21 or later).
5. **Placeholder for `try_map` and `custom`.** An explicit argument
   (recommended, as in `decode.failure`), or an untyped placeholder that
   crashes if a builder body inspects it. Three of the four `try_imap` uses in
   the apps and siblings reject the inner placeholder, so derivation alone fails.
6. **1.x union wire.** Offer `union` with configurable keys (`"type"`,
   `"data"`) for stored 1.x data, or keep only `{"tag","value"}`.
7. **Default byte limit.** 1 MiB (recommended), or 10 MiB with a compact
   number representation, which saves about a third of the heap per number but
   not the per-element overhead.
