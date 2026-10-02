# API card: `json_blueprint`

Repo: `/code/gleam-dream/json_blueprint`, branch `implementation/schema-aware-core`.
Design: [blueprint-design.md](../../../blueprint-design.md). Scanned 2026-10-01.

## Health

- Git head: `129c963 feat: describe codec schemas and render decode errors`. The working tree is clean.
- The gate is the CI workflow `.github/workflows/test.yml`: `gleam format --check src test`, `gleam test --target=erlang`, `gleam test --target=javascript`. The repo has no lefthook config, AGENTS.md or scripts directory. The Nix shell provides gleam 1.17.0, OTP 28, rebar3 and Node.
- Results through `nix develop`:

  | Command                          | Result                                                                                                       |
  | -------------------------------- | ------------------------------------------------------------------------------------------------------------ |
  | `gleam format --check src test`  | pass                                                                                                         |
  | `gleam build`                    | pass                                                                                                         |
  | `gleam test --target=erlang`     | **157 passed, no failures** (OTP 28; includes a benchmark printout)                                          |
  | `gleam test --target=javascript` | **156 passed, no failures** (Node v24.15.0); 2 unused-import warnings in `test/api_control_test.gleam:12,17` |

  No test needs an external service. `test/schema_check.py` (the `jsonschema` oracle) is not part of `gleam test`.

- The manifest still says `version = "1.7.1"` (`gleam.toml:2`). 2.0 is unreleased, and the CHANGELOG says no release decision has been made.
- Open items:
  - `src/json/blueprint.gleam:738`: a TODO says the `decode0` empty-object check is disabled because of a JS-target failure.
  - `README.md:46` cites `PUBLIC-API.md`, which does not exist in the repo.
  - The README says Node v24.19.0, but the version exercised here was v24.15.0.
  - The CHANGELOG lists these as out of scope: recursive references, untagged unions, regex/pattern, browser JS, and JS integers beyond the safe-integer range.

## Purpose and scope delivered vs design

Blueprint provides one bidirectional `Codec(a)` that derives the encoder, the decoder and a Draft 2020-12 schema. It also provides these pieces:

- an exact JSON `Value` and decimal `Number` model;
- a bounded strict parser that rejects duplicate keys;
- finite runtime contracts, which validate a `Value` against a `Schema` and gate native decoding;
- a loader for finite Draft 2020-12 documents;
- typed `codegen.Definition(a)` values that compile to checked-in Gleam source.

The released 1.x one-way `Decoder` and Draft-07 `schema` module remain for recursive types. The design's core facade (values, codecs, schema derivation, contracts, validation, checked combinators) is delivered. Generation is also delivered, ahead of the design, which calls it future tooling.

Larger design capabilities still missing:

- recursive schemas (`$ref`/`$defs`) in `Codec` (only the legacy `Decoder` has them);
- general or N-ary unions (`anyOf`/`oneOf`) and a flat tagged registry. `tagged` is binary only, and nesting it nests the `{tag, value}` envelope;
- string length, `pattern`/`format`, `multipleOf`, collection constraints, numeric enums and enum aliases;
- a `Float` codec (only `Int`, `Number`, `String`, `Bool` exist) and a dict/map codec;
- an unmodelled-schema escape hatch with explicit validation semantics (Relay invents its own override; see Composition seams);
- named, stable generated names, plus recursive and union generation;
- complete legacy (1.x) wire, error and number migration.

## Public modules

