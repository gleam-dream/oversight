# Pre-release public API cleanup

## Authorization

The user authorized a breaking cleanup after the first API ergonomics pass. Every public function and type must justify its place in the intended release by a caller capability. Compatibility alone does not justify an API in Sinal, Relay, or LLM Wire.

Blueprint is released. Its next major target is 2.0. Preserve existing usage where doing so is simple and robust; remove APIs whose preservation would retain substantial duplication, fragility, or conceptual overhead. Document every Blueprint breaking change and its migration. This work prepares the API and migration; it does not publish a release.

This contract supersedes compatibility requirements in the preceding API ergonomics contract and the older package design facades. The underlying protocol and correctness requirements remain in force.

## Review and implementation rules

- Inventory every current public function, constant, and type, including aliases and implementation-facing exports. Record whether each remains public for a named capability, becomes internal, is replaced, or is removed. A low symbol count alone is not an acceptance criterion.
- Give each concept one canonical public owner. Delete superseded wrappers and nominal duplicate types. Move implementation-only exports behind an actual internal module boundary where feasible; annotation-only hiding must not preserve an alternative public workflow. Gleam internal-module metadata identifies unsupported implementation modules and hides documentation; it does not prohibit imports. Opaque types still enforce construction boundaries, which are checked by negative compiler fixtures.
- Use immutable value-first configuration modifiers and validate whole configurations at preparation or startup. Derive values from existing descriptions instead of requesting them again.
- Preserve useful advanced capabilities: exact JSON values and schemas, codec generation and runtime validation, native telemetry isolation and scoped cleanup, MCP transports and rich content/progress/client-input flows, bounded provider streaming, structured output, pools, cancellation, refusal, retry evidence, and exact continuation identity.
- Keep annotations independent and optional. Omitted differs from false; read-only and open-world may coexist.
- Keep one safe generic tool-error path and an explicit rendering capability. An encoded error codec is not independently justified merely because the old constructor had one: applications may deliberately render JSON text. Remove dedicated encoded-error machinery if the renderer subsumes its useful semantics without losing required error information.
- Preserve resource cleanup, admission failures, bounds, no hidden retries, and protocol requirements. Do not broaden provider profiles or weaken gates to make removals pass.
- Update all workspace consumers, tests, fixtures, examples, generator templates, and executable scripts that use changed APIs. Preserve behavioral coverage; delete tests only when their sole subject is a deliberately removed redundant surface.
- No package publication, remote push, dependency upgrade, paid provider call, or unrelated architecture redesign.

## Package boundaries

### Blueprint

Use schema-bearing codecs as the ordinary path, with runtime schema contracts and generated codecs retained for their distinct capabilities. Retain the released root Decoder, dynamic decoding, and schema AST as the advanced recursive and legacy-schema path. Its renderer labels the schema Draft-07 but also emits `$defs`; retention does not establish broader standards conformance. Modern finite codec schemas do not subsume recursive references or the full Draft-07 constraint vocabulary; deleting this engine would lose useful capability. Remove the migration adapter because it reparses serialized values, collapses error details, and cannot supply a schema. Retain the five existing primitive `Value` constructor aliases because they are simple, robust compatibility for released consumers; ordinary examples use the data constructors. Keep lightweight compatibility only where its benefit outweighs public ambiguity, and label its intended scope. A 2.0 migration guide must provide old-to-new mappings and compiling representative examples. Do not change exact-number or missing/null semantics.

### Sinal

The opaque Handler wrapper is removed. Fallible single-event, multi-event, and scoped attachment accept the typed callback directly; the selected event remains available where needed. The infallible observer callback remains `fn(measurements, metadata) -> Nil`. Pure constructor aliases, the version stub, and the public event-name validator are removed.

Retain one event constructor and one custom native-field constructor, alongside primitive convenience fields. Ordinary observation and fallible multi-event/scoped handling are distinct capabilities. Remove pure aliases, implementation-only validation exports, and nominal layers that provide no caller capability. Preserve native event and field wire encodings.

