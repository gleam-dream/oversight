# Relay — typed MCP server and client

The current public API cleanup follows the [pre-release contract](docs/implementation/pre-release-api/contract.md#relay). It supersedes older facade and compatibility descriptions below.

The additive application API changes are specified in the
[API ergonomics contract](docs/implementation/api-ergonomics/contract.md#relay-tools).

The [current API control contract](docs/implementation/api-control/contract.md#relay-client)
covers discovered JSON tool calls, typed transport failures, bounded tool
listing, and explicit input-required continuations. The client advertises only
configured input methods and leaves response decisions to the application.
Server dispatch reads the current registry after updates, content-only tools
support advanced input rounds and schema overrides, and runtime outputs identify
their exchange for multiplexed transports. Resource templates admit supported
syntax before advertisement, with an explicit matcher for advanced patterns;
HTTP keepalive is validated caller policy. The
[pilot](playground/ecosystem_pilot/README.md) exercises discovery and dynamic
calls over local HTTP. Older laboratory declarations below are design evidence.

## 0. Purpose and scope

- Relay targets complete typed MCP server and client behavior, stdio and Streamable HTTP transport, and MCP resource-server and client authorization. The initial three-method server facade is a delivery subset rather than the full package scope.
- This design consolidates the baseline at `9194f02` with the recorded protocol, authorization, and interface findings. [PUBLIC-API](PUBLIC-API.md) freezes the initial facade; partial and open [coverage](API-COVERAGE.md#relay) remains implementation backlog.
- Native APIs retain typed values; revision-specific codecs own wire methods, JSON shapes, and header values. The pure protocol core returns effects, while runtime adapters own sockets, processes, clocks, and cleanup.
- Protocol revision selects an explicit wire contract and lifecycle. The first target is released `2026-07-28`, followed by `2025-11-25` compatibility; the baseline's older supported-revision targets remain deferred scope.
- LLM provider clients and a general OAuth authorization server remain outside Relay. A configurable test authorization server remains part of the public test-kit target.
- Deprecated dual-endpoint HTTP+SSE remains optional compatibility scope rather than a first-class transport. Revisions older than `2025-03-26` remain excluded as in the baseline.

## 1. Landscape and evidence

| Source                                                | Role in Relay                                                                                 | Limitation                                                                                 |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| MCP specification and frozen conformance requirements | Wire authority and acceptance gate                                                            | Selected scenarios or structural schema checks do not establish complete conformance       |
| Official TypeScript and Python SDKs                   | Scoped implementation oracles for protocol, transport, and authorization scenarios            | Implementation choices cannot override the pinned specification                            |
| `mcp_toolkit`                                         | Typed builder, decoder, snapshot, and transport design reference                              | Older protocol, JSON-string schemas, and no official conformance integration               |
| `mcp_client`                                          | Child-port ownership, stderr isolation, buffering, crash eviction, and reconnection reference | Stdio-only older protocol and raw string API                                               |
| Anubis                                                | Registration, contextual authorization, version policy, and supervision reference             | Baseline research did not inspect its test tree; documented features are not test evidence |

- The exact source pins and licenses appear in §6. This consolidation relies on the recorded research and does not claim new upstream suite runs.
- The baseline proposed eight Relay distribution packages. The initial distribution keeps their responsibilities as internal Relay modules; a later physical split remains deferred until target, dependency, or release-cadence evidence justifies it. This changes packaging only: server, client, stdio, HTTP, authorization, test-kit, conformance, and pure-core capabilities all remain Relay scope.
- The pure core must remain separable from OTP and I/O. JavaScript-target core validation remains a deferred baseline ambition rather than a claim that the initial Erlang package supplies dual-target runtime support.

## 2. Target design

### 2.1 Module and package ownership

- Internal modules separate protocol values, revision codecs, registry construction, server dispatch, client behavior, transport, authorization, and test support. Conformance executables remain repository tooling.
- [Blueprint](blueprint-design.md) owns the JSON Schema-aware value/codec model, schema ASTs, validation, and schema generation used by declarations and schema-validated output. Relay must not duplicate that `Schema(a)` DSL. Ordinary protocol envelopes prefer standard Gleam JSON encoders/decoders, with any reusable codec abstraction independent of Blueprint.
- Relay owns protocol-specific schema admission and revision-specific document encoding. Blueprint source generation remains experimental tooling outside the initial public facade; proposed `relay_gen` work remains optional protocol tooling rather than a published API claim.
- [Warden](warden-design.md) owns web login and OIDC identity. Relay owns MCP bearer grants and authorization roles; neither package initially depends on the other.

### 2.2 Type safety and data contracts

- Public `String` or `Dynamic` use requires a documented boundary justification; `Dynamic` must not become a public protocol contract. Extension payloads, metadata, and explicit raw-tool calls retain checked JSON boundaries without requiring Blueprint. Blueprint values apply when those paths explicitly need JSON Schema validation.
- Method names, protocol revisions, content variants, errors, roles, log levels, and stop reasons use typed alternatives. Names, cursors, resource URIs, progress tokens, session identifiers, scopes, and credentials use validated or opaque types where their ownership requires it.
- Binary content remains bytes natively, with base64 confined to revision codecs. URI templates require parsed segments rather than unchecked substitution.
- Blueprint’s exact-number policy applies when its schema/value model is used; ordinary protocol serialization retains its own explicit numeric contract. The current integer-only laboratory request identifiers and progress values are a subset; general numbers, fractional progress, and byte parsing remain open.
- A tool retains its input codec, output codec, metadata, and typed handler before heterogeneous registration erases native types. Registry construction rejects duplicates and unavailable required schema metadata; declarations and dispatch derive from the same registry.
- Admission must retain the actual Blueprint schema rather than independently handwritten JSON. Unsupported schema or dialect features require explicit outcomes instead of silent rewriting.
- Handler context remains application-owned and explicit at listing and invocation. Contextual tools keep tenant, identity, and policy inputs outside the business argument schema; no universal request-context record is introduced.
- Native codec compatibility is a compile-time obligation. Protocol document validity, decoded argument validity, and output-schema compliance remain separate runtime obligations.

### 2.3 Typed requests and results

- Typed method values pair parameter and result codecs without requiring GADTs. Client-to-server and server-to-client method types remain distinct so direction is checked at the public boundary.
- Typed tool references retain input and output contracts. An explicit raw call returns a checked JSON result rather than claiming a native result type; it does not require Blueprint.
- Call outcomes distinguish structured output, content-only output, and tool execution failure from protocol, transport, and authorization errors. Retain the baseline structured output plus text-mirror compatibility intent through revision-specific result encoding.
- Tool output-schema declarations, annotations, text/image/audio content, resource links, and embedded resources remain required server scope. The modern prototype's general JSON structured-content boundary does not establish those complete capabilities.
- Modern complete results include `resultType: "complete"`, including tool failures with `isError: true`. The `2025-11-25` result codec omits `resultType`; shared native values must not collapse those wire contracts.

### Current contextual tool declarations

- Code below is a current prototype declaration excerpt: constructor definitions and function signatures retain the linked source module’s names and aliases; function bodies and unrelated declarations are omitted. These excerpts are not standalone modules or published package signatures, and no new compilation or runtime claim follows from this documentation pass.
- [The registry module](playground/interface_lab/src/lab/relay.gleam) imports `Codec` from `lab/blueprint` for schema-derived declarations. [The shared-registry consumer](playground/interface_lab/src/consumers/shared_registry.gleam) preserves contextual business handlers through registration; broader content and output-schema contracts above remain backlog.

```gleam
pub fn context_tool(
  name: String,
  input: Codec(i),
  output: Codec(o),
  error: Codec(e),
  handler: fn(context, i) -> Result(o, e),
) -> ContextTool(context)

pub fn registry(
  tools: List(ContextTool(c)),
) -> Result(Registry(c), RegistryError)

pub fn dispatch(
  registry: Registry(c),
  context: c,
  name: String,
  input: Value,
) -> Result(Value, DispatchError)
```

### 2.4 Sans-I/O core and exchange ownership

- Pure transitions classify requests, notifications, responses, and errors; they return response, invocation, cancellation, and cleanup effects. The interpreter performs application work outside the reducer.
- The transport allocates an `ExchangeId` before parsing so parse failures still have an unambiguous destination. The core allocates a distinct `InvocationId` only after admitting executable work.
- Client wire identifiers and progress tokens remain payload metadata. They must not identify a runtime task or response destination, because independent exchanges may repeat them.
- An invocation retains the selected dispatch path, tool name, arguments, admitted grant, and application context. Protected execution must re-enter protected dispatch rather than cache a raw handler that bypasses policy.
- Immediate responses and tool calls consume the same exchange ownership boundary. Repeated admission, late progress, and repeated completion cannot create a second response in one authoritative history.
- Closing an exchange before admission leaves a terminal record; later admission cannot revive it. Closing an active exchange emits cancellation intent and suppresses subsequent wire output.
- Copyable reducer state and invocation values cannot enforce authoritative execution or exactly-once side effects. The eventual owner must serialize effect interpretation and prevent stale callbacks from aliasing a replacement exchange.
- Tombstone retention, resource bounds, concurrent commands, and runtime cleanup remain implementation obligations. Pure terminal suppression does not establish that an external effect stopped or was undone.

### Current modern exchange declarations

- The [modern server module](playground/interface_lab/src/lab/relay_server_2026.gleam) imports `authorization`, `exchange`, and `Value` from their laboratory modules. [The modern consumer](playground/interface_lab/src/consumers/modern_relay.gleam) supplies parsed values, explicit context, and an admitted grant; this does not parse bytes or admit HTTP headers.
- The prototype uses `lab/value.Value` as a shared laboratory convenience. The production ordinary JSON boundary remains schema-independent; no replacement signature is settled here. `perform` interprets one retained invocation outside `step`, and copied invocations still require a runtime owner to prevent duplicate execution.

```gleam
pub type Input(context, principal) {
  RequestReceived(
    exchange: exchange.ExchangeId,
    application_context: context,
    grant: authorization.GrantedRequest(principal),
    message: Value,
  )
  ToolFinished(
    invocation: exchange.InvocationId,
    outcome: Result(Value, relay.DispatchError),
  )
  ToolProgress(invocation: exchange.InvocationId, value: Int)
  ResponseStreamClosed(exchange: exchange.ExchangeId)
}

pub fn step(
  server: Server(context, principal),
  input: Input(context, principal),
) -> #(Server(context, principal), List(Effect(context, principal)))

pub fn perform(
  invocation: Invocation(context, principal),
) -> Input(context, principal)
```

### 2.5 Revision admission and lifecycle

- Modern `2026-07-28` requests carry protocol version and client capabilities in `_meta`. `server/discover` is supported, but clients need not call it before listing or invoking tools.
- Modern Streamable HTTP uses one POST per request without GET, DELETE session termination, `Mcp-Session-Id`, or an initialize handshake. Required `MCP-Protocol-Version`, `Mcp-Method`, and tool-call `Mcp-Name` must agree with the body.
- Unsupported modern versions produce the pinned `-32022` outcome. Malformed envelopes, invalid parameters, unknown methods, header disagreement, and parse failures remain distinct errors.
- Protocol members must have unambiguous names and valid shapes. Absent tool arguments default to an empty object; supplied non-object arguments reject before domain decoding.
- A notification receives no ordinary JSON-RPC result. Valid unsupported notifications and inbound responses produce a non-wire disposition; transport mapping must remain separate from invocation.
- An untrustworthy wire identifier is omitted from the error response while exchange identity still determines its destination. Accepted HTTP notifications require the revision-appropriate empty response behavior.
- Legacy `2025-11-25` compatibility requires initialize, negotiated capabilities and version, then initialized before normal requests. It must reject repeated initialization, unknown or stale sessions, and post-initialization version disagreement.
- Legacy early ping, cancellation restrictions, notifications, batching, and header behavior must follow that revision rather than inherit modern rules. A ready legacy client can use handshake typestate; modern readiness must not invent a handshake.
- Baseline `2025-03-26` and `2025-06-18` support remains deferred compatibility scope. Supported revisions must be explicit; deprecation lasts at least one minor release and removal of supported revisions requires a major release.

### 2.6 Runtime and transports

- The server runtime owns supervised invocations, timeout, cancellation observation, progress callbacks, crash isolation, and cleanup. Modern request ownership and legacy session supervision must remain separate lifecycle strategies.
- Legacy sessions retain configurable idle timeout and maximum session count. Client runtime owns correlation, timeouts, registered callback handlers, and transport lifetime.
- The transport port provides bounded inbound data, explicit terminal outcomes, cancellation, and shared idempotent close. Pure effects cannot establish connection or actor cleanup.
- Stdio uses newline framing with configurable large-frame bounds, incremental UTF-8 handling, and stderr isolation. Child exit, stdout noise, partial reads, and close-stdin/wait/terminate shutdown ordering require tests.
- Modern HTTP owns body limits before parsing, media negotiation, case-insensitive headers, encoded header values, Origin/Host allow-lists, response streaming, disconnect handling, and backpressure. Mist remains a thin runtime adapter rather than the protocol owner.
- Legacy Streamable HTTP retains the baseline POST JSON/SSE, GET notification stream, DELETE session termination, session headers, event store, and resumability capabilities. These belong to the legacy codec and transport strategy, not the modern POST-only path.
- Client SSE parsing retains carry-over state across chunks. Revision-supported reconnect hints, `Last-Event-ID`, event ordering, and duplicate suppression remain required tests; exactly-once event delivery requires evidence beyond parser correctness.
- HTTP authorization retry is bounded to prevent repeated 401 authentication loops. Paired in-memory transports remain a public downstream-testing capability.

### 2.7 Resource-server authorization

- The application selects a configured verifier that accepts an opaque bearer token and returns an attestation of principal, audiences, and scopes. A constructible attestation is a trusted adapter assertion, not cryptographic proof.
- Relay admits an opaque grant only after checking the configured resource and endpoint scopes. The initial profile requires exactly one matching audience and exact scope membership; duplicate or additional audiences reject until a broader policy is defined.
- The grant retains the accepted resource and all actual scopes. Each protected registry rechecks them against its own configuration before policy, decoding, or handler invocation.
- Listing evaluates visibility; named invocation re-evaluates visibility and execution permission using the current explicit context. Argument-dependent authorization remains inside the typed handler after decoding.
- Unknown, hidden, and denied names share one external inaccessible outcome while retaining separate internal causes. Sanitized protocol encoding must not disclose those causes.
- A protected transport must route every protected operation through the protected registry. Constructing that wrapper cannot invalidate a previously copied raw registry, so integration tests must detect bypass paths.
- A Warden verified identity cannot substitute for a Relay grant. Application policy may relate the independently verified bearer principal to the web identity, but their authority remains distinct.
- Verifier labels do not enforce production provenance, and grants currently carry no verifier-origin identity. Cross-domain grant reuse requires explicit policy before trusting interchangeable principal types.
- Relay owns bearer extraction, RFC 9728 metadata, challenges, resource/audience binding, scopes, and HTTP/MCP mapping. Local JWT/JWKS and RFC 7662 introspection remain verifier targets; key rotation, issuer/expiry/signature checks, and exception mapping require runtime evidence.
- Wrong or absent authorization must map to the applicable challenge; insufficient scope must preserve required-scope information. Tokens must not pass through to upstream APIs or leak through errors, observations, or generic principals.
- Anonymous access, authorization-sensitive pagination, and a broader audience policy remain deferred capabilities. Policy callback evaluation does not make application data reads and handler effects atomic.

### Current protected registry entry points

- [Resource authorization](playground/interface_lab/src/lab/relay_authorization.gleam) keeps the grant's principal type separate from application context. [The constructive consumer](playground/interface_lab/src/consumers/resource_authorization.gleam) checks resource/scopes and early denial; [the negative identity consumer](playground/interface_lab/negative/web_identity_as_grant.gleam) rejects a Warden identity in place of a Relay grant.
- These prototype signatures describe configured assertions and pure policy. Bearer verification, HTTP challenges, and production trust-origin policy remain requirements rather than demonstrated behavior.

```gleam
pub fn admit(
  verifier: Verifier(principal),
  token: BearerToken,
  protection: ProtectionConfig,
) -> Result(GrantedRequest(principal), AdmissionError)

pub fn dispatch_granted(
  registry: ProtectedRegistry(context, principal),
  context: context,
  grant: GrantedRequest(principal),
  name: String,
  input: value.Value,
) -> Result(value.Value, ProtectedDispatchError)
```

### 2.8 Client authorization

- MCP client authorization owns protected-resource discovery, authorization-server selection and migration, issuer-bound credentials, incremental scopes, resource indicators, and bounded retries. Warden's web-login flow does not replace these rules.
- Retain authorization-code PKCE, client credentials, static bearer, and private-key-JWT configuration targets. Registration modes retain pre-registration, dynamic registration where permitted, and client metadata documents according to the pinned revision and server metadata.
- The flow resolves challenge, RFC 9728 resource metadata, RFC 8414 authorization metadata or permitted OIDC fallback, registration, authorization, and token exchange. Interactive authorization remains an application callback.
- State, PKCE verifier, callback issuer, resource, and selected authorization server must stay bound to the flow. Reject forged or replayed state, unsupported PKCE, and issuer mismatch before accepting credentials.
- Token storage remains pluggable with memory and file-backed targets. Refresh rotation must be persisted before use; concurrent authentication failures must coalesce rather than start duplicate flows.
- Step-up after insufficient scope remains required behavior. DPoP, mTLS, and workload identity remain later explicit extensions rather than implicit support.

### 2.9 Errors, progress, and cancellation

- Error families retain protocol, transport, authorization, capability mismatch, version mismatch, decode failure, timeout, and cancellation. Exceptional output or error encoding must produce sanitized protocol failure rather than fabricated success.
- Application tool failure is a successful JSON-RPC result marked `isError: true`. Invalid arguments and unknown methods remain protocol failures rather than ordinary tool output.
- Progress requires the invocation's retained token and monotonically increasing nonnegative values; no progress follows completion or close. Fractional progress remains a wire-number integration obligation.
- Modern HTTP progress uses the request's SSE response stream rather than a subscription channel. Closing that stream signals cancellation; stdio uses its revision-defined cancellation notification.
- Legacy cancellation tests retain cancel-before-start, mid-flight, after-completion, and prohibited initialize cancellation cases. Runtime interruption must follow revision-specific response behavior rather than assume one cancellation rule across transports.
- Cancellation is not rollback or proof of absent external effects. Side-effecting handlers require their own idempotency, receipt, or reconciliation contract where that distinction matters.

## 3. Library capability contracts

### 3.1 Server

- Server construction retains typed contextual tool registration, metadata, annotations, input/output schemas, and handlers. Dynamic add/remove must emit revision-supported list-change notifications after accepted registry changes.
- Resources retain list/read, URI templates, subscriptions, updates, list-change notifications, and completion. Prompts retain list/get, argument completion, and list-change notifications.
- Logging retains set-level and notification behavior. Pagination retains opaque cursors, invalid-cursor outcomes, and exhaustive traversal; protected cursors must bind catalog revision, grant, tenant context, and visible view.
- Modern cache fields, multi-round input, completion, subscriptions, and change notifications remain full server scope. The current terminal listing page with private zero-TTL cache metadata does not establish pagination or cache ownership.
- Handler facilities retain progress, logging, cancellation observation, client information, and authorization access. Sampling, roots, and elicitation callbacks remain capability-checked typed interactions under revisions or extensions that define them.
- Elicitation retains accepted, declined, and cancelled outcomes with form decoding and URL mode where supported. No deprecated server-initiated capability is silently reintroduced into the modern wire contract.

### 3.2 Client

- The client retains typed method/result pairs, typed tool references, raw calls, discovery, and version admission. Structured output, content-only output, and tool failure remain distinct call outcomes.
- Client capabilities retain tool listing, cursor traversal, resource reading and subscription, completion, log-level setting, ping, close, and registered sampling/roots/elicitation handlers.
- Correlation, timeout, cancellation, response bounds, reconnection, and server-era pinning require behavioral tests. A provider's older handshake support does not establish modern compatibility.

### 3.3 Public test kit

- Downstream callers must be able to use paired transports, a fake clock, scripted peers, fixtures, and a configurable authorization server serving metadata and JWKS. The test kit must reproduce malformed-peer and timing behavior without becoming an alternative protocol authority.
- Tasks and Apps remain later typed extensions with explicit module boundaries and pinned requirements. Experimental status does not remove their retained scope.

## 4. Validation plan

### 4.1 Evidence layers

| Layer            | Retained obligation                                                                             | Current evidence boundary                                                                 |
| ---------------- | ----------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Static           | Gleam checks, formatting, public-boundary review, negative native type fixtures                 | Contextual tools and grants have constructive and compiler-negative laboratory consumers  |
| Codec            | Revision round trips, wire snapshots, negative decoding, official schema validation             | Modern parsed-value responses have frozen-schema checks; complete byte codecs remain open |
| Pure transitions | Server/client lifecycle, OAuth flow, SSE state, exchange correlation                            | Modern exchange histories are demonstrated; copied state does not prove runtime ownership |
| Integration      | In-memory, stdio, real HTTP, authorization, cleanup                                             | No complete live Relay transport or authorization claim                                   |
| Conformance      | Independent server/client and authorization frozen requirement runs for each supported revision | Selected fixtures and development scenarios do not satisfy this gate                      |
| Interoperability | TypeScript/Python peers in both directions and Inspector smoke                                  | Retained validation backlog                                                               |
| Robustness       | Malformed-input fuzzing, churn, cancellation storms, bounded memory/processes                   | Retained runtime backlog                                                                  |

### 4.2 Frozen acceptance and drift

- Conformance for `2026-07-28` requires its frozen requirement set with no expected-failures claim. Compatibility must independently pass its own frozen `2025-11-25` set at the corresponding wire revision.
- The baseline's expected-failure file may serve only as development debt: additions need an issue, passing entries must be removed, and it must not be presented as conformance. This replaces the baseline's weaker milestone acceptance wording without removing feature scope.
- Server and client jobs remain independent, with a separate authorization job. Harness invocation and everything-client integration belong in one tooling adapter pinned to the selected harness interface.
- Traceability must identify requirements without scenarios; local codec, transition, and integration tests must cover those gaps. A clean harness run certifies only its covered behavior.
- A scheduled latest-harness drift check and generated-schema comparison remain CI requirements, separate from pinned acceptance. The baseline's nightly interoperability, soak/fuzz, and fourteen-green-night hardening target remain release-validation backlog rather than freeze prerequisites.

### 4.3 Scenario provenance and negative tests

| Source or risk                  | Required scenarios                                                                                                                                                                                                                   |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| TypeScript authorization        | Resource-to-AS discovery order and fallback, authorization URL state/PKCE/resource/scope, unsupported PKCE per revision, private-key JWT, bounded repeated-401 behavior                                                              |
| TypeScript transport and output | Chunked SSE, reconnect/event IDs, JSON-only responses, era-specific server modes, Origin/Host validation, output-schema validation, form/URL elicitation, sampling, tasks                                                            |
| Python runtime                  | Host/Origin matrix including missing Origin and wildcard mistakes, session idle/max/lifecycle limits, modern versus legacy lifecycle, callback types, legacy browser CORS headers, in-memory client/server parity                    |
| Anubis reference                | Static/dynamic registration, list-change notifications, contextual scopes and visibility, version negotiation, typed unsupported revisions, supervision and reconnect behavior; inspect tests before treating them as a test oracle  |
| Resource authorization          | Wrong issuer/audience/expiry/signature/key, 401 challenge metadata, insufficient-scope step-up, rotation without refresh storms, no token passthrough, sender-constraint and replay rejection when shipped                           |
| Gleam codecs                    | Every type/revision round trip, reviewed snapshots, official schema checks, optional versus nullable, boundary numbers, malformed/duplicate members, invalid/missing fields, unknown extension policy                                |
| JSON-RPC and lifecycle          | Zero/string IDs, repeated IDs across exchanges, unknown responses, invalid notification shapes, malformed or oversized frames, unknown methods/notifications, revision-specific batching, early/double initialize, capability gating |
| Exchange ownership              | Immediate-response reuse, close before admission, simultaneous equal wire IDs, old completion after identifier reuse, cancellation and progress suppression, output/error encoding failure                                           |
| Progress and paging             | Token correlation, monotonicity, fractional numbers, invalid/stale/authorization-mismatched cursors, complete traversal, no notifications after terminal output                                                                      |
| Transport                       | Every SSE event-boundary disconnect, ordered nonduplicated reconnect delivery, partial UTF-8, large stdio lines, child exit, stderr isolation, bounded buffers, cleanup and backpressure                                             |
| OAuth and security              | Forged/replayed state, callback issuer mismatch, credential issuer binding, refresh rotation, concurrent 401 coalescing, malicious server discovery, protected-route bypass, token redaction                                         |
| Runtime                         | Session churn, parallel calls, cancellation storms, supervisor isolation, bounded mailbox/process counts, owner termination, timeouts, stale callback isolation                                                                      |

- Port scenarios and assertions with provenance; inspect licenses before copying source. The baseline's TypeScript/Python observations and uninspected Anubis feature descriptions have different evidence strength.
- Blueprint owns schema-law and exact-number validation within its schema/value model. Relay proves that schema-aware declarations preserve those contracts on the wire; ordinary revision codecs retain independent numeric and roundtrip obligations.
- Pure core tests retain the baseline Erlang/JavaScript cross-target ambition when that target is enabled. OTP 27/28 CI, reference-peer interoperability, and release hardening require actual implementation compatibility evidence.

### 4.4 Demonstrated subset and remaining work

- [Contextual registry evidence](playground/interface_lab/README.md) establishes heterogeneous native handlers and explicit application context. [Resource authorization](playground/interface_lab/RESOURCE-AUTHORIZATION.md) adds admission, protected resource/scope rechecks, visibility, and execution ordering.
- [Relay exchanges](playground/interface_lab/RELAY-EXCHANGES.md) demonstrates one pure authoritative history with distinct exchange and invocation identities. It establishes neither concurrent actor ownership nor one-time handler execution.
- [Modern Relay](playground/interface_lab/MODERN-RELAY.md) demonstrates parsed-value discovery, protected listing and call, immediate exchange ownership, modern complete results, and sanitized errors. Cursors and continuation parameters are explicitly rejected in that subset.
- [Frozen schema validation](playground/interface_lab/oracles/mcp_2026/README.md) checks emitted fixture structure and negative required-field mutations. It does not test byte parsing, HTTP, cryptographic verification, live cleanup, or complete MCP conformance.
- Implementation proceeds through the remaining modern server requirements, client, client authorization, stdio, and legacy compatibility. The freeze starts no additional interface-refinement wave; a real implementation caller mismatch is required to reopen the public surface.

## 5. Baseline capability disposition and friction

| Baseline capability                                                       | Disposition                                                                                                                                             | Remaining friction                                                                                                                 |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| Typed core, JSON-RPC, capabilities, ping, lifecycle                       | Retained with explicit modern and legacy strategies                                                                                                     | Baseline modern-draft/handshake assumptions are obsolete                                                                           |
| Schema/codec/value DSL and generation                                     | JSON Schema-aware contracts reassigned to Blueprint; protocol generation deferred tooling                                                               | Blueprint exact numbers apply to schema-aware values; ordinary protocol JSON stays independent                                     |
| Tools, annotations, structured output/output schema, all content variants | Retained; contextual registry and narrow modern calls demonstrated                                                                                      | Rich results, output declarations, protocol-specific admission remain partial                                                      |
| Resources, templates, subscriptions, updates, completion                  | Retained backlog                                                                                                                                        | Revision-specific wire and runtime behavior unimplemented                                                                          |
| Prompts, argument completion, change notifications                        | Retained backlog                                                                                                                                        | Full typed family and fixtures unimplemented                                                                                       |
| Logging, pagination, progress, cancellation, metadata                     | Retained; narrow progress/cancel/meta demonstrated                                                                                                      | Fractional numbers, paging, live interruption, and cache semantics remain open                                                     |
| Sampling, roots, form/URL elicitation                                     | Retained as revision-scoped compatibility or extensions                                                                                                 | Deprecated features cannot be assumed present in modern protocol                                                                   |
| Server/client, typed tool references, raw escape hatch                    | Retained; current facade is server subset                                                                                                               | Client correlation, callbacks, and outcome compatibility remain open                                                               |
| Stdio, HTTP both roles, in-memory                                         | Retained backlog                                                                                                                                        | Modern POST-only and legacy session/resumption behavior need separate adapters                                                     |
| Resource-server and MCP client authorization                              | Retained; grant policy demonstrated                                                                                                                     | Real verification, challenges, client flows, trust-origin policy remain open                                                       |
| Optional sender constraints, tasks, Apps, workload identity               | Deferred explicit extensions                                                                                                                            | Consumer and pinned requirement needed before implementation claims                                                                |
| Older revisions and deprecated HTTP+SSE                                   | Older supported targets deferred; dual-endpoint transport remains optional                                                                              | Separate lifecycle/codec acceptance required; pre-2025-03-26 remains excluded                                                      |
| Public test kit and complete validation plan                              | Retained                                                                                                                                                | Fixture success must not be reported as live or full conformance                                                                   |
| Eight proposed Relay distribution packages                                | Initially one Relay distribution with internal module boundaries; later physical split deferred pending target, dependency, or release-cadence evidence | Packaging changes only; no capability reassignment or removal, including pure-core separation and deferred JavaScript verification |
| Dual-target core                                                          | Deferred baseline ambition                                                                                                                              | Initial package is Erlang-target; JS requires separate verification                                                                |

- No requested baseline feature family is silently dropped. Superseded wire forms remain attached to their applicable revision; the current modern subset does not erase compatibility or full server/client obligations.
- Unresolved decisions include principal vocabulary and verifier-origin reuse, anonymous policy, protected cursor identity, scope normalization, resource-owner retention bounds, and runtime transport selection. Their partial status must remain visible through implementation.

## 6. Pinned sources and authority

- [Protocol and authorization research](research/protocol-auth-boundaries.md), [server contract](research/relay-server-contract.md), and [resource authorization contract](research/relay-resource-authorization-contract.md) record the accepted boundaries and source evidence.
- MCP `2026-07-28` is pinned at `5f5440bb26a62e2cf3440b92da5a667efa03b267`, MIT; its TypeScript schema is authoritative. The frozen JSON schema hash is `ef70b61f99b6d2e5e3b46863822eab08dff6a45bedc7a08914e0e5b133f40203`, verified before fixture validation.
- Conformance `0.2.0-alpha.10` is the frozen requirement release anchor. Inspected source `7169291ec0b68eb370fddcd9947313ab0d5e4156` reports `0.2.0-alpha.11`, MIT; preserve the distinction rather than silently changing the acceptance pin.
- Official TypeScript `2.0.0` is pinned at `cc4b41617ce3601b1290d67216ea0b194a3cd9ac`; Python `2.0.0` is pinned at `6f69a3758ebf2ee55ce050f58b470ce11af71133`. They are scoped implementation oracles, while the specification and frozen requirements decide wire correctness.
- `mcp_toolkit` `0.3.1` is pinned at `7085e9dd64490d06e338935b3f497b85bb82d068`, Apache-2.0; `mcp_client` `0.1.0` is pinned at `8dce5d3819bd8ac0cccadc68bb8b3773398ba38f`, Apache-2.0. Their older protocols supply reference scenarios rather than inherited conformance.
- Anubis's baseline README reported LGPL-v3 and its test tree remained uninspected. Retain source provenance and resolve license terms before copying tests; no unrecorded source revision is invented here.
- The `2025-11-25` compatibility fixture and requirement run need their own recorded pins before conformance claims. Historical unpinned SDK examples and auth-glue references remain research context rather than acceptance oracles.
