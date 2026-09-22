# API ergonomics implementation progress

This document records the initial implementation checkpoint. The subsequent cleanup and authorized local commits are recorded in [the final delivery](../pre-release-api/progress.md).

## Worktrees

- Isolated sibling worktrees live under `/private/tmp/gleam-dream-api-ergonomics-20260922` on each repository's `codex/api-ergonomics` branch.
- All subagents use GPT-6 Sol with high reasoning, as requested by the user. Three subagents may run concurrently; eight assignments run in dependency order. The tool rejected an eighth agent thread, so a completed implementation agent will be reused for the pilot.
- Original package worktrees remain untouched until acceptance and integration. No commits or remote publication are planned.

## Assignment ledger

| Assignment                 | State      | Agent         | Notes                                                                         |
| -------------------------- | ---------- | ------------- | ----------------------------------------------------------------------------- |
| Blueprint                  | accepted   | blueprint_api | Parent format/check/build and both Erlang/JavaScript suites passed (145 each) |
| Sinal                      | accepted   | sinal_api     | Parent format/check/build, 51 tests, and Nix flake check passed               |
| Relay tools                | in-review  | relay_tools   | Agent 111 tests and gates passed; parent gate follows sequential config slice |
| LLM configured interaction | dispatched | llm_session   | Configured facade and self-contained continuation                             |
| Relay configuration        | dispatched | relay_config  | Sequential writer after tool delivery; URL config and listener description    |
| LLM consistency            | pending    | —             | Waits for LLM configured interaction, Blueprint, and Sinal                    |
| Ecosystem pilot            | pending    | —             | Waits for package changes                                                     |
| Independent review         | pending    | —             | Reviews package changes and pilot                                             |

## Baseline observations

- Relay advanced from review revision `6574f38` to `098417b` before implementation. Its encoded application errors now cross MCP, and this behavior is explicitly preserved.
- The original package working trees were clean at worktree creation.
- Repository Nix tools resolve to Gleam 1.18.1, Erlang/OTP 28.5.0.6, and rebar3 3.27.0.
- Nix required access to its local cache; loading the development shell succeeded after the sandbox escalation.
- Package compilation/test gates and the real pilot are the acceptance checks. This Markdown design repository has no Typst design layer or renderer.

## Acceptance

- All eight assignments passed their applicable executable and source-review checks. Changes are uncommitted; final assembled-workspace verification is recorded below.

## Sinal acceptance

Rubric source: `acceptance_rubric.checks` in `/code/edgar/skills/schema/design-schema.json`.

| Rubric item                  | Verdict and evidence                                                                   |
| ---------------------------- | -------------------------------------------------------------------------------------- |
| Builds what was asked        | Pass: infallible observation and three primitive fields                                |
| Honors design constraints    | Pass: contract Sinal section; native failure and detach behavior preserved             |
| Holds interface contract     | Pass: exact observe and primitive signatures                                           |
| Tests assert behavior        | Pass: native maps, synchronous delivery, detach, panic isolation                       |
| Acceptance criteria coverage | Pass: convenience path and existing attachment regression suite                        |
| Scenario ownership           | Applicable inner loop: contract defines this delta; no formal projected behavior rules |
| No scope creep               | Pass: Sinal source, examples, and tests only                                           |
| No unnamed special branch    | Pass: helpers use existing field and attachment operations                             |
| Design captured              | Pass: contract and linked Sinal design                                                 |
| Standing directives          | Pass: format/check/build/test and Nix checks                                           |
| Quality                      | Pass: immutable descriptors, explicit attachment ownership, compatible aliases         |

## Blueprint acceptance

Rubric source: `acceptance_rubric.checks` in `/code/edgar/skills/schema/design-schema.json`.

| Rubric item                  | Verdict and evidence                                                                         |
| ---------------------------- | -------------------------------------------------------------------------------------------- |
| Builds what was asked        | Pass: schema export and inferred record construction                                         |
| Honors design constraints    | Pass: contract Blueprint section; exact renderer and optional semantics retained             |
| Holds interface contract     | Pass: schema_json, record2, record3 signatures match                                         |
| Tests assert behavior        | Pass: schema document, record round trips, duplicate admission and missing/null distinctions |
| Acceptance criteria coverage | Pass: all new operations plus native-backed and migration cases                              |
| Scenario ownership           | Applicable inner loop: contract defines this delta; no formal projected behavior rules       |
| No scope creep               | Pass: codec, examples, and tests only                                                        |
| No unnamed special branch    | Pass: record helpers compose existing combine/object/imap                                    |
| Design captured              | Pass: contract and linked Blueprint design                                                   |
| Standing directives          | Pass: format/check/build and 145 tests on each target                                        |
| Quality                      | Pass: explicit Results, no parser guarantees changed, README uses canonical codec path       |

## Resolved review findings

- The configured LLM stream initially accepted a separate prepared call during collection. It now retains the originating prepared call; ordinary and structured terminal mapping retain the correct continuation and output codec. Behavior tests passed.
- Relay URL admission initially used parse/render string equality, rejecting valid scheme and port normalization. Component admission now accepts valid normalization and rejects malformed components.
- Relay listener startup initially checked only nonempty bind/TLS strings. Bind-address and TLS-file validation now runs before hub allocation and returns errors for invalid configuration.

## Relay acceptance

Parent gates passed: format/check/build, 115 tests, negative compiler fixture, frozen MCP schema (17 positive and 40 negative messages), checksums, Nix flake check, and pinned HTTP conformance (109 checks passed, zero failed). One conformance scenario emits no checks for this specification version; this is not a claim of complete MCP conformance. Dependencies were copied from the existing installed cache; package manifests and locks are unchanged.

