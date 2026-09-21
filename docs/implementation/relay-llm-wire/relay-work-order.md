# Relay work order: typed tools server over stdio

Status: frozen for dispatch on 2026-09-20.

## Dispatch contract

- Work in `/code/gleam-dream/relay` from clean `master` at
  `75ce50dd1ba180c382c239901ee8e0b8508070a3` (`chore: bootstrap package
skeleton`). Stop and report if the starting tree or head differs.
- Use external `agy` with `--sandbox --dangerously-skip-permissions` and its
  configured default model. Do not pass `--model`.
- Use the configured language-server bridge at the absolute path
  `/etc/profiles/per-user/edgar/bin/agent-lsp`. Do not install or replace it.
  Start Gleam through the repository shell, equivalent to
  `nix develop --command /etc/profiles/per-user/edgar/bin/agent-lsp gleam:gleam,lsp`.
- The implementer owns Relay source, tests, fixtures, dependency files, and
  Relay-local documentation needed by this order. Do not edit Oversight,
  `json_blueprint`, `sinal`, `llm_wire`, or any GitHub state. Do not push,
  publish, open a PR, use credentials, or change repository remotes.
- Use a local path dependency on `../json_blueprint` and `../sinal` for this
  wave. Record their exact observed commits and package versions in Relay's
  provenance documentation. Do not guess published package coordinates or
  repository URLs.
- Implement test first in red-green-refactor slices. Do not write all tests and
  then all implementation. No passing placeholder, permissive decoder, fake
  transport, or swallowed error satisfies this order.
- Use named `todo as "wave N: ..."` only for deliberately deferred public
  scaffold operations. Every TODO must name its owning later wave. Do not put a
  TODO on any accepted Wave 1 path.
- The delivery is returned to the orchestrator for a SolMedium review and gate
  rerun. The implementer must not self-accept or broaden this order.

## Context

Relay is the independent Gleam implementation of Model Context Protocol. This
first production-bound wave must replace the one-function package skeleton with
the intended typed facade and one real vertical capability: a locally spawned
MCP `2026-07-28` tools server over standard input/output.

This wave establishes the pure protocol/core boundaries, typed heterogeneous
tool registry, Blueprint-owned schema contracts, authoritative OTP runtime
ownership, real process I/O, and native Sinal observations. It does not depend
on `llm_wire`; an MCP tool server must work without any LLM provider client.

## Verified starting evidence

The orchestrator verified these trees before freezing the order:

| Repository | Branch and exact head                                                            | Package fact                                      | Baseline                                      |
| ---------- | -------------------------------------------------------------------------------- | ------------------------------------------------- | --------------------------------------------- |
| Relay      | `master` at `75ce50dd1ba180c382c239901ee8e0b8508070a3`                           | `relay` `0.1.0`, Gleam `>= 1.18.0`, Erlang target | `gleam test`: 1 pass; `nix flake check`: pass |
| Blueprint  | `implementation/schema-aware-core` at `d3f0708b61eddb4a4789c0476ab5384267814a51` | `json_blueprint` `1.7.1`, MIT                     | `gleam test`: 140 passes                      |
| Sinal      | `master` at `dd09933e5466628f7d46fa896c389f31ba7d4cb6`                           | `sinal` `0.1.0`, Apache-2.0, `telemetry == 1.4.2` | `gleam test`: 47 passes                       |

Recheck these facts before dependency resolution. A newer sibling head or a
compiler-floor conflict is an evidence change: report it before changing a
sibling or weakening Relay's toolchain.

## Protocol pin verdict

The `2026-07-28` pin is a released protocol, not a draft. Its authority is the
official MCP tag and exact commit
`5f5440bb26a62e2cf3440b92da5a667efa03b267`, licensed MIT. The source-of-truth
artifact is `schema/2026-07-28/schema.ts`; the repository also carries generated
`schema/2026-07-28/schema.json`. The official release page identifies the same
short commit `5f5440b` as the stable release.

Frozen conformance requirements are
`@modelcontextprotocol/conformance@0.2.0-alpha.10`. The official
`requirements/2026-07-28.yaml` names that release, published 2026-07-27, as its
anchor. Pin the package through a lock file when it first enters Relay tooling;
do not substitute today's unpinned harness.