| Module                         | Responsibility                                                                                                                                                                                                                                                                 |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `json/blueprint/codec`         | `Codec(a)`, primitives, `pair`/`list`/`nullable`, `Properties` + `object`/`record2`/`record3`, `tagged`, `string_enum`, ranges, `imap`/`try_imap`, `describe`, JSON text encode/decode, `Schema` AST, schema rendering, error types. It also exports 45 generated-code helpers |
| `json/blueprint/codegen`       | Inspectable `Definition(a)` mirror of the codec combinators; `runtime(def)` gives a `Codec`; `compile(path, name, def)` gives `GeneratedModule` source                                                                                                                         |
| `json/blueprint/runtime`       | `RuntimeContract` (normalized `Schema`), `validate(contract, Value) -> ValidatedValue`, `matches`, `same_schema`, `decode(codec, validated)`                                                                                                                                   |
| `json/blueprint/document`      | `load(Value) -> Result(RuntimeContract, DocumentError)` for finite Draft 2020-12 documents                                                                                                                                                                                     |
| `json/blueprint/parser`        | Strict bounded parse of bytes or strings into `Value`; `parse_schema_document[_from_string]`; re-exports limits                                                                                                                                                                |
| `json/blueprint/parser_limits` | Opaque `ParserLimits`: `new`, `default`, `with_max_bytes`, `with_max_depth`, `with_number_limits`                                                                                                                                                                              |
| `json/blueprint/value`         | `Value` (`Null`/`Bool`/`String`/`Number`/`Array`/`Object` as an ordered list of pairs) and constructors                                                                                                                                                                        |
| `json/blueprint/number`        | Opaque exact decimal `Number`, limits, `parse_number`, `compare`, checked `from_int`/`to_int_exact`/`from_float_exact`/`to_float_exact`                                                                                                                                        |
| `json/blueprint/json_text`     | `render_value(Value) -> String`                                                                                                                                                                                                                                                |
| `json/blueprint` (legacy)      | 1.x `Decoder(t)`, `decode0..9`, `tuple2..6`, `encode_tuple2..9`, union and enum helpers, `self_decoder`/`reuse_decoder`, `generate_json_schema`                                                                                                                                |
| `json/blueprint/schema`        | Legacy Draft-07-labelled schema AST (refs, formats, constraints)                                                                                                                                                                                                               |
| `json/blueprint/dynamic`       | Copy of the deprecated stdlib `gleam/dynamic` decoders (1.x support); public                                                                                                                                                                                                   |

## Common path

This snippet was compiled and run from a separate consumer package. It prints
`{"name":"Ada","age":36}`, a 2020-12 schema with `additionalProperties:false`, and `{"tag":"circle","value":3}`.

```gleam
import json/blueprint/codec

pub type User { User(name: String, age: Int) }
pub type Shape { Circle(radius: Int) Square(side: Int) }

pub fn demo() {
  let assert Ok(user) =
    codec.record2(
      codec.required("name", codec.string() |> codec.describe("Display name")),
      codec.required("age", codec.int()),
      User, fn(u) { u.name }, fn(u) { u.age },
    )
  // Unions are binary `tagged` + imap from Either; >2 variants nest envelopes.
  let assert Ok(either) = codec.tagged("circle", codec.int(), "square", codec.int())
  let shape = codec.imap(either,
    fn(e) { case e { codec.Left(r) -> Circle(r) codec.Right(s) -> Square(s) } },
    fn(s) { case s { Circle(r) -> codec.Left(r) Square(s) -> codec.Right(s) } })

  let assert Ok(text) = codec.encode_json(user, User("Ada", 36))  // Result(String, EncodeError)
  let assert Ok(_) = codec.decode_json(user, text)                // Result(User, JsonDecodeError)
  let assert Ok(_schema) = codec.schema_json(user)                // Result(String, SchemaError)
  codec.encode_json(shape, Circle(3))
}
```

## Configuration and advanced paths

- **Strict decoding**:
  - `codec.decode_json` always uses the strict parser. It rejects duplicate keys, keeps exact numbers, and applies default limits of 10 MiB, depth 128, and 1024/800/1200 number bounds.
  - `codec.decode_json_with_limits(codec, limits, source)` takes `parser_limits.default() |> with_max_bytes(n)`.
  - `decode_json_native` opts into `gleam/json` parsing (generated codecs only).
  - Objects are always closed, so unknown keys fail. There is no permissive or open-object mode.
