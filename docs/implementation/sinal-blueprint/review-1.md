# First implementation checkpoint review

## Verdict

- **Re-review verdict: accepted for the scaffold and first tested vertical.** This acceptance does not claim that Sinal's native adapter or Blueprint's todo-marked facade families are implemented.
- The initial review required changes in both repositories. The re-review confirmed that every blocking and secondary finding below was resolved.
- Named scaffold todos and the intentionally red Sinal behavior command are expected at this stop point. The findings below concern public contract integrity, test evidence, scope, and provenance.
- The fixes belong in the implementation repositories. This file records review findings only.

## Re-review evidence

- Sinal now derives event, span-prefix, and field identities from trusted native atoms; rejects empty event names and prefixes; rejects duplicate native event names and field keys; retains fallible field encoding; and rejects non-map terms for empty and nonempty field sets.
- Sinal's focused behavior program now observes the selected event, decoded measurement and metadata, and callback PID. It remains intentionally red at `sinal.attach`, before any native behavior is claimed.
- Sinal now pins telemetry exactly to 1.4.2, removes exception-test exports from the production scope FFI, records direct source/test URLs, and retains a durable expected-red catalog and todo inventory.
- JSON Blueprint removed the throwing JavaScript FFI. Its implemented Erlang number behavior is limited to the tested parse, canonical rendering, comparison, resource-limit, and exact-integer-projection vertical. Unimplemented numeric and JavaScript paths are named todos.
- JSON Blueprint now uses structured codec failure reasons with field/index location wrappers, removes unused laboratory FFI helpers, records the historical red-to-green transition, and states the oversight source's undeclared-license status accurately.
- Independent focused gates passed: Sinal `gleam check`, nine unit tests, formatting, and the expected-red focused command; JSON Blueprint Erlang and JavaScript checks/tests, with 24 Erlang tests and 21 legacy JavaScript tests, plus formatting. `git diff --check` passes in both repositories.

## Sinal

### Initial blocking findings — resolved on re-review

- **Native event identity is forgeable.** `src/sinal.gleam:23-29` and `src/sinal/span.gleam:10-15` accept logical and native names independently. `attach_many` checks only logical names at `src/sinal.gleam:133-159`, so two admitted descriptors can have different labels and the same native atom list. Native dispatch cannot then select the promised descriptor. Retain explicit trusted `Atom` or `List(Atom)` input, derive the logical name from it, and reject empty event names. A registry is not required for this checkpoint. Proposed cure: `(in-place-fix, now)`.
- **Field collision checks use the wrong identity.** `src/sinal/fields.gleam:39-61` accepts independent labels and atom keys, while `pair` checks labels at lines 73-100. Two differently labelled fields using the same atom pass validation, after which `maps:merge` overwrites one encoded value. Derive labels from trusted atoms or retain native keys in `Fields` and reject duplicate native keys. Proposed cure: `(in-place-fix, now)`.
- **The focused test cannot prove its claimed behavior.** `test/focused_behavior.gleam:39-51` ignores the selected event and decoded values and records no observable handler invocation or emitter process identity. The test can pass after the todos are removed even if no callback runs. Make handler execution observable and assert the selected descriptor, decoded measurement and metadata, synchronous completion, and emitter process. Until then, the claims at `test/oracle/telemetry-1.4.2.md:18,29` overstate the ported evidence. Proposed cure: `(in-place-fix, now)`.
- **Fallible field encoding is absent from the public contract.** `fields.field` accepts `fn(a) -> Dynamic`, so no public constructor can produce `FieldEncodeError`. Change the constructor boundary to retain a fallible encoder. Proposed cure: `(in-place-fix, now)`.
- **Empty fields accept a non-map native payload.** `fields.empty` returns `Ok(Nil)` for every `Dynamic`. A foreign non-map measurement or metadata term can therefore reach a typed handler instead of becoming `MalformedMeasurements` or `MalformedMetadata`. Validate that the boundary value is a native map even for an empty field set. Proposed cure: `(in-place-fix, now)`.

### Initial secondary findings — resolved on re-review