Primary sources:

- <https://github.com/modelcontextprotocol/modelcontextprotocol/tree/2026-07-28>
- <https://github.com/modelcontextprotocol/modelcontextprotocol/commit/5f5440bb26a62e2cf3440b92da5a667efa03b267>
- <https://modelcontextprotocol.io/specification/2026-07-28>
- <https://github.com/modelcontextprotocol/conformance/blob/main/requirements/2026-07-28.yaml>

The current official server harness accepts a URL and therefore exercises an
HTTP server, not a stdio server command. This wave must run official schema
checks and Relay-owned process scenarios derived from the pinned requirements,
but it must not claim an official frozen conformance pass. The full frozen
server requirement run belongs to the Streamable HTTP wave.

The final release also differs from the retained laboratory prototype in one
important place: server identity moved out of the `server/discover` result body
and into result `_meta["io.modelcontextprotocol/serverInfo"]`; the server should
identify itself there on every successful result. Use the final tagged schema,
not copied prototype fixtures, as wire authority.

## Governing design

Implement against these accepted anchors:

- `relay-design.md` §2.1–§2.6, §2.9, §3.1, §3.3, and §4.
- `PUBLIC-API.md`, Relay facade and package-seam paragraphs.
- `API-COVERAGE.md`, Relay rows.
- `research/relay-server-contract.md`.
- `research/relay-resource-authorization-contract.md`.
- `research/protocol-auth-boundaries.md`.
- `research/runtime-schema-contract.md`.
- `research/sinal-lifetime-contract.md`.
- `/code/gleam-dream/relay/AGENTS.md`.

The constraints to preserve are:

- Revision-specific codecs own methods and wire shapes. Native values do not
  collapse the `2026-07-28` and `2025-11-25` contracts.
- Ordinary JSON-RPC envelopes use `gleam_json` and checked Gleam decoders.
  Blueprint is used only for typed schema contracts, schema materialization,
  typed tool arguments/results/errors, and their validation. Do not build a
  second schema DSL in Relay and do not make Blueprint the general protocol
  envelope model.
- A registered tool retains its input codec, output codec, error codec,
  metadata, and typed contextual handler before heterogeneous erasure.
- Listing and dispatch derive from the same registry. Registry construction
  rejects duplicate names and schemas that cannot meet the protocol profile.
- Application context is explicit at listing and invocation and stays outside
  the business argument schema. Do not introduce a universal request-context
  record.
- The sans-I/O reducer owns protocol state and returns effects. It performs no
  process, clock, stdin/stdout, handler, or telemetry effects.
- Transport allocates an internal exchange identity before parsing. Runtime
  invocation identity is separate from untrusted JSON-RPC IDs and progress
  tokens.
- Exactly one authoritative owner serializes each exchange history and effect
  interpretation. Copyable reducer values do not constitute exactly-once
  execution.
- Sinal observes committed Relay facts. An observation never admits, completes,
  cancels, retries, or otherwise drives a protocol transition.
- Native OTP/process ownership is the initial runtime. Keep pure modules free of
  OTP and I/O so a later JavaScript core validation remains possible.

Apply the repository's Gleam guidance: custom sum types for error families,
opaque smart constructors for invariants, exhaustive cases, no stringly typed
library errors, no discarded `Result`, and no public `Dynamic` protocol
contract. Keep FFI minimal, typed on the Gleam side, and confined to runtime or
transport boundaries.

## What to build

### 1. Typed public scaffold

Create a coherent public type surface for the full retained Relay direction,
with implementation complete only where this order says so. The scaffold must
make these boundaries visible and distinct:

- protocol revisions and revision-specific wire codecs;
- JSON-RPC request/notification/response values and error families;
- typed tools, declarations, contextual registries, and dispatch;
- sans-I/O server input, state, effects, exchanges, and invocations;
- server runtime ownership and transport ownership;
- stdio, Streamable HTTP, and paired in-memory transports;
- typed client method/result pairs, typed tool references, and raw checked JSON
  calls;
- resource-server grants/policy and MCP client authorization;
- resources, prompts, completion, progress, cancellation, subscriptions,
  logging, and multi-round input;
