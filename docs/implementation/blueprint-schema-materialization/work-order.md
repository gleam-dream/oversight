# Blueprint schema materialization experiment

## Objective

- Work in `/code/gleam-dream/json_blueprint` on
  `implementation/schema-aware-core` at `8f2d46c5a4174a3700e0f214e37e612b0c65316a`.
- Test whether two heterogeneous `Codec(a)` values can yield one deterministic
  generated Gleam module whose public functions reconstruct their existing
  `codec.Schema` trees.
- Keep this as test/dev tooling. The result is evidence for a possible later
  product surface, not a promoted public generation API.

## Existing contract

- `Codec(a)` already stores `schema: Result(Schema, SchemaError)`, so
  `codec.schema(codec)` is an O(1) field retrieval rather than a repeated codec
  traversal.
- Materialization may avoid constructing application codecs and their closures
  when only schemas are needed. Each generated function may still allocate its
  `Schema` value, so this experiment establishes neither constant evaluation nor
  zero runtime work.
- Keep `Codec`, `Schema`, `RuntimeContract`, and `Number` unchanged. Do not add
  `Dynamic`, a second schema representation, a static/runtime codec split,
  compiler macros, or types generated from schemas.

## Experimental shape

- Add a small pure emitter under `test/` or test support. It accepts a validated
  caller-selected module name and a list of schema exports, then returns the
  module path and source text.
- Derive each export separately with a generic operation equivalent to
  `from_codec(name: String, codec: Codec(a)) -> Result(SchemaExport, Error)`.
  `SchemaExport` contains only the accessor name and derived `Schema`, so exports
  from codecs with different native types can share one list without erasing
  native values through `Dynamic`.
- Return `UnknownSchema(accessor)` when `codec.schema` returns
  `Error(codec.UnknownSchema)`. Do not omit that export or invent a schema.
- Validate the caller-selected module path as slash-separated lowercase Gleam
  module segments and each accessor as a non-keyword lowercase Gleam identifier.
  Reject invalid names and duplicate accessors before emission; never splice an
  unchecked name into source or a filesystem path.
- Emit the existing public `codec.Schema` constructors directly. Preserve list
  order and every string exactly, using one pure Gleam string-literal escaping
  function for quotes, backslashes, controls, newlines, and Unicode.
- Return a located typed unsupported result for `NumberRangeSchema`. Its bounds
  are opaque `Number` values; do not inspect internals, convert through `Float`,
  or add runtime parsing and another import merely to reconstruct them.
- The generated module imports only `json/blueprint/codec`, exposes functions
  such as `order_schema() -> codec.Schema`, and has no runtime dependency on the
  emitter or runner.

## Fixtures

- Build two codecs with different native types and finite but heterogeneous
  schema trees. Together cover objects with required and optional properties,
  lists, pairs, nullable values, tagged alternatives, string enums, integer
  bounds, exact numbers without bounds, booleans, and `imap` schema retention.
- Use caller names `generated/schema_catalog`, `order_schema`, and
  `decision_schema`. Include wire property names, enum labels, and tags with a
  quote, backslash, newline, Unicode, keyword text, and source-like text; these
  values must remain data rather than identifiers or source.
- Add negative fixtures for an invalid module segment, invalid and keyword
  accessors, duplicate accessors, a custom `codec.new` with `UnknownSchema`, and
  a `number_between` schema rejected at its exact tree path.

## Compile proof

- Add a tiny explicitly named dev runner if file emission needs an effectful
  boundary. Keep rendering pure; the runner writes an independent fixture under
  ignored `build/schema-materialization/` and may use a minimal test-only FFI.
- The fixture contains its own `gleam.toml`, the generated module, and a
  separately authored test module. The generated module must compile without
  copying or importing emitter code.
- Run the generator as an ordinary module, then run ordinary package checks in
  the generated fixture:

  ```sh
  cd /code/gleam-dream/json_blueprint
  nix develop --command gleam run -m schema_materialization_runner
  cd build/schema-materialization/fixture
  nix develop --command gleam check
  nix develop --command gleam test
  ```

- In the fixture tests, rebuild the two source codecs and assert structural
  equality between each generated accessor and `codec.schema(runtime_codec)`.
  This comparison is the primary oracle; optional JSON rendering is outside this
  experiment.

## Determinism and acceptance

- Emit twice from the same tracked fixture inputs and compare source bytes and
  output paths. Also compare a reordered export list according to one declared
  rule: preserve caller order or sort by validated accessor, then test that rule.
- CI starts from a clean `build/schema-materialization/`, regenerates the ignored
  fixture, compiles it, runs its structural-identity tests, and repeats emission.
  The byte comparison proves determinism only. Do not claim a stale-artifact
  check from `git diff` over ignored output; tracked codec builders and tests are
  the source inputs.
- Accept the experiment when both heterogeneous accessors compile and equal the
  schemas already stored in their codecs, repeat emission is byte-identical,
  adversarial strings survive exactly, and every name, `UnknownSchema`, and
  unsupported-number-range case fails with its typed result.
- Keep recursive `$ref`/`$defs`, native type or codec generation, JSON-to-native
  code generation, a CLI framework, committed generated artifacts, and public
  API promotion deferred. Do not alter Wave 4 acceptance or release claims.

## Handoff

- Run implementation through external `agy --sandbox --dangerously-skip-permissions`
  with its configured default model and no model override. Use Sol with medium
  reasoning for independent review. The review checks scope, generated-module
  independence, exact structural equality, deterministic source, name
  validation, escaping, and honest unsupported results.
- Return changed files, exact commands and results, supported and unsupported
  constructors, and any design mismatch. Do not commit, push, or publish.
