# Public API ergonomics contract

This document records the initial implementation checkpoint. The subsequent cleanup and authorized local commits are recorded in [the final delivery](../pre-release-api/progress.md).

The compatibility requirements in this first-pass contract are superseded by the [pre-release cleanup contract](../pre-release-api/contract.md), including its separate Blueprint 2.0 migration policy.

## Authorization and scope

- The user accepted the cross-package API review for implementation on 2026-09-22 and delegated assignment boundaries and sequencing to the orchestrator.
- This is an additive public API design change across Blueprint, Sinal, Relay, LLM Wire, and the ecosystem pilot. Existing callable entry points and useful protocol capabilities remain supported.
- The implementation starts from Blueprint `d3f0708`, Sinal `dd09933`, Relay `098417b`, LLM Wire `cdfb38a`, and Oversight `8db2b00`. Relay's current baseline exposes encoded application errors through MCP; this behavior must remain intact.
- No package publication, remote pushes, dependency upgrades, real provider calls, or unrelated architecture changes are authorized by this work order.

## Common rules

- A constructor supplies defaults for optional settings. A modifier accepts the existing configured value first and preserves all unrelated settings. A preparation or startup boundary validates the whole configuration before side effects.
- Absence remains distinct from an explicit negative value. Configuration must not weaken protocol validation, exact-number semantics, authorization, resource bounds, cleanup, or continuation identity.
- Compatibility entry points remain documented as such. New examples use one canonical application path; additive alternatives must have a distinct capability or compatibility purpose.
- Native business types and handlers remain application-owned. Blueprint owns schema-bearing codecs, Relay owns MCP, LLM Wire owns provider interaction, and Sinal owns native typed telemetry. The host owns tool execution and continuation policy.
- No unvalidated cross-package cast, reflection-based codec derivation, implicit retry, global mutable configuration, or new shared framework is introduced.

## Blueprint

- `codec.Codec(a)` is the ordinary application definition. Existing legacy decoders, raw schema values, runtime contracts, and generated-code definitions remain explicit advanced or compatibility paths.
- Add `codec.schema_json(Codec(a)) -> Result(String, SchemaError)` to export the complete Draft 2020-12 schema document through the existing exact JSON renderer. Schema-less codecs continue to fail explicitly.
- The compiled usage probe selected `codec.record2` and `codec.record3`. Each accepts two or three `Properties` values, the native constructor, and one native accessor per property, and returns `Result(Codec(record), PropertyError)`. Constructor and accessor types infer without annotations in the probe.
- Record helpers preserve field order, required/optional distinction, missing/null distinction, closed-object validation, and bidirectional mappings. They do not claim parity between native-backed and runtime JSON parser behavior.
- This scope does not add general JSON Schema vocabularies or change legacy migration semantics.

## Sinal

- Add `sinal.observe(HandlerId, Event(m, d), fn(m, d) -> Nil) -> Result(Attachment, AttachError)` for ordinary infallible observers. It uses the existing native failure-isolation path, including malformed-map removal and native failure reporting.
- Preserve `attach`, `attach_many`, custom failure callbacks, scoped cleanup, and explicit detach ownership. Convenience observers do not introduce asynchronous execution or stronger cleanup guarantees.
- Add primitive `Fields` constructors for trusted atom keys, including `fields.string(Atom) -> Fields(String)`, `fields.int(Atom) -> Fields(Int)`, and `fields.bool(Atom) -> Fields(Bool)`. Retain the fallible custom field constructor.
- Document one canonical spelling for equivalent existing constructor pairs without removing aliases. Existing event metadata wire encodings remain compatible.

## Relay tools

- Preserve the existing three-codec constructors and their encoded local and MCP application errors. Add a clearly documented two-codec path whose generic handler error uses a stable generic public message unless the author explicitly supplies an error renderer.
- Add an admitted opaque `tool.Definition(input, output)` that retains name, metadata, and input/output codecs. Pin the seam as `tool.definition(ToolName, Codec(input), Codec(output)) -> Result(Definition(input, output), ToolAdmissionError)`; `tool.handle(Definition(input, output), fn(context, input) -> Result(output, error)) -> ContextTool(context)`; and `client.call_definition(Client, Definition(input, output), input) -> ToolCallOutcome(output)`.
- Definitions expose their name, metadata, and input codec through typed accessors for an application-owned LLM declaration adapter. Binding a handler erases native types only when producing the heterogeneous contextual tool.
- Metadata modifiers preserve unrelated settings. Definition modifiers include description, title, annotations, and required client capabilities. They remain independently composable.
- Explicit public error rendering is bound before generic error erasure. A content-only handler must not require an unused structured-output codec. Existing progress, client-input, raw-schema override, and rich-content constructors remain supported.
- Tool annotations retain independent `Option(Bool)` fields. Read-only and open-world may coexist. Setters change one hint only; `None` remains omitted and `Some(False)` remains explicit false. Existing record construction remains valid.
- Definition adoption must not claim to recover native Gleam types from remote JSON Schema or equate Relay and provider tool-name admission.

## Relay configuration

- Add value-first service modifiers to the existing server description without discarding registry state, other services, or custom dispatch. Preserve existing constructors.
- Add URL-based client configuration that derives host, port, path, and TLS selection; keeps bounded defaults; validates malformed URLs and unsupported components; and permits explicit timeout, size, and CA settings. Existing client configuration remains available.
- Add one composable HTTP listener description carrying listener options, policy, context, and optional TLS settings. Local defaults remain visibly local. A modifier does not imply authorization, authentication, or expanded host/origin permissions.
- Startup validates the configuration before allocating resources. Existing HTTP/HTTPS startup functions remain compatibility entry points.
- List setters replace the relevant list; they do not silently append. Repeated scalar setters use the last supplied value. Preserve custom dispatch and every unrelated field.

