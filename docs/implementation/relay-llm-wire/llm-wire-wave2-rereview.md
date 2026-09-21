# LLM Wire Wave 2 correction re-review

- **Baseline:** `e5b7b0b` plus the complete staged, unstaged, and untracked tree in `/code/gleam-dream/llm_wire`.
- **Scope:** the seven blockers recorded in `llm-wire-wave2-review.md`. This review does not treat the blocker subset as full Wave 2 completion.

## Verdict

- **Changes required for the seven-blocker correction subset.** Six repairs have the intended behavior, but the transport and raw-client modules remain importable by external packages. An external caller can therefore bypass `api.prepare` and send an arbitrary request body through the supported Gun path.
- The original schema defect is behaviorally repaired for the field/object contract that caused it. The broader report claim of exact Blueprint projection is false for nullable schemas because the `anyOf` branches are reversed.
- **Full Wave 2 remains incomplete independently of these findings.** Google, connection pooling/reuse, the strict pre-allocation response-header cap, the broad lifecycle race matrix, representative fragmentation coverage, duplicate JSON-member coverage, and complete selected-oracle inventory remain open in `WAVE-2-REPORT.md`.

## Adherence

- **P0 · bypass · raw provider transport remains externally callable.** `src/llm_wire/internal/client.gleam:8-176` and `src/llm_wire/internal/transport.gleam:65-120` export public functions. `gleam.toml:1-19` declares no `internal_modules` boundary. With Gleam 1.18.1, a separate path-dependent package imported `llm_wire/internal/client` and referenced `client.open_openai_stream`; `gleam check --target erlang` compiled successfully. The lower-level client validates HTTPS, routes, and headers at `internal/client.gleam:237-292`, but it accepts caller-provided `tools` and `body`, so it bypasses the Blueprint and capability admission required by `llm-design.md:24-27` and the work order at `llm-wire-wave2-work-order.md:52-68`. Make these modules package-internal through the package configuration or remove their public entry points. **Proposed `(design-change, now)`; strong.**
- **P2 · divergent claim · nullable schema projection is equivalent but not exact.** `src/llm_wire/schema.gleam:45-60` emits `[inner, null]`; Blueprint `codec.schema_value` emits `[null, inner]`. A temporary adversarial test comparing the parsed projection of `NullableSchema(IntSchema)` with `codec.schema_value` failed with those exact values. JSON Schema behavior is unchanged because `anyOf` order has no validation meaning, but `WAVE-2-REPORT.md:67-68,103` claims exact structural projection and `test/llm_wire_api_test.gleam:35-76` covers only one field schema plus numeric serialization. Use Blueprint ordering or narrow the claim and add a representative recursive projection table. **Proposed `(in-place-fix, now)`; strong.**
- The other adherence checks are clean within the named blocker boundaries. `StreamProgress` has no executable tool-call variant (`types.gleam:419-435`); both reducers retain closed calls until terminal assembly (`openai.gleam:787-827,925-957`; `anthropic.gleam:636-728,813-884`). `Continuation` and `PreparedCall` are opaque and share an origin reference checked before result validation (`api.gleam:24-51,357-417,510-553`).
- Provider refusal, provider cancellation, unknown Anthropic stops, and hosted effects have distinct terminal behavior (`openai.gleam:892-1003`; `anthropic.gleam:796-895`). Timeout cancellation uses a per-read reference and owner acknowledgement, so delivery or cancellation wins observably (`owner.gleam:27-46,226-259,305-327,359-441`).

## Spec

- The correction subset does not satisfy the work-order rule that preparation performs local schema and capability admission before transport (`llm-wire-wave2-work-order.md:52-68`), because the importable raw client reaches transport without `api.prepare`. The in-package regression at `test/llm_wire_integration_test.gleam:1-67` proves remote plaintext rejection, but it does not prove an external package cannot call the seam.
- Terminal-only tool batches, origin-bound continuation, provider terminal classification, timeout arbitration, and the root facade satisfy the reproduced blocker cases. The root facade also compiled and passed from a separate path-dependent package importing only `llm_wire`; the in-repository consumer is at `test/llm_wire_root_facade_test.gleam:1-18`.
- This is subset acceptance only. The explicit Wave 2 requirements retained as unfinished in the report continue to prevent full Wave 2 acceptance even after the P0 correction.

## Standards

- No additional repository-rule violation was found. The source and tests satisfy the documented formatting and compilation rules. The review performed no source repair or commit.

## Craft

- The main regression has a package-boundary test smell: a test inside `llm_wire` can always import project modules, so moving files under a directory named `internal` does not demonstrate external inaccessibility. The corrective test must compile an actual dependent package and expect the import to fail.
- The schema regression is too narrow for its universal claim. It compares one transmitted `FieldSchema`, then separately checks one decimal range; it does not table-test every admitted recursive schema constructor against Blueprint's canonical value.
- No further blocker-level craft defect was found in the other five corrected paths. Their negative cases exercise the failure boundary rather than only the successful output.

## Independent checks

- `nix develop --command gleam format --check src test`: passed.
- `nix develop --command gleam check --target erlang`: passed.
- `nix develop --command gleam test --target erlang`: passed, 90 tests.
- `nix flake check`: passed the single `aarch64-darwin` formatting check; Linux and `x86_64-darwin` were omitted by Nix.
- `git diff --check`: passed.
- External root-facade probe: passed, one test.
- External `llm_wire/internal/client` import probe: unexpectedly compiled; this reproduces the P0 bypass.
- Nullable exact-projection probe: failed as expected, showing `[integer, null]` versus Blueprint `[null, integer]`.

## Routing

- `(design-change, now)`: enforce an actual package boundary around the raw client and transport, then retain the HTTPS/header validation as defense in depth.
- `(in-place-fix, now)`: align nullable projection order with Blueprint or narrow the exactness claim and test the admitted constructor surface.
- Frontdesk routing was not run because this task requested a bounded judge-only re-review.
