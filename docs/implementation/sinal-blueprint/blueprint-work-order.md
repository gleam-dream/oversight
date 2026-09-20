# JSON Blueprint implementation work order

## Assignment and stop point

Evolve the existing package in `/code/gleam-dream/json_blueprint` on a separate
branch. Do not create a blank successor package. The existing 1.7.1 API, Erlang
and JavaScript implementations, and test examples are compatibility evidence and
must remain working during the scaffold unless a later reviewed migration
decision explicitly changes them.

The authoritative design baseline is oversight commit
`bd0b83743533313eb9b4eee2bf7f99ed68a26750`:

- [`blueprint-design.md`](../../../blueprint-design.md)
- [`PUBLIC-API.md`](../../../PUBLIC-API.md)
- [`API-COVERAGE.md`](../../../API-COVERAGE.md), JSON Blueprint rows
- [`research/blueprint-number-policy.md`](../../../research/blueprint-number-policy.md)
- [`research/blueprint-compatibility-contract.md`](../../../research/blueprint-compatibility-contract.md)
- [`research/blueprint-generation-contract.md`](../../../research/blueprint-generation-contract.md)

This first external run ends at a review checkpoint. Deliver:

1. a recorded clean 1.7.1 baseline on both existing targets and the frozen
   compatibility oracles;
2. branch `implementation/schema-aware-core` from the recorded baseline HEAD;
3. a compiler-checked new schema-aware public surface alongside the legacy API,
   with honest named `todo` bodies and no legacy breakage;
4. a traced exact-number/schema/compatibility oracle corpus;
5. one focused new behavior test red for the intended missing behavior, or one
   small red-to-green vertical only after all prior checkpoint artifacts exist;
6. the standard report at the end of this file.

Stop for independent Sol Medium review. Do not push, publish, rewrite history,
access secrets, broadly implement the package, or change the old wire contract.

## Repository and branch safety

At planning time the repository is clean at
`0e379c6491d34aca49795f716e87b9003df0130e` (`v1.7.1`, `main`,
`origin/main`) with origin `lostbean/json_blueprint`. It has no `AGENTS.md`.
Read `gleam.toml`, `manifest.toml`, `flake.nix`, the README, all source modules,
and all tests before editing. Preserve any user changes or newer commits.

First record, without mutation:

```sh
git status --short --branch
git rev-parse HEAD
git remote -v
git branch --list implementation/schema-aware-core
nix develop --command gleam --version
nix develop --command gleam deps list
nix develop --command gleam check --target erlang
nix develop --command gleam test --target erlang
nix develop --command gleam check --target javascript
nix develop --command gleam test --target javascript
```

Also run the independent compatibility baseline before any branch change:

```sh
cd /code/gleam-dream/oversight
nix develop --command python3 playground/blueprint_compatibility/scripts/check.py
```

The baseline must pass. A baseline failure is a checkpoint blocker, not a reason
to edit expectations. Return to `/code/gleam-dream/json_blueprint`. If the branch
does not exist, create it from the exact recorded HEAD. If it exists, inspect its
tip, merge base, status, and changes; never reset or overwrite it. Reuse it only
if it is clean, based on the intended baseline, and contains no unrelated work;
otherwise stop and report the collision.

The flake includes Gleam, OTP 28, rebar3, and Node.js but no formatter/check
output today. Do not claim `nix flake check` covers formatting unless you add and
review such a check. Preserve JavaScript support even though new runtime-contract
work begins Erlang-first; a new Erlang-only module must be isolated and its JS
status explicit rather than deleting the existing JS FFI.

Start Gleam language intelligence before edits. Detect the configured
`agent-lsp`, launch it through
`nix develop --command agent-lsp gleam:gleam,lsp`, inspect capabilities, and use
absolute paths. Do not install another bridge unless the configured probe is
actually absent. Use LSP for symbols, references, and diagnostics; the compiler
and target-specific tests remain authoritative.

## Product boundary

Blueprint is required only when JSON Schema is part of the contract: schema
declaration/derivation, schema-aware validation, runtime schema contracts,
structured outputs, or tool declarations. It is not the ecosystem's ordinary
JSON layer. Do not create a universal codec package and do not make Sinal, jobs,
workflows, security messages, or ordinary provider envelopes depend on
Blueprint.

Within Blueprint, one opaque exact `Number` is the only JSON numeric value.
`Value` must not gain parallel `Int` and `Float` cases. Native `Int` and `Float`
enter and leave through explicit checked projections. JSON Schema acceptance and
native projection are different results: a schema-valid exact decimal may be
inexact or out of range for a native type. Parser/resource rejection is also
separate from either result.