- `gleam.toml:13` permits any telemetry release from 1.4.2 through 1.x. The manifest currently resolves 1.4.2, but the oracle boundary must remain exact. Pin the dependency constraint to 1.4.2. Proposed cure: `(in-place-fix, now)`.
- `src/sinal_scope_ffi.erl:3-12,61-77` exports unused exception-test helpers (`capture`, `raise_error`, `raise_exit`, `raise_throw`, and `raise_cleanup`). Remove them from production source unless an implemented public path requires them. Proposed cure: `(in-place-fix, now)`.
- The repository contains no durable expected-red catalog. Record the focused command, public behavior, expected site and message, observed failure, and removal condition. Keep it separate from the todo-warning inventory. Proposed cure: `(in-place-fix, now)`.
- `test/oracle/telemetry-1.4.2.md:5-12` records the repository but omits the requested direct upstream source and test URLs. Add them. Proposed cure: `(in-place-fix, now)`.

### Accepted direction

- Explicit trusted native atoms are the safe minimal boundary. The current production code does not allocate atoms from runtime strings, and no Blueprint dependency exists. The required correction is to prevent logical/native divergence and invalid empty identities, not to introduce a global atom registry.

## JSON Blueprint

### Initial blocking findings — resolved on re-review

- **JavaScript support is fake-green.** Every function in `src/json_number_ffi.mjs:5-35` throws, but the public Number functions compile on JavaScript with `Result` return types. A JavaScript caller therefore receives an untyped exception outside the declared contract. Isolate the new Number module to Erlang for this checkpoint or implement the JavaScript boundary; do not use throwing stubs to satisfy target compilation. Proposed cure: `(in-place-fix, now)`.
- **The first green exceeds the authorized vertical.** `src/json/blueprint/number.gleam` is effectively the complete 740-line laboratory kernel renamed from `JsonNumber` to `Number`, including float construction and projection. The package test covers only parsing, canonical text, equality, and exact integer projection. Retain only the implementation needed by that tested vertical and return the other executable paths to named todos, or supply package-level evidence for the complete 62-case contract before retaining the full kernel. Proposed cure: `(in-place-fix, now)`.
- **Codec failures are stringly typed.** `src/json/blueprint/codec.gleam:4-14` reduces root reasons to `CannotEncode(String)` and `CannotDecode(String)`. The frozen design requires structured reasons so callers do not parse prose. Represent unknown labels, tags, and properties, wrong tuple lengths, invalid native values, and bounds failures as typed reasons while retaining field and index locations. Proposed cure: `(in-place-fix, now)`.

### Initial secondary findings — resolved on re-review

- `src/json_number_ffi.erl:11-14,70-104` includes unused laboratory helpers for float fixtures, bit formatting, string joining, and output. Remove them from the production FFI. Proposed cure: `(in-place-fix, now)`.
- The durable oracle document does not retain the historical expected-red command, expected failure, observed failure, and removal condition after the green transition. Add the required catalog. Proposed cure: `(in-place-fix, now)`.
- `test/oracle/schema-aware-core.md:15` calls the exact-number source license `internal`. The frozen oversight commit has no declared `LICENSE`; state that fact or identify the actual governing license. Proposed cure: `(in-place-fix, now)`.

### Confirmed boundaries

- The branch is based on `0e379c6491d34aca49795f716e87b9003df0130e`, and the legacy implementation files remain unchanged.
- The new `Value` has one exact `Number` case and no parallel integer or float case.
- No source-generation API was promoted into the initial facade.

## Evidence reviewed

- The Sinal upstream checkout is at telemetry commit `7baf8085e406d5ae9e43b284d7c866742ae04b28`. Its retained Common Test log reports 42 cases in two suites.
- `git diff --check`, repository status, Blueprint branch ancestry, source diffs, and the external checkpoint reports were inspected directly.
- The first review process could not independently rerun Nix-based gates because its sandbox could not access the Nix daemon and no global Gleam binary was present. The external reports record successful compiler, target, compatibility, flake, and oversight gates. Re-review should rerun focused gates after the corrections above.