- public test-kit concepts: scripted peer, paired transport, and fake clock;
- Relay-owned Sinal observation descriptors.

Deferred functions may contain only named TODOs that cite a later wave from the
roadmap below. Their modules and documentation must say that they are not
implemented. Do not return empty lists, dummy success, anonymous grants, or
no-op close/cancel values to make the scaffold appear usable.

The completed initial facade must at minimum preserve these seam shapes. Names
may be made idiomatic without changing their type distinctions:

```gleam
pub fn context_tool(
  name: ToolName,
  metadata: ToolMetadata,
  input: blueprint_codec.Codec(input),
  output: blueprint_codec.Codec(output),
  error: blueprint_codec.Codec(application_error),
  handler: fn(context, input) -> Result(output, application_error),
) -> Result(ContextTool(context), ToolAdmissionError)

pub fn registry(
  tools: List(ContextTool(context)),
) -> Result(Registry(context), RegistryError)

pub fn declarations(
  registry: Registry(context),
  context: context,
) -> Result(List(ToolDeclaration), ListingError)

pub fn dispatch(
  registry: Registry(context),
  context: context,
  name: ToolName,
  arguments: blueprint_value.Value,
) -> Result(blueprint_value.Value, DispatchError)
```

`ToolName` is validated and opaque. Derive its exact admitted grammar and limits
from the tagged specification. `ToolDeclaration` retains the exact admitted
input schema and output schema; wire encoding materializes those retained
schemas rather than reconstructing them independently. `DispatchError`
distinguishes unknown tool, invalid input, application failure, invalid output,
and error-encoding failure.

The public server core must expose typed input/effect boundaries equivalent to:

```gleam
pub type ServerInput(context) {
  MessageReceived(exchange: ExchangeId, context: context, bytes: BitArray)
  InvocationFinished(invocation: InvocationId, outcome: InvocationOutcome)
  ExchangeClosed(exchange: ExchangeId)
}

pub type ServerEffect(context) {
  Write(exchange: ExchangeId, bytes: BitArray)
  StartInvocation(Invocation(context))
  CancelInvocation(InvocationId)
  CloseExchange(ExchangeId)
  Ignore(UnhandledMessage)
}

pub fn step(
  server: Server(context),
  input: ServerInput(context),
) -> #(Server(context), List(ServerEffect(context)))
```

The actual types may split byte admission from parsed protocol transitions, but
both seams must be public and testable. Parsing and encoding remain in the
revision module; the lifecycle reducer remains pure.

### 2. Blueprint schema contract and registry admission

Use current Blueprint public APIs from the exact sibling head. Relay may consume
`json/blueprint/codec.{Codec, schema, encode, decode, schema_document}` and
`json/blueprint/value.Value`. Do not edit Blueprint and do not copy its
implementation.

Relay registry admission must:

- reject a missing schema (`UnknownSchema` or other schema failure);
- require a valid JSON Schema 2020-12 object-root input contract;
- accept an output schema of any root type allowed by the final protocol;
- retain the actual schema returned by the codec;
- reject duplicate tool names;
- return located typed errors for unsupported Relay profile features rather
  than rewriting or widening a schema;
- never dereference a network `$ref` automatically;
- decode arguments before running a handler and validate encoded successful
  output before emitting it;
- turn output or application-error encoding failure into a sanitized internal
  protocol error, never fabricated success.

Blueprint's new build-time code generation remains available to application
authors and test fixtures. Relay must not invoke it at runtime, modify it, or
promote it to Relay's own generator. If a fixture uses a generated codec, its
generated and runtime forms must produce the same retained schema and behavior.

Ordinary envelope parsing must stay standard JSON. If exact Blueprint numeric
values cannot be transferred from the standard envelope parser without loss,
stop and report that concrete boundary collision; do not modify Blueprint,
silently coerce decimal numbers through `Float`, or parse all protocol values as
Blueprint merely to bypass the design.

### 3. Final `2026-07-28` tools wire

Implement a revision-specific byte codec and pure dispatch for:

- `server/discover`;
- `tools/list` without pagination in this wave;
- `tools/call` with absent arguments defaulting to `{}`;
- `notifications/cancelled` for an in-flight stdio request;
- unknown valid notifications as a non-wire ignored disposition;
- inbound responses as a non-wire ignored disposition.

