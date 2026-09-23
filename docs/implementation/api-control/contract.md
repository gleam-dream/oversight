# Composable APIs and explicit control

## Authorization and scope

The user authorized implementation of the cross-package API, extensibility, and fragility reviews on 22 September 2026. Seven assignments are delivered by GPT-6 Sol workers with high reasoning. The agent service limits worker creation, so the dependent LLM assignments reuse one worker sequentially. The user delegated assignment and dependency decisions to the orchestrator. This contract captures that authorization and supersedes conflicting facade details in the preceding pre-release contract. Protocol requirements remain binding.

Blueprint is released. Add compatible functionality where it stays coherent and document necessary acceptance changes for 2.0. Sinal, Relay, and LLM Wire have no external compatibility constraint. Remove superseded APIs instead of retaining aliases. This work does not publish, push, upgrade dependencies, or merge Blueprint into main.

## Shared rules

- Application configuration is immutable and value-first. Startup or preparation validates complete settings before side effects.
- Independent policies have independent controls. Internal limits derive from admitted settings when they express the same policy.
- Internal decisions use typed data. Human-readable diagnostics do not determine cancellation, deadlines, or retry classification.
- Protocol constants remain fixed at their owning boundary. Missing provider data remains unknown rather than becoming a fabricated value.
- Simple entry points preserve useful information. Advanced entry points expose distinct capabilities rather than alternative constructor families.
- Application-owned types and errors remain usable. Boundaries erase native types only after binding their typed callbacks.
- Tests exercise public behavior and actual package composition. Use local scripted transports for external provider behavior. Preserve frozen protocol oracles and negative admission checks.

## Blueprint

- Add `codec.try_imap(base, from, to)` with fallible native conversion in both directions and the existing located codec errors. Retain the base wire schema; native projection may impose additional restrictions.
- Add a direct optional-property bridge to standard `Option(a)` while retaining released `Optional(a)`. Absence, present null, and present value remain distinguishable through an optional nullable codec.
- Add `codec.decode_json_with_limits(codec, limits, source)` using public `parser.ParserLimits` and returning `codec.JsonDecodeError`. The ordinary `decode_json` uses the same strict Blueprint parser for interpreted, generated, and mapped codecs. Native generated parsing remains available only through an explicitly named advanced function if it is retained for its distinct performance capability.
- Public and internal parser defaults have one owner. Ordinary defaults admit exact finite-float Number construction, including subnormal values, while retaining byte/depth/numeric bounds. Caller-chosen stricter limits still reject oversized input.
- Bounded integer projection derives capacity from admitted bounds rather than an unrelated 24-digit constant. Document loading and runtime validation agree with codecs. Preserve exact numbers and host safe-integer checks.
- Repair legacy JavaScript map lookup. Preserve missing keys versus present undefined values where the existing decoder distinguishes them.
- Update generated fixtures, parity checks, documentation, and the 2.0 migration guide. Do not add an arbitrary number of record-arity constructors or general JSON Schema support.

## Sinal

- Introduce a pure opaque `Subscription` that binds a typed event to its observer. A pure subscription plan supplies the default exception-cleanup policy and accepts an optional reporter through value-first configuration. A scoped runner accepts heterogeneous subscriptions through that plan, acquires sequentially, skips work on acquisition failure, and removes prior registrations on failure. Preserve attributed cleanup errors and exact catchable work exceptions.
- Acquisition is not atomically visible. Independent subscription failure does not imply native attach-many grouping semantics. Retain same-shaped native attachment grouping as its distinct capability.
- Validate integer native timing fields before constructing opaque timing values. Add one time-unit selector and three value-first time conversion functions without forcing callers to decode Dynamic or write conversion FFI. Context, exception reasons, and stacktraces remain arbitrary native terms.
- Add a non-panicking span execution outcome that distinguishes failed start encoding before work from failed completion instrumentation after work. Preserve the completed application result on completion-instrumentation failure. Native work exceptions retain their class, reason, and stacktrace; no hidden rerun of work occurs. Keep the existing raising path only as an explicit distinct policy if needed.
- Delegate span timing, context, and event lifecycle to native telemetry. A completion instrumentation failure produces a native exception event with a distinct structured instrumentation reason and returns the retained application result through the result-bearing path. A private per-call identity distinguishes bridge-generated failures from work exceptions. Do not copy the native span implementation or emit an unmatched start event.
- Remove unreachable `BackendFailed` from emit errors. Repair the README record mapping so it preserves method, route, and status.

## LLM provider and session boundary

- Public opaque provider adapters support application-defined HTTP/SSE providers without imports from internal modules or edits to built-in provider switches. Built-in providers use the same adapter boundary.
- An adapter owns request encoding, headers/routes, provider schema projection, stream reduction, and provider replay. Provider state remains typed inside closures where feasible; ordinary Config, PreparedCall, Stream, and Continuation do not require application-supplied reducer-state type parameters.
- The shared runtime retains admission, origin identity, exact tool-result coverage, byte limits, backpressure, deadlines, cancellation, cleanup, and terminal delivery. Public adapter construction is not a path around these checks.
- Provider-specific options belong to provider builders and feed common pure configuration. Keep one obvious built-in path. Do not add WebSocket or non-SSE transport support in this delivery.
- Tool-call outcomes retain normalized assistant text. Continuations retain the provider-authored assistant turn needed for correct replay.
- Buffered and structured execution failures retain retry evidence, including reducer startup failures before transport and received HTTP errors. Preparation remains a separate failure boundary. Missing or malformed usage counts are not represented as zero.
- Progress admission failures retain already-observed state and cannot be overridden by a terminal result from the same event. Queue accounting includes retained identifiers. Terminal provider metadata has an explicit aggregate bound; application-owned replay closure memory remains the adapter author's responsibility. Aggregate terminal text is bounded as a total, while wire-specific block structure remains the reducer's responsibility when no block progress is emitted.
- An external consumer fixture implements a fourth provider with its own reducer/replay types and completes text, tool continuation, and bounded-failure scenarios.