Source generation is experimental tooling outside the initial public facade.
Keep it in the roadmap and preserve the existing laboratory evidence, but do not
publish generation APIs or spend this first run implementing them.

## Preserve the released API before adding the migration surface

The released module [`src/json/blueprint.gleam`](/code/gleam-dream/json_blueprint/src/json/blueprint.gleam)
exports `Decoder`, `FieldDecoder`, schema generation, primitive/collection/tuple/
object/union/enum decoders, recursive decoder support, mappings, and encoders.
[`src/json/blueprint/schema.gleam`](/code/gleam-dream/json_blueprint/src/json/blueprint/schema.gleam)
currently renders its historical schema vocabulary. Existing Erlang and JS FFI,
the main test file, and recursive/union/enum-tuple-optional examples are baseline
contracts. Do not rename or remove them during scaffold work.

The compatibility oracle already establishes deliberate facts that must not be
blurred:

- 1.7.1 decoding can be adapted only with a caller-supplied encoder; it does not
  become a bidirectional codec automatically.
- the adapter's schema is unknown rather than guessed;
- 1.1.0 and 1.7.1 differ on `decode0` acceptance;
- the 1.7.1 declared Draft 7 tuple schema uses `prefixItems`, so decoder and
  Draft 7 validator acceptance disagree for swapped element types;
- legacy `{type,data}` and enum envelopes are not the new finite string-enum or
  tagged codec wire shape.

Any changed legacy acceptance must be proposed as a documented compatibility
decision with source, wire, schema, and corrected-behavior impact separated. It
is not authorized in this checkpoint.

## Scaffold: compile-green, behavior unfinished

Add the production-bound schema-aware surface within the same package, alongside
the legacy root module. Prefer focused modules under the existing
`json/blueprint/*` namespace (for example `value`, `number`, `codec`, `runtime`,
and `document`) rather than overloading the legacy `Decoder` record or creating a
second package. Exact module names may follow compiler/reference analysis, but
the checkpoint report must map them to the families below. Do not expose the old
vendored/private `Dynamic` machinery through the new API and do not wrap it just
to avoid implementing a typed boundary.

Use opaque types, checked constructors, custom errors, and exhaustive cases. Use
`todo as "..."` for unfinished executable paths. Never use fake `Nil`, an
undefined generic, forged opaque constructors, raw panic, or a permissive wrapper
to make compilation green. Inventory every todo warning.

The compile-green public scaffold must represent:

- `Number`: explicit positive resource limits; JSON-number parsing; canonical
  text; mathematical comparison/integrality; `from_int`; checked exact `to_int`;
  checked finite `from_float` and exact `to_float`; distinct syntax, token,
  significand, exponent, fractional, digit-limit, overflow, underflow, inexact,
  and nonfinite errors. Base this on
  [`json_number.gleam`](../../../playground/interface_lab/src/lab/json_number.gleam),
  [`json_number_ffi.erl`](../../../playground/interface_lab/src/json_number_ffi.erl),
  and [`EXACT-NUMBERS.md`](../../../playground/interface_lab/EXACT-NUMBERS.md),
  while choosing the frozen public term `Number` rather than preserving the
  experiment's `JsonNumber` name by inertia.
- `Value`: null, boolean, string, exact number, array, object. Define duplicate
  object-key and parsing policy explicitly at the boundary. Do not carry the
  laboratory's integer-only [`value.gleam`](../../../playground/interface_lab/src/lab/value.gleam)
  into the new production surface.
- Opaque schema-aware `Codec(a)`: fallible native encode/decode, located field/
  index errors, explicit `UnknownSchema`, `new`, `encode`, `decode`, `imap`, and
  schema discovery. A custom callback codec gets no invented schema.
- finite checked combinators: primitives; exact pairs/lists; nullable values;
  `Missing` versus present optional fields; closed objects and empty objects;
  finite string enums from one checked label/value table; binary tagged
  alternatives; inclusive numeric constraints. Preserve native types and reject
  duplicate declarations/keys, unknown keys/tags/labels, malformed locations,
  reversed constraints, and non-roundtripping invalid encodings.
- schema AST and Draft 2020-12 document rendering for the supported finite
  vocabulary, without silently relabeling the old Draft 7 renderer;
- opaque `RuntimeContract` and `ValidatedValue`, normalized exact structural
  matching, checked validation with located reasons, and native decoding only
  through a retained `Codec(a)`;