Use the final tagged TypeScript schema as source of truth. At minimum:

- accept JSON-RPC string and integer IDs; never use them as runtime identities;
- require per-request `_meta.io.modelcontextprotocol/protocolVersion` and
  `_meta.io.modelcontextprotocol/clientCapabilities`;
- accept optional `_meta.io.modelcontextprotocol/clientInfo` according to the
  final schema;
- return unsupported `2026-07-28` version requests with the specified `-32022`
  error and supported-version data;
- distinguish parse error, invalid request, method not found, invalid params,
  unsupported version, and internal error;
- omit an unreadable/untrustworthy request ID from an error response;
- emit no response for notifications;
- include `resultType: "complete"` in modern completed results, including tool
  application failures with `isError: true`;
- include result `_meta["io.modelcontextprotocol/serverInfo"]` on every
  successful result;
- list `inputSchema` and `outputSchema` from the retained codecs;
- for success, emit `structuredContent` that conforms to the output schema and
  a backward-compatible text content mirror;
- for typed application failure, emit `isError: true` and safe content. Do not
  place encoded application-error data in `structuredContent` unless it also
  conforms to the declared output schema;
- keep malformed arguments, unknown tools, and protocol failures out of the
  ordinary tool-error result path.

Do not implement or inspect HTTP headers in this codec. `MCP-Protocol-Version`,
`Mcp-Method`, and `Mcp-Name` belong to the later HTTP adapter; stdio carries its
metadata in the JSON body.

### 4. Authoritative OTP runtime owner

Implement one OTP owner that serializes server-core inputs and interprets
effects. It must:

- allocate an `ExchangeId` before parsing each frame;
- allocate an `InvocationId` only after a tools call is admitted;
- start each admitted handler under supervised ownership;
- ensure a given invocation is started at most once and an exchange produces
  at most one terminal response;
- suppress stale completion after cancellation, close, timeout, or owner
  replacement;
- isolate a crashing handler and translate the crash to one sanitized internal
  error without crashing the connection owner;
- cancel work when `notifications/cancelled` names an active stdio request and
  suppress later output for that request;
- bound live exchanges, frame bytes, and invocation duration with explicit
  configuration and typed refusal/timeout outcomes;
- retain terminal tombstones long enough to reject late callbacks, with an
  explicit bounded-retention policy;
- release invocation processes and owner state after terminal outcomes.

No exactly-once claim extends to external side effects. The runtime proves one
Relay invocation and one Relay response under one owner; application handlers
remain responsible for idempotency or reconciliation of external effects.

### 5. Real stdio boundary

Deliver a real local-process server boundary. A test fixture executable must be
spawnable as a child, read newline-delimited UTF-8 JSON-RPC from stdin, and write
only newline-delimited MCP JSON-RPC to stdout.

- Each input line is one bounded message; reject embedded/trailing protocol
  material and oversized frames.
- Support incremental reads and UTF-8 characters split across OS chunks.
- Never write logs or Sinal diagnostics to stdout. Stderr is isolated and may
  contain diagnostics.
- Serialize concurrent responses through one writer owner so bytes never
  interleave.
- On EOF, stop admission, cancel or settle owned invocations according to the
  runtime policy, flush permitted terminal output, and exit without orphaning
  processes.
- Close is idempotent. Broken stdout, child termination, and owner termination
  are explicit terminal outcomes.

This is an explicitly local, unprotected process transport. Name its constructor
and documentation accordingly. It must not imply bearer verification or safe
public network deployment.

### 6. Authorization boundary honesty

Carry the typed resource-server scaffold from the design: opaque bearer token,
resource, scope, verifier, granted request, protection configuration, tool
policy, and protected registry remain distinct from application context and
from Warden web identity.

Runtime bearer verification, HTTP challenges, RFC 9728 metadata, JWT/JWKS,
introspection, and protected HTTP routing are Wave 4. Until then:

- no public function may mint an apparently verified grant from raw claims;
- no transport may label the stdio path protected;
- a protected runtime constructor must remain a named TODO or return an explicit
  unsupported capability before any handler can run;
- unknown, hidden, and denied tools retain separate internal causes but share
  one external inaccessible outcome when protected dispatch is implemented;
