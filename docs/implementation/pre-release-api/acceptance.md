# Cleanup acceptance evidence

The governing rubric is `acceptance_rubric.checks` in `/code/edgar/skills/schema/design-schema.json`. Rows below follow its order. Package verdicts require independent source review and executable checks; a writer's reported result alone does not establish acceptance.

| Rubric item | Blueprint | Sinal | Relay | LLM Wire | Composition |
| ----------- | --------- | ----- | ----- | -------- | ----------- |
| 1           | Pass      | Pass  | Pass  | Pass     | Pass        |
| 2           | Pass      | Pass  | Pass  | Pass     | Pass        |
| 3           | Pass      | Pass  | Pass  | Pass     | Pass        |
| 4           | Pass      | Pass  | Pass  | Pass     | Pass        |
| 5           | Pass      | Pass  | Pass  | Pass     | Pass        |
| 6           | Pass      | Pass  | Pass  | Pass     | Pass        |
| 7           | Pass      | Pass  | Pass  | Pass     | Pass        |
| 8           | Pass      | Pass  | Pass  | Pass     | Pass        |
| 9           | Pass      | Pass  | Pass  | Pass     | Pass        |
| 10          | Pass      | Pass  | Pass  | Pass     | Pass        |
| 11          | Pass      | Pass  | Pass  | Pass     | Pass        |

## Blueprint

The [contract](contract.md#blueprint) preserves recursive decoding and the actual legacy schema representation. The source diff leaves that engine intact. It removes the text-reparsing migration adapter. Five existing `Value` constructor aliases remain supported because preserving them is cheap and avoids unnecessary released-package source breaks. The package migration guide maps every removal and distinguishes closed modern objects, missing versus null, and the different union envelopes. A compiled example checks both the released decoder's permissive object behavior and the modern codec's rejection of extra fields.

The [declaration audit](json_blueprint-surface.json) classifies all 297 baseline declarations. Independently rerun format, type check, build, and diff checks pass. The Erlang and JavaScript suites each pass 144 tests, including recursive examples, exact-number behavior, parser/runtime contracts, and generated codec behavior. Adapter-specific expectations are replaced with migration behavior checks while retaining the underlying decoder coverage. The assembled workspace rerun includes the restored lightweight aliases and passes 144 tests on each target. No package version or dependency version changed.

## Sinal

The [contract](contract.md#sinal) preserves native telemetry encoding, synchronous observation, handler failure isolation, and scoped cleanup. The source diff replaces the `Handler` wrapper with the same typed callback at each attachment boundary. It keeps the callback's selected event and failure observer on advanced attachment paths. Pure aliases and the version stub are removed; duplicate-name validation remains at attachment admission.

The [declaration audit](sinal-surface.json) classifies all 91 baseline declarations. Independently rerun format, type check, build, 50 behavioral tests, Nix formatting, and diff checks pass. Duplicate native event names are now tested through `attach_many`, instead of an exported validator. Native malformed-value and callback-exception tests still prove handler removal and telemetry failure emission. The one-test reduction removes the deleted version stub's assertion.

## LLM Wire

The [contract](contract.md#llm-wire) gives application code the `config`, `session`, `types`, `pool`, and `telemetry` modules. The forwarding root and redundant constructors are deleted. Provider adapters, wire preparation, raw stream ownership, parsing, and transport live under the implementation namespace. Internal-module metadata is a supported-surface/documentation distinction, not an import prohibition; opaque prepared values still reject fabrication.

The public request record contains caller-owned choices. Provider replay travels through the retained continuation instead of a request field. The single full tool-call record keeps provider metadata, while `types.tool_call` supplies the absent metadata defaults for application-authored history. Custom CA configuration keeps certificate and hostname verification and the existing endpoint policy. Limit and deadline records use defaults and named updates, with validation before execution.

Root source review checked replay origin and result coverage, error type migration, TLS policy, and the shared deadline classifier. The four classified timeout strings originate in the transport's explicit overall-deadline branches; other failures remain transport errors. Tests cover the actual configured HTTPS path and continued-call deadline outcome. The [audit](llm_wire-surface.json) covers all 307 baseline declarations and seven additions, including implementation helpers. Independently rerun format, type check, build, 147 tests, external positive/negative compiler probes, Nix formatting, and diff checks pass. Dependency versions are unchanged.

## Relay

The [contract](contract.md#relay) separates admitted structured and content-only tool definitions. Source review verified that ordinary callbacks accept only input, advanced callbacks retain per-invocation context, and content-only calls require no output codec. The explicit renderer runs before the application error type is erased. The old encoded-error branch, forwarding root, constructor families, placeholder test kit, and duplicate client listing/cancellation entry points are gone. Custom server dispatch and raw protocol calls remain distinct advanced capabilities.

Metadata uses default values and named updates. Tests verify simultaneous read-only/open-world hints, explicit false, and omitted hints on the wire. HTTP URL admission derives connection fields, and HTTP listener configuration keeps policy separate from bind changes. Stdio configuration supplies bounded defaults. The protected registry contains an actual tool registry instead of an optional implementation field. Revision-specific encoding, schema helpers, transport process state, and subscription bookkeeping live under the explicit internal module pattern.

The [audit](relay-surface.json) covers every one of the 474 baseline declarations and records additions and moved declarations separately. Root and a separate read-only reviewer found no blocking capability loss. Independently rerun format, type check, build, 119 tests, the intended codec/handler negative compiler fixture, frozen-schema positives/negatives, checksum pins, local HTTP conformance, Nix formatting, and diff checks pass. The schema checker required the repository's Nix Python environment (`nix develop --command python3 scripts/relay_schema_check.py`); the initial ambient Python attempt lacked `jsonschema` and made no source change.

Conformance reports 109 passing checks and zero failures across 40 scenarios. The upstream missing-input-response scenario still performs zero checks, so that scenario alone is not evidence of behavioral coverage. The package's input-round and validation tests remain in place.

## Composition and integration

The original repositories now contain the reviewed source. Integration compared each destination with its saved baseline before writing and checked all 129 resulting changed paths against the reviewed content. All package and dependency versions remain unchanged. The pilot alone adds an already locked transitive dependency, glisten, as a direct dependency so its scripted provider uses public transport APIs instead of LLM Wire internals.

Root reran format, check, build, tests, and diff checks in dependency order in the assembled workspace. Blueprint passes 144 tests on Erlang and 144 on JavaScript; Sinal passes 50; Relay passes 119; LLM Wire passes 147; the pilot passes all seven scenarios and its executable example prints `A-100 has 7 Ada Lovelace notebooks.` The full extended gates had already passed independently on the byte-matched reviewed worktrees. Final verification used the integrated source; subsequent edits only finalized the review evidence.

The [pilot](../../../playground/ecosystem_pilot/README.md) covers success, invalid arguments, rendered errors, generic errors, deliberate JSON-text errors, cancellation, and disconnects. Its single Relay definition supplies registration, typed client calls, and the application-owned LLM tool declaration. The real local transports and Sinal observations remain in the tests. The removed facades and wrappers have no remaining imports in active source, tests, fixtures, or the pilot. Historical prototype/oracle packages retain their independent version contracts.

The review found no blocking issue. The user authorized local commits after review; Blueprint's manifest stays at 1.7.1 and its migration guide prepares the intended 2.0 source transition without publishing a release.

Local package commits are recorded in [progress.md](progress.md#committed-delivery). Commit hooks passed without changing package source. Relay’s exact sibling pins were refreshed to those commits, and its checksum/pin verification passed again. No additional application behavior changed during commit preparation.