- strict loading of already-parsed supported schema documents with explicit
  malformed versus unsupported errors. Whole-byte JSON parsing, duplicate-key
  detection, UTF-8/source locations, recursion, and hostile-input limits may be
  honest todos/backlog where the design has not supplied behavior.

The laboratory source is evidence, not a package dependency or file-copy target:

- [`blueprint.gleam`](../../../playground/interface_lab/src/lab/blueprint.gleam)
- [`blueprint_runtime.gleam`](../../../playground/interface_lab/src/lab/blueprint_runtime.gleam)
- [`blueprint_document.gleam`](../../../playground/interface_lab/src/lab/blueprint_document.gleam)
- consumers: [`config_codec.gleam`](../../../playground/interface_lab/src/consumers/config_codec.gleam),
  [`collection_codec.gleam`](../../../playground/interface_lab/src/consumers/collection_codec.gleam),
  [`object_codec.gleam`](../../../playground/interface_lab/src/consumers/object_codec.gleam),
  [`tagged_codec.gleam`](../../../playground/interface_lab/src/consumers/tagged_codec.gleam),
  [`enum_codec.gleam`](../../../playground/interface_lab/src/consumers/enum_codec.gleam),
  [`runtime_schemas.gleam`](../../../playground/interface_lab/src/consumers/runtime_schemas.gleam),
  and [`schema_documents.gleam`](../../../playground/interface_lab/src/consumers/schema_documents.gleam).
- type-boundary negatives:
  [`missing_is_not_null.gleam`](../../../playground/interface_lab/negative/missing_is_not_null.gleam),
  [`union_payload.gleam`](../../../playground/interface_lab/negative/union_payload.gleam),
  [`enum_table_native_type.gleam`](../../../playground/interface_lab/negative/enum_table_native_type.gleam),
  [`runtime_contract_as_codec.gleam`](../../../playground/interface_lab/negative/runtime_contract_as_codec.gleam),
  [`runtime_value_as_native.gleam`](../../../playground/interface_lab/negative/runtime_value_as_native.gleam),
  and [`runtime_enum_is_not_native.gleam`](../../../playground/interface_lab/negative/runtime_enum_is_not_native.gleam).

If preserving the legacy root API and stating the new surface expose an actual
name/type collision, report the exact callers and alternatives. Do not resolve a
material mismatch with an arbitrary API rewrite.

## Oracle corpus and provenance

Create a durable provenance document in the package, for example
`test/oracle/schema-aware-core.md`. For every ported case record:

| New test | source file/case | revision/hash/license | normalization | matched semantic |
| -------- | ---------------- | --------------------- | ------------- | ---------------- |

Required sources and gates:

1. Existing repository tests at baseline commit, MIT license, on Erlang and
   JavaScript. These remain green throughout the scaffold.
2. Published compatibility projects: 1.7.1 checksum
   `6260f1e9a609a5ec3fbe638745744a3bbbd5fcec37b0792ac7ea631efa4d20d7`
   and 1.1.0 checksum
   `879833acfaf7ef9fac1e90ef78e41e5d3cbb0fa718d63105efc597fe520930bf`.
   Preserve the separate dependency locks and outcomes in
   [`playground/blueprint_compatibility`](../../../playground/blueprint_compatibility/README.md).
3. Exact-number oracle: 62 independent cases in
   [`number_check.py`](../../../playground/interface_lab/number_check.py), checked
   with Python `Decimal`/`Fraction` and binary64 bits. Record the oversight
   revision and repository license for every adopted family.
4. Schema agreement: 61 accepted/rejected cases in
   [`schema_check.py`](../../../playground/interface_lab/schema_check.py) against
   pinned `jsonschema` 4.26.0 / Draft 2020-12. Decoder, runtime validator,
   original document, and normalized document must agree for the named cases.
5. Generation corpus is backlog evidence only in this checkpoint. Record its 16
   compiled modules and 4 compiler negatives as retained work; do not claim it
   is part of the initial facade or run it as proof of new production generation.

Run each source baseline before porting from it. Record exact commands and
results. Normalization may change module/test syntax or replace laboratory
`Value.Int` with exact `Number`, but must state the change and preserve the tested
semantic. Never change expected acceptance merely to make the new code pass.
Never claim unrun benchmark, full JSON Schema conformance, full legacy parity,
or parser security.
Alongside the provenance table, keep a source-coverage ledger for each legacy,
number, schema, runtime, document, negative, and generation family: ported,
planned, excluded with reason, or blocked. Similar behavior is not enough to mark
an upstream case covered.