- **Missing vs null**: `optional` returns `Optional(a)` (`Missing`/`Present`), `optional_option` returns `Option(a)`, and `nullable` returns `Nullable(a)` (`Null`/`NonNull`). These are separate dimensions.
- **Larger records**: `combine(props, props) -> Result(Properties(#(a, b)), PropertyError)`, then `object`, then `imap`/`try_imap` from nested tuples.
- **Refinements**:
  - `integer_between`, `number_between` (`Result(_, ConstraintError)`) and `string_enum(List(#(String, a)))` (`Result(_, EnumError)`);
  - `try_imap` for application validation that keeps the base schema.
- **Custom codecs**:
  - `new(encode, decode)` has an unknown schema.
  - `from_parts(encode, decode, schema)` supplies the schema without checking it.
  - `from_json_parts(..)` adds a native JSON text encoder and decoder.
  - All of these work over `Value`, not `gleam/json` or `Dynamic`.
- **Runtime contracts**:
  - Build one with `runtime.from_codec`/`from_schema`, `document.load(Value)`, or `parser.parse_schema_document_from_string(limits, text)`.
  - Then `runtime.validate(contract, value)` returns `ValidatedValue`, and `runtime.decode(codec, validated)` checks that the codec's schema shape matches the contract.
  - `same_schema` compares shapes and ignores descriptions.
- **Schema output**:
  - `codec.schema` returns the `Schema` AST (public, matchable; adding a variant is a breaking change).
  - `codec.schema_value`/`schema_document` return a `Value`, and `schema_json` returns a `String`.
- **Generation**:
  - Build a `codegen.Definition(a)` with `named_mapping(fn, "mod.fn", fn, "mod.fn")` and `enum_variant(label, value, "mod.Ctor")`.
  - Then call `compile(module_path, name, def) -> GeneratedModule`. The caller writes the file, formats it, and keeps a freshness test.

## Lifecycle and supervision

Confirmed pure. No module starts a process, opens a resource, or uses a registry. The FFI covers only number and float bit handling and legacy dynamic classification. A `Codec` is a record of closures. Fabric notes that capturing nested codecs inflates the closure environments OTP copies into tasks, and works around it at `fabric/src/fabric/graph/llm.gleam:119-125`.

## Failure model

| Outcome                           | Type                                                                                                                                     |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Construction-time definition bugs | `PropertyError.DuplicateProperty`, `UnionError.DuplicateTag`, `EnumError`, `ConstraintError`, `codegen.CompileError`                     |
| Value encode                      | `EncodeError` = `CannotEncode(EncodeReason)` nested in `EncodeAtField`/`EncodeAtIndex`                                                   |
| Value decode                      | `DecodeError` = `CannotDecode(DecodeReason)` nested in `DecodeAtField`/`DecodeAtIndex`                                                   |
| JSON text decode                  | `JsonDecodeError` = `BlueprintParserFailure(location+reason)` / `NativeJsonFailure(json.DecodeError)` / `TypedCodecFailure(DecodeError)` |
| Schema unavailable                | `SchemaError.UnknownSchema` (codec), `runtime.ContractError.UnknownSchema`                                                               |
| Contract validation               | `runtime.ValidationError(path: List(PathSegment), reason: ValidationReason)`                                                             |
| Document load                     | `DocumentError` = `Malformed`/`Unsupported`/`UnsupportedDialect`/`SchemaInvariant`, each with a path                                     |
| Parse/admission                   | `parser.ParseError(Location, ParseErrorKind)`, `AdmissionError` = parse or document                                                      |

Callers can tell syntax, resource limits, typed-shape failures, schema invalidity and missing schema apart by constructor. `render_json_decode_error` gives redacted prose for decode errors only. No `EncodeError` renderer exists, so fabric writes its own (`fabric/src/fabric/internal/invocation.gleam:39`).