## LLM configured interaction

- Add one additive ordinary facade under `llm_wire/session`, backed by `llm_wire/config`. Existing root, API, runtime, types, and low-level provider operations remain available for compatibility and advanced use.
- `config.openai(ApiKey)`, `config.anthropic(ApiKey)`, and `config.google(ApiKey)` supply provider endpoints and bounded execution defaults. Value-first modifiers preserve other settings. Provider-specific settings reject incompatible providers rather than silently ignoring them.
- The session seam is `session.prepare(config.Config, types.Request) -> Result(session.PreparedCall, types.WireError)`, `session.run(session.PreparedCall) -> Result(session.RunResult, types.WireError)`, and `session.prepare_continue(session.Continuation, List(types.ToolResult)) -> Result(session.PreparedCall, types.WireError)`.
- A configured prepared call retains admitted settings. A configured continuation retains the originating prepared call and provider-owned replay state, exact outstanding-call identity, and original result ordering. It does not require the caller to resupply the originating prepared call or limits.
- Configured streaming and structured output preserve the same settings and public business types. Typed structured continuation retains its output codec. Pool ownership remains explicit; no implicit live resource is created by a pure config constructor.
- The ordinary facade uses `types.Message`, `types.ToolCall`, and `types.ToolResult` consistently, avoiding conversions through the reduced root ToolCall. Canonical session outcomes may wrap its own continuation but retain the same tool-call type as streaming.
- Nonpositive limits and deadlines fail validation before side effects on the new configured path. Existing legacy zero-deadline behavior must not be silently changed. Timeout values are execution durations, not stale absolute times retained across continuation.
- Provider option checks, exact correlation, refusal, output limits, cancellation, and no hidden retries remain unchanged.

## LLM schema and public surface consistency

- Structured-output schema admission normalizes Blueprint schema equivalence before checking root and provider constraints. A closed required single-field `FieldSchema` is admitted wherever the equivalent `ObjectSchema` is admitted.
- Unsupported provider vocabulary still fails locally. Optional fields are not silently converted to nullable required fields. Google-specific restrictions remain distinct.
- New consumer documentation uses the configured facade and one canonical set of business types. Existing reduced root types remain compatibility values rather than a recommended history-reconstruction path.
- Migrate package telemetry primitive fields to Sinal's new helpers once accepted. Keep native wire metadata compatible. Add typed metadata helpers only where they do not require changing the existing event payload contract.

## Ecosystem acceptance

- Update the real ecosystem pilot to use the new ordinary surfaces and one admitted Relay definition per business tool. Its LLM declaration adapter derives the name, description, and input codec from that definition without a mandatory package-to-package dependency.
- Keep the success, invalid-arguments, application-error, cancellation, and provider-disconnect scenarios through real local transports. Preserve explicit tests of the legacy encoded application-error path alongside the new generic and rendered failure choices.
- Exercise schema export, record codec construction, configuration composition, typed call reuse, self-contained continuation, and Sinal observation through public APIs.
- The scripted provider remains the only substituted external service. Do not mock owned package internals, use live credentials, or perform paid provider calls.

## Assignments and dependencies

| Assignment | Owner scope                                            | Blocked by            | Shared surface rule                                          |
| ---------- | ------------------------------------------------------ | --------------------- | ------------------------------------------------------------ |
| 1          | Blueprint schema export and record usage probe         | None                  | Blueprint-only writer                                        |
| 2          | Sinal observers and primitive fields                   | None                  | Sinal-only writer                                            |
| 3          | Relay tool definitions, error paths, and metadata      | None                  | Relay tool/client writer; finish before assignment 5         |
| 4          | LLM configuration and session continuation             | None                  | LLM session/API writer; finish before assignment 6           |
| 5          | Relay server/client/listener configuration             | 3                     | Same Relay worktree, sequential writer                       |
| 6          | LLM schema equivalence and canonical consumer guidance | 1, 2, 4               | Same LLM worktree, sequential writer                         |
| 7          | Ecosystem pilot and usage documentation                | 1–6                   | Oversight pilot writer; package corrections return to owners |
| 8          | Independent cross-package review                       | 1–6; pilot when ready | Read-only; fixes return to owners                            |

## Verification

- Run `gleam format --check src test`, `gleam check`, `gleam build`, and `gleam test` from each package using the repository Nix development environment. Blueprint additionally runs `gleam test --target javascript` for changed codec behavior.
- Relay, Sinal, LLM Wire, and Oversight have `nix flake check` formatting checks. Blueprint has no separate flake check or lint channel; record that absence rather than inventing tooling.
- Run `gleam check`, `gleam run`, and `gleam test` from the updated pilot. Rerun the package suites and pilot on the final assembled tree.
- Review public behavior, compatibility, exact schemas, configuration preservation, failure isolation, continuation identity, resource cleanup, and the documented limitations before acceptance.
- This repository's design sources are Markdown. It has no `docs/design` Typst layer or design-layer renderer; this change follows the existing Markdown design and formatting workflow.

## Acceptance evidence

The eight assignments and their executable and independent-review evidence are recorded in [progress.md](progress.md). Package changes and the pilot remain uncommitted for user review; no release or remote publication has occurred.