### Relay

Structured `Definition(input, output)` and input-only `ContentDefinition(input)` retain distinct contracts, so a content-only caller supplies no unused output codec and a structured caller has a definite output codec. Advanced binding uses a named invocation context and typed handler result to compose progress, rich content, and client input. Ordinary binding accepts an input-only callback; application values may be captured in that callback. Advanced binding retains per-invocation application context, and content-only advanced binding retains that capability without an output codec. Generic-safe binding has an explicit error-rendering alternative. A definition modifier applies an explicit input-schema document without replacing codec validation. The root forwarding facade is removed. Generic JSON-RPC and revision data remain public; revision-specific server encoders and actor-message plumbing become internal unless a concrete external capability requires them.

Use one admitted tool definition for schemas and typed calls, with handler binding for ordinary and advanced behavior. Consolidate old three-codec constructor families into that design; rich content, progress, client input, and explicit schema overrides must remain expressible. Remove duplicate root forwarding exports and superseded server/client/listener startup families. A stdio client configuration takes the executable and arguments and supplies bounded timeout/response defaults; named record updates retain advanced control. Keep raw protocol access only where it exposes distinct control. Preserve all implemented MCP behavior and frozen-schema conformance.

### LLM Wire

The root forwarding facade is removed. Provider adapters, raw transport/stream ownership, schema lowering, and the alternate API/runtime workflows move to internal modules. Custom CA support moves to `config.with_ca_cert_file`, preserving TLS verification. Request remains a caller-owned record containing model, messages, and request options; provider continuation state moves into the internal prepared/continuation path. One complete ToolCall type retains provider replay metadata; a default constructor accepts only call ID, name, and arguments. The stream collection operations remain public because they support switching from incremental reading to collection.

Use config/session and one set of business types for ordinary buffered, streaming, structured, and continued calls. Remove the duplicate root facade and reduced nominal types. Internalize runtime/provider/parser machinery where it exists only to implement the public client. Low-level control remains public only when a concrete use cannot be expressed by the configured facade. Keep explicit pool ownership and telemetry. Remove placeholder-heavy constructors when default configuration plus record updates or modifiers subsume them.

### Composition

The pilot must compile and run through the cleaned surface. One Relay definition continues to drive registration, client calls, codecs, and the application-owned LLM declaration adapter. Preserve success, invalid input, rendered and generic errors, cancellation, and disconnect scenarios. If dedicated encoded-error APIs are removed, demonstrate intentional JSON-text errors through the renderer rather than keeping a legacy-only scenario.

## Work and verification

Reuse the existing isolated sibling worktrees after checking they match the previously accepted workspace contents. Package writers first report their inventory and exact retained seams, then implement within these rules. Shared package/consumer edits are serialized or explicitly assigned.

Use GPT-6 Sol with high reasoning, as previously requested. Assign Relay, LLM Wire, and Blueprint/Sinal to separate writers within the available agent limit. Review and integrate the composed pilot after the package surfaces stabilize. The orchestrator independently reviews changes and reruns gates.

Each package runs `gleam format --check src test`, `gleam check`, `gleam build`, and `gleam test`. Blueprint also runs `gleam test --target javascript`. Use existing Nix formatting checks for Sinal, Relay, LLM Wire, and Oversight. Relay additionally runs its negative compiler fixtures, frozen-schema checks, checksum verification, and pinned local HTTP conformance suite. The pilot runs check, run, and test. Genuine historical version pins must be distinguished from current dependency versions if Blueprint's version changes.

Every removal must appear in the public-surface inventory with its replacement or reason. Final acceptance requires source review, preserved capability coverage, and passing checks on the assembled workspace. Changes were reviewed before the user authorized local commits. Package publication and remote pushes remain outside this delivery.