- no bearer token may enter a generic principal, error, Sinal observation, log,
  or downstream tool arguments.

Do not provide fake protected support merely to complete the scaffold.

### 7. Native Sinal observations

Use the exact sibling Sinal public API. Define Relay-owned, typed descriptors for
at least frame rejected, request admitted, invocation started, invocation
completed, invocation cancelled, invocation crashed, and exchange closed.

- Event names and field keys are package-owned trusted atoms, never atoms made
  from request strings.
- Measurements and metadata use `sinal/fields` typed groups.
- Emit only after the owning transition has occurred.
- Emission failure cannot undo or change the protocol result.
- Metadata contains bounded identifiers/classifications and never full request
  bodies, tool arguments, application output, bearer values, or credentials.
- Native attachment tests observe real `:telemetry` delivery through Sinal;
  do not replace Sinal with a test callback seam.

## Acceptance criteria

The wave is acceptable only when all of the following are true:

1. Two tools with unrelated native input, output, and application-error types
   coexist in one registry and are listed and invoked through the same public
   server. Wrong handler/codec pairing fails at compile time in a negative
   fixture.
2. Duplicate names, invalid names, primitive-root input schemas, unavailable
   schemas, unsupported schema features, malformed arguments, unknown tools,
   invalid output, and error-encoding failure all produce their specified typed
   refusal and no handler is called before admission completes.
3. Discovery, list, successful call, and application-error call encode as valid
   final `2026-07-28` messages. Official tagged JSON Schema validation passes for
   every emitted corpus item and fails reviewed single-mutation negatives.
4. Final-release server identity appears in result `_meta`; no obsolete RC-era
   server-info field appears in the discovery body.
5. The pure reducer performs no I/O and returns deterministic state/effects for
   repeated fixtures. Property tests cover at least encode/decode round trips,
   one terminal response per exchange, no invocation before admission, and no
   output after terminal state.
6. An actual spawned child process completes discovery, list, success call, and
   tool-error call over stdin/stdout. Its stdout contains only valid one-line MCP
   messages and stderr content cannot corrupt the wire.
7. Process tests cover partial UTF-8, partial reads, multiple frames in one OS
   chunk, configured maximum frame, EOF shutdown, broken child/owner, handler
   crash, and timeout.
8. Race tests cover equal wire IDs on distinct exchanges, duplicate admission,
   cancel-before-start, cancel racing completion, late completion after cancel,
   stale callback after owner replacement, simultaneous handler completion, and
   repeated close. Run each race enough times to expose ordering assumptions and
   assert process/mailbox cleanup rather than sleeps alone.
9. Real Sinal handlers observe typed lifecycle facts after transitions. Handler
   or emission failure does not alter the response, and no request body,
   argument, output, token, or credential appears in observations.
10. The README and public docs state exactly what works: local unprotected stdio
    tools server at `2026-07-28`. They state that HTTP, official server
    conformance, client, production resource authorization, and legacy revision
    support remain unimplemented.
11. Every deferred public operation has a named later-wave TODO. A repository
    inventory lists them; no accepted Wave 1 path contains a TODO, panic used as
    control flow, or fabricated success.
12. The implementation has no dependency on `llm_wire` and no LLM provider
    concept in Relay's public or internal modules.

## Upstream provenance, license, and checksum tests

- Record the MCP spec repository, exact tag/commit, MIT license, artifact paths,
  and SHA-256 for every copied schema or fixture.
- Record the conformance package name/version and lock-file integrity. Retain
  the release's `requirements/2026-07-28.yaml` only if needed for traceability;
  if copied, checksum it and preserve its license notice.
- Record Blueprint and Sinal local path, package version, exact Git head, and
  license. Dependency tests fail loudly when the observed sibling identity no
  longer matches the recorded development pin.
- Keep copied upstream fixtures separate from Relay-authored negative and race
  tests. Give every copied or ported case its source and license; do not copy
  SDK implementation code.
- Add one deterministic verification command that checks committed checksums
  without fetching the network. A separate documented refresh command may
  fetch pinned upstream material and must fail if Git does not resolve to the
  exact commit.

## Test strategy