## Focused first red cycle

After baseline, branch, scaffold, and provenance table exist, add one public
behavior test for the exact-number kernel. Recommended first case:

- parse `"1.2300e2"` under explicit limits;
- obtain canonical `"1.23e2"`;
- compare equal to parsing `"123"`;
- confirm exact integer projection yields `123`;
- keep JSON Schema validity out of this test.

The test must fail because the named number behavior is still a todo/missing,
not because the legacy test suite or module graph no longer compiles. Report the
legacy baseline/full suite green and the focused new behavior red separately.
Do not skip, mark expected-failure, comment out, or weaken the assertion.

Create an expected-red catalog for the checkpoint with: focused command, public
behavior, expected failure site/message, observed failure, and removal condition.
Todo warnings belong in a separate scaffold-warning inventory. Legacy or
compatibility baseline failures never enter the expected-red catalog.

Only if the baseline record, scaffold, provenance, and red output have been
captured may this run implement the smallest exact-number vertical to make that
one test green. It must preserve exact decimal semantics and resource checks; it
must not pass by converting through Float or the legacy Dynamic decoder.

## Gates and review evidence

Run target gates separately and report actual coverage:

```sh
cd /code/gleam-dream/json_blueprint
nix develop --command gleam format --check src test
nix develop --command gleam check --target erlang
nix develop --command gleam test --target erlang
nix develop --command gleam check --target javascript
nix develop --command gleam test --target javascript
git diff --check
git status --short --branch

cd /code/gleam-dream/oversight
nix develop --command python3 playground/blueprint_compatibility/scripts/check.py
nix develop --command python3 playground/interface_lab/check.py
```

If the new scaffold is intentionally Erlang-first, existing JS tests still must
pass. Report new modules not yet exercised on JS rather than implying dual-target
support. An intentional focused red command is evidence, not a passing gate;
state expected and actual failure exactly. Do not commit unless the orchestrator
requests it, and never push or publish.

## Later roadmap, not this run

After review, proceed in vertical TDD cycles: exact `Number` + `Value`; byte
parser/resource policy; primitive and collection codecs; object/optional/null;
tagged/enum/constraints; schema rendering and independent corpus; runtime
contracts; strict document loading; compatibility/migration facade and error
paths; recursive/reference policy; hostile-input/fuzz/performance; only then
experimental generation and committed-output tooling. Preserve the full design
roadmap while keeping ordinary JSON users independent of Blueprint.

## Exact cold start for the external agent

```text
Work in /code/gleam-dream/json_blueprint. Read the complete work order at
/code/gleam-dream/oversight/docs/implementation/sinal-blueprint/blueprint-work-order.md.
Use the progressive-implementation, lang-gleam, and tdd skills. Follow the
user-approved staged order in the work order even where generic TDD guidance
would normally start with one behavior before the complete signature scaffold.
Use Gleam LSP before edits and the project compiler as final authority. First
prove the untouched 1.7.1 Erlang+JavaScript and compatibility baselines, then
safely create or inspect branch implementation/schema-aware-core. Complete only
the first checkpoint: compile-green honest schema-aware scaffold alongside the
legacy API, traced oracle corpus, and first focused exact-number red cycle (plus
at most its smallest exact green). Preserve all user and legacy work. Do not
push, publish, access secrets, rewrite the legacy API/wire format, expose private
Dynamic machinery, or continue into broad implementation. Stop and return the
standard result report.
```

Launch mechanism selected by the user, from the JSON Blueprint working directory:
`/opt/homebrew/bin/agy --sandbox --dangerously-skip-permissions --add-dir /code/gleam-dream/oversight --print-timeout 0 --print <literal-prompt>`.
The orchestrator supplies the literal prompt and does not select a model here.

## Standard result report

```text
Checkpoint: baseline / branch / scaffold / oracle corpus / first red [or green]
Repository, baseline HEAD, branch, and final HEAD:
Files changed:
Legacy Erlang and JavaScript baseline commands/results:
Compatibility pin/checksum commands/results:
New public modules and signature-family mapping:
Named todos and why each is honest:
Oracle rows added, source revision/license, and exact normalization:
Compile-green commands/results:
Focused behavior command, expected red reason, actual result:
If green, smallest implementation and evidence it avoids Float/Dynamic shortcuts:
Oversight gates/results:
Legacy API/wire behavior preserved:
JS coverage limitation, if any:
Design mismatches or decisions needed:
Unrelated user changes preserved:
Next smallest TDD slice:
```