## LLM control and schema-only tools

- Replace string-based FFI timeout classification with typed failure categories. Pool checkout exhaustion of the remaining overall deadline has the same deadline classification as other phases.
- Add independent outgoing request byte limits with the prior request bound as default. Incoming SSE limits remain unchanged by that setting.
- Tool argument and structured-output parser bounds follow the relevant admitted execution limits. Depth/numeric policy remains explicit and bounded.
- Add `types.tool_from_contract(name, description, runtime.RuntimeContract)` alongside native codec admission. Schema-only tools receive the same schema/JSON validation but need no fabricated native application type.
- Schema-only admission supports Blueprint's stated finite subset. Unsupported remote schemas fail explicitly. No unchecked general-schema path is introduced.

## Relay client

- A dynamic discovered-tool call accepts a remote declaration and JSON arguments and returns structured content, content blocks, and distinct application/protocol/transport outcomes without application-owned JSON-RPC parsing.
- Typed and dynamic calls can expose an input-required continuation. Continuation retains originating client, name, request state, and arguments. Supported input methods are explicitly configured and emitted as capabilities; defaults remain empty. A capability does not imply an automatic responder. Callers handle requests and supply responses to continue.
- Preserve rich content and cancellation distinctions. Typed transport failures distinguish connection closure from actual cancellation without diagnostic-string matching.
- Listing has an explicit aggregate bound or page iterator and a configurable bounded default. Accumulation and cursor detection do not perform quadratic copying/scanning.
- Structured-response parser byte bounds follow the admitted response limit while preserving depth and number policy.
- Preserve raw JSON-RPC for distinct unsupported-method access. Do not restore a redundant legacy typed-codec constructor family.

## Relay server and transport policy

- Custom dispatch persists across registry updates and receives the current registry. Preserve advanced context, input rounds, progress, and content; do not retain stale registry closures.
- Content-only definitions support schema overrides and advanced input rounds without dummy output codecs.
- Resource templates are admitted against supported syntax before advertisement. Support ordinary embedded variables such as `{id}.png`; unsupported syntax fails clearly. An explicit matcher is permitted for advanced application-owned matching.
- Generic simple resource, prompt, and completion handlers accept application error types when current wire behavior discards their details. Explicit protocol mappings remain available when semantically meaningful.
- Runtime output can identify its exchange and callers can report per-exchange closure, permitting multiplexed transports without rebuilding worker ownership. Built-in wrappers preserve their current routing behavior.
- Runtime and stdio settings are validated before actors or stdio setup. HTTP SSE keepalive interval is validated caller policy with the prior default retained.
- Independent optional annotation booleans retain omission versus false and compatible combinations. No protocol revision or frozen schema change occurs.

## Composition and acceptance

- The pilot retains native shared-definition scenarios and adds discovered-schema tool composition, mixed Sinal observation, and an external provider example using only supported public modules.
- Package documentation shows one simple path and the distinct extension path. Migration text names every public removal, result change, parser acceptance change, and required consumer update.
- Blueprint gates: `gleam format --check src test`, `gleam check`, `gleam build`, `gleam test`, `gleam test --target javascript`.
- Sinal, Relay, and LLM Wire gates: the same format/check/build/test commands for Erlang, plus existing `nix flake check`.
- Sinal and Relay CI additionally require `gleam build --warnings-as-errors`.
- Relay extra gates: `python3 scripts/check_negative_fixtures.py`, `nix develop --command python3 scripts/relay_schema_check.py`, `./scripts/verify_checksums.sh`, `./scripts/conformance/run-server-suite.sh`.
- LLM Wire extra gate: `sh test/external_package_boundary.sh`, updated for supported provider extension while retaining construction-boundary checks.
- Pilot gates: `gleam format --check src test`, `gleam check`, `gleam build`, `gleam test`, `gleam run`. Oversight uses its existing formatting gate.
- The orchestrator reviews delivered changes and reruns gates on the assembled workspace. Unsupported syntax and intentional limitations remain explicit; a failed gate is not waived to complete an assignment.

## Ownership and dependency order

| Assignment                                  | Owner   | Dependency                                  |
| ------------------------------------------- | ------- | ------------------------------------------- |
| Blueprint mappings, parsing, numeric policy | Agent 1 | None                                        |
| Sinal subscriptions, spans, timing          | Agent 2 | None                                        |
| LLM provider and session boundary           | Agent 3 | None; consume compatible Blueprint baseline |
| LLM control and schema-only tools           | Agent 4 | Agent 3; Blueprint limits API               |
| Relay client and discovery                  | Agent 5 | None; consume compatible Blueprint baseline |
| Relay server and transport policy           | Agent 6 | None; separate checkout from Agent 5        |
| Pilot, migration, independent review        | Agent 7 | Stable package surfaces                     |

Package writers update their own tests and README. Agent 7 owns Oversight and cross-package examples. The orchestrator owns this contract, assignment records, and integration. Shared edits are serialized or reviewed during assembly.