## Composition seams

- **Relay tools** (`relay/src/relay/tool.gleam:249-325`):
  - `tool.definition(name, input: Codec(input), output: Codec(output))` admits object-root schemas once and keeps the codecs for decoding calls.
  - Relay's public API exposes `blueprint/value.Value` in `with_input_schema_override(def, Value)` (`tool.gleam:278`) and in client `decode_output: fn(Value)` (`relay/src/relay/client.gleam:464,854`). This is a richer-schema escape hatch, and its validation semantics are Relay's, not Blueprint's.
  - Relay still parses transport JSON with `gleam/json` + `Dynamic` and bridges it by hand (`client.gleam:2381` `dynamic_to_json`).
- **llm_wire tools and structured output**:
  - `types.tool_from_codec(name, description, Codec(a))` derives `codec.Schema` and a `RuntimeContract` (`llm_wire/src/llm_wire/types.gleam:310-343`). `tool_from_contract` admits a schema-only tool.
  - `session.prepare_structured(.., output_codec: Codec(output))` (`session.gleam:212`) validates through `runtime.validate` and then `runtime.decode` (`internal/schema.gleam:307`).
  - Provider `Spec.project_tool_schema: fn(codec.Schema) -> Result(json.Json, _)` exposes Blueprint's AST in llm_wire's provider extension point (`provider.gleam:23`).
  - llm_wire reimplements `Value -> json.Json` with a lossy float fallback for numbers (`internal/schema.gleam:17-60`), because Blueprint offers no `gleam/json` bridge.
  - It flattens Blueprint errors to `string.inspect` (`types.gleam:320,330`; `internal/schema.gleam:323,329`).
- **Fabric tools** (`fabric/src/fabric/tool.gleam:58,135`):
  - Tools hold `input`/`output: Codec(_)`, check arguments with `decode_json` + `render_json_decode_error`, and encode results with `encode_json`.
  - Fabric also uses Blueprint codecs for **ordinary non-schema persistence**: graph receipts and fork results are built as nested `pair`s with `try_imap` and string tag dispatch (`fabric/src/fabric/graph/llm.gleam:128-175`, `graph/fork.gleam:74-78`). The design reserves Blueprint for schema-aware paths, and this use couples fabric's checkpoint wire format to Blueprint's.
- **Interop with `gleam/json` and `gleam/dynamic/decode`: there is none in the 2.0 core.**
  - No `from_decoder(decode.Decoder(a))`, no `Value <-> json.Json` or `Value <-> Dynamic` conversion, and `encode_json` returns `String`, not `json.Json`.
  - An existing `decode.Decoder` or `fn(a) -> json.Json` cannot be reused as a `Codec`. The caller rewrites it as combinators or hand-writes Value-level functions for `codec.new`.
  - `from_json_parts` accepts native text functions but still requires Value functions and a schema, and ordinary `decode_json` ignores its native decoder.
  - Embedding Blueprint output in a `gleam/json` tree means rendering to text and reparsing, or writing your own bridge. Relay and llm_wire each wrote one.
- **Independence**: Blueprint imports no sibling package, which is correct. Its only deps are `gleam_stdlib`, `gleam_json` and `gleam_crypto`; the last is used by the legacy schema hashing and codegen fingerprints.

## Ergonomics concerns