Rubric source: `acceptance_rubric.checks` in `/code/edgar/skills/schema/design-schema.json`.

| Rubric item                  | Verdict and evidence                                                                                      |
| ---------------------------- | --------------------------------------------------------------------------------------------------------- |
| Builds what was asked        | Pass: typed definitions, deliberate errors, metadata and composable configuration                         |
| Honors design constraints    | Pass: contract Relay sections; independent optional hints, encoded errors and transport bounds retained   |
| Holds interface contract     | Pass: definition/handle/call_definition and value-first config                                            |
| Tests assert behavior        | Pass: loopback typed calls/errors, real HTTPS, service discovery, config rejection                        |
| Acceptance criteria coverage | Pass: generic/rendered/encoded errors; omission/false; dispatch preservation; URL and listener validation |
| Scenario ownership           | Applicable inner loop: contract defines this delta; no formal projected behavior rules                    |
| No scope creep               | Pass: bounded Relay API and telemetry convenience migration                                               |
| No unnamed special branch    | Pass: IPv6 parsing addresses URI parser behavior; validation uses native address/file operations          |
| Design captured              | Pass: contract and linked Relay design                                                                    |
| Standing directives          | Pass: repository gates and pinned conformance rerun                                                       |
| Quality                      | Pass after review corrections: malformed URL and listener failures handled before startup allocation      |

## LLM Wire acceptance

Parent format/check/build, 144 tests, Nix flake check, and diff check passed. The independent source review found no remaining concrete issue. Structured admission retains provider restrictions, configured continuations retain settings and codec, and stream outcomes retain retry evidence and refusal usage.

Rubric source: `acceptance_rubric.checks` in `/code/edgar/skills/schema/design-schema.json`.

| Rubric item                  | Verdict and evidence                                                                                  |
| ---------------------------- | ----------------------------------------------------------------------------------------------------- |
| Builds what was asked        | Pass: provider defaults, configured sessions, continuations, schema consistency and consumer guidance |
| Honors design constraints    | Pass: both LLM contract sections; legacy APIs and zero-deadline behavior unchanged                    |
| Holds interface contract     | Pass: prepare/run/prepare_continue and opaque streams; structured codec retained                      |
| Tests assert behavior        | Pass: scripted transports, schema admission, deadlines, native telemetry and exact result IDs         |
| Acceptance criteria coverage | Pass: defaults, invalid records, config retention, typed continuation, provider restrictions          |
| Scenario ownership           | Applicable inner loop: contract defines this delta; no formal projected behavior rules                |
| No scope creep               | Pass: facade wrappers, schema equivalence, telemetry helpers and docs                                 |
| No unnamed special branch    | Pass: provider-specific admission remains explicit; terminal conversion shared                        |
| Design captured              | Pass: contract and linked LLM design                                                                  |
| Standing directives          | Pass: package and Nix gates; representative usage snippets compiled                                   |
| Quality                      | Pass after stream correction: prepared identity and codec cannot be mismatched during collection      |

## Pilot and independent review acceptance

Parent format/check, real local run, and all seven tests passed. The run printed `A-100 has 7 Ada Lovelace notebooks.`. Final independent source/documentation review accepted the composed application.

Rubric source: `acceptance_rubric.checks` in `/code/edgar/skills/schema/design-schema.json`.

| Rubric item                  | Verdict and evidence                                                                   |
| ---------------------------- | -------------------------------------------------------------------------------------- |
| Builds what was asked        | Pass: all four packages composed through new public APIs                               |
| Honors design constraints    | Pass: application owns dispatch/error policy; only external provider scripted          |
| Holds interface contract     | Pass: one definition reused for registry, client, codecs and LLM declaration           |
| Tests assert behavior        | Pass: seven real transport scenarios and explicit cleanup assertions                   |
| Acceptance criteria coverage | Pass: success, invalid input, rendered/generic/legacy errors, cancellation, disconnect |
| Scenario ownership           | Applicable inner loop: ecosystem contract and pilot report describe each scenario      |
| No scope creep               | Pass: pilot code/tests/docs only                                                       |
| No unnamed special branch    | Pass: explicit application error policies and separate native name admission           |
| Design captured              | Pass: ecosystem contract and report                                                    |
| Standing directives          | Pass: Gleam format/check/run/test; no paid or live-provider requests                   |
| Quality                      | Pass: independent review closed annotation/codec reuse points; limitations documented  |

## Final assembled workspace

- All reviewed files were integrated into the original workspace checkouts after verifying unchanged baseline commits and original file contents. No concurrent edits were overwritten.
- All four package suites were rerun from those checkouts: Blueprint 145 tests on Erlang and 145 on JavaScript; Sinal 51; Relay 115; LLM Wire 144. All passed.
- The original Oversight pilot passed check, run, and all seven tests after integration. The run produced the expected inventory sentence.
- Oversight Nix flake check passed. The changed documentation was explicitly formatted, including new untracked contract and progress files.
- Relay also passed the pinned HTTP conformance suite with 109 checks and no failures before byte-identical integration. The no-check scenario limitation remains documented.
- All eight assignments are accepted. Seven distinct GPT-6 Sol high agents were used; the tool refused an eighth agent thread, so the Relay configuration agent also completed the pilot assignment. The independent reviewer remained separate.
- Changes remain uncommitted in all five repositories. No remote push, package publication, live-provider call, or paid request occurred. The isolated worktrees remain available for inspection.