No formal behavior-rule block exists in the current design layer, so this order
uses the inner TDD loop: one failing public behavior, the smallest passing
change, then green-only refactoring.

Test in layers without mocking owned modules:

- registry, schema admission, codecs, and reducer together in-process;
- OTP owner with real Gleam processes, monitors, timers, and Sinal;
- stdio with a real spawned local server process and real pipes;
- official schema validation through the pinned schema artifact;
- upstream conformance CLI only in the HTTP wave where its server URL contract
  can be exercised.

Property and generative tests must have deterministic seeds in failure output.
Race tests must synchronize on messages/monitors/barriers instead of depending
only on wall-clock sleeps. Keep the suite bounded and suitable for the normal
repository gate.

## Gate

Run these commands from `/code/gleam-dream/relay` and report exact outcomes:

```text
nix develop --command gleam format --check src test
nix develop --command gleam check
nix develop --command gleam test
nix flake check
```

Also run the Relay-local upstream checksum/license verifier and the spawned
stdio process suite through their documented deterministic commands. Do not
claim conformance from selected scenarios or from an expected-failures file.

## Out of scope

- Streamable HTTP server/client and Mist.
- The official frozen server requirement run, because the current harness
  server leg is URL/HTTP based.
- Relay client runtime or provider interaction.
- Production bearer verification, RFC 9728 HTTP behavior, JWT/JWKS,
  introspection, authorization challenges, and MCP client authorization.
- `2025-11-25` lifecycle and any older revision.
- Resources, prompts, completion, subscriptions, pagination, logging, MRTR,
  Tasks, Apps, DPoP, workload identity, and deprecated dual-endpoint HTTP+SSE.
- Publishing, package split, repository URL changes, GitHub operations, or
  modifications to sibling packages.

## Escalation rule

Stop and return evidence before changing any goal, public invariant, revision
wire contract, module ownership boundary, sibling API, dependency source,
authorization claim, or deferred-wave boundary. In particular, escalate:

- any mismatch between the final tagged schema and this order;
- inability to preserve Blueprint exact values across the standard envelope
  boundary without a lossy numeric conversion;
- a local sibling head/version different from the recorded pin;
- a compiler or dependency floor conflict;
- a requirement to modify Blueprint or Sinal;
- a runtime design that cannot prove single ownership without changing the
  public core contract.

Pure implementation choices inside these contracts belong to the implementer.

## Concise roadmap after Wave 1

| Wave                             | Outcome                                                                                                                                   | Required proof                                                                                |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| 2. Complete modern server core   | Remaining `2026-07-28` server families, rich content, resources, prompts, completion, progress, pagination/cache, subscriptions, and MRTR | Tagged-schema corpus, pure/runtime tests, capability gating                                   |
| 3. Streamable HTTP               | Thin Mist shell, final HTTP headers, bounded bodies, Origin/Host policy, request-scoped SSE, backpressure and disconnect cancellation     | Full frozen `2026-07-28` server requirements with no expected-failure claim; HTTP fault tests |
| 4. Resource-server authorization | Verifier adapters, grants, protected routing, RFC 9728 metadata/challenges, scope/resource binding and redaction                          | Frozen server authorization requirements, rotation/bypass/malicious-input tests               |
| 5. Typed client and test kit     | Method/result pairing, typed references/raw calls, timeouts/correlation, paired transport, scripted peer and fake clock                   | Client properties, interoperability with pinned official peers                                |
| 6. MCP client authorization      | Discovery, issuer selection/migration, registration, PKCE, resource indicators, incremental scope, refresh rotation and bounded retry     | Frozen client authorization requirements and malicious-server tests                           |
| 7. Legacy compatibility          | Explicit `2025-11-25` codec, initialize typestate, sessions, legacy HTTP/SSE behavior, and stdio era selection                            | Independent frozen `2025-11-25` server/client requirement runs                                |
| 8. Extensions and hardening      | Tasks/Apps only from pinned extension contracts; fuzz, soak, limits, interop, OTP 27/28                                                   | Extension-specific gates and release-readiness report                                         |

Each later wave replaces a named TODO without changing the meaning of the Wave
1 seams. A real caller mismatch or upstream pinned-spec correction returns to
the design owner rather than being silently absorbed.