1. **Generated-code machinery is public facade.** 45 of the 82 `pub fn` in `codec.gleam` are helpers for generated modules (`codec.gleam:384-1068`), for example `encode_native_object_with` and `decode_native_required_property_with`. Several take raw `Dynamic` (`decode_native_string(raw: Dynamic)` at `codec.gleam:861`, plus `:873` and `:903`). This breaks "one ordinary path" and "do not spread `Dynamic` through ordinary callers", and it freezes generator internals as semver API. Mark them `@internal` or move them to an internal module that generated code may import.
2. **Overlapping and incomplete record/union families.**
   - `record2`/`record3` (`codec.gleam:1271,1298`) form an arity family capped at 3. Larger records fall back to `combine`, `object` and tuple `imap`, which gives two ways to build a record and a cliff at four fields. Fabric shows the cost with hand-nested `pair(string, pair(string, pair(..)))` (`fabric/.../graph/llm.gleam:128-136`).
   - `tagged` is binary over `Either` (`codec.gleam:1505-1518`, `TaggedSchema(String, Schema, String, Schema)` at `:107`), so an N-variant union nests envelopes, and fabric falls back to `pair(string, string)` dispatch.
   - The legacy root adds `decode0..9`, `tuple2..6` and `encode_tuple2..9` (`blueprint.gleam:562-1125`). Those are published, so removing them has a migration cost.
   - A builder (`use` over properties) or a list-of-variants union would collapse both families.
3. **Required arguments that don't change behavior, and duplicated vocabularies.**
   - `value.object(entries, policy: ObjectKeyPolicy)` (`value.gleam:41`) makes callers pass a policy whose only variant is `RejectDuplicates` (`value.gleam:13-15`).
   - `parser.parser_limits`/`default_limits`/`LimitsError` (`parser.gleam:11-30`) duplicate `parser_limits.new`/`default`/`LimitsError` (`parser_limits.gleam:8-31`).
   - Parse failures have two public vocabularies: `parser.ParseErrorKind` (`parser.gleam:36`) and `codec.BlueprintJsonParseReason` (`codec.gleam:77`).
   - Locations have three shapes: nested `DecodeAtField` in codec, `runtime.PathSegment`, and a separate `document.PathSegment` (`runtime.gleam:46`, `document.gleam:9`).
4. **Stringly-typed errors at key outcomes.**
   - `runtime.decode` reports a contract/codec mismatch as `CannotDecode(CustomDecodeReason("Schema mismatch"))` (`runtime.gleam:140,144`). The mismatch is indistinguishable from a caller's custom reason and is lumped with decode failures.
   - `EncodeInvalidNativeValue(String)`, `DecodeInvalidWireValue(String)` and `DecodeMissingTagPayload(String)` (`codec.gleam:20,48,42`; the payload is always `"Missing payload"`) carry prose.
   - Downstream, every consumer collapses errors with `string.inspect` (llm_wire `types.gleam:320`, fabric `invocation.gleam:45`), because there is no `EncodeError` renderer and runtime/document errors have no renderer at all.
5. **Missing `gleam/json` and `decode` interop pushes duplication into siblings.** There is no `Value -> json.Json`, `Codec -> json.Json` encode, or `decode.Decoder` adapter (see Composition seams). Relay and llm_wire each maintain their own bridge, and llm_wire's bridge silently goes through `Float` for non-integers. This bridge is the design's own seam ("ordinary JSON stays on gleam/json"), so Blueprint should own a lossless one.
6. **Naming collisions with siblings, and a leaky legacy surface.**
   - `json/blueprint/runtime` (contracts) collides with `relay/runtime` (process lifecycle), and llm_wire imports both vocabularies.
   - `codegen.Definition` reuses the name that relay and fabric give a tool definition.
   - Legacy `blueprint.Decoder` is a non-opaque record with public `dyn_decoder` fields (`blueprint.gleam:14-28`), and `get_dynamic_decoder` (`:137`) returns a private alias over `Dynamic`.
   - `json/blueprint/dynamic` exports a copy of the deprecated stdlib `Dynamic` API, including `from(a: anything) -> Dynamic` (`dynamic.gleam:53`). It is not in `internal_modules` (`gleam.toml:3`).
   - codegen mixes error types: `combine` returns `codec.PropertyError` (`codegen.gleam:748-751`), `integer_between` returns `codec.ConstraintError` (`:234`), and everything else returns `CompileError`.
