# `relay` — a Gleam MCP implementation — Target Design, Library API, and Validation Plan

Status: draft v0.1 · Audience: library authors and reviewers · Date: 2026-09-19

> All Gleam code below is design-level pseudocode. It has not been compiled. Names and signatures are proposals meant to be argued with.

---

## 0. Summary

A feature-complete Model Context Protocol implementation for Gleam: **server and client**, **stdio and Streamable HTTP**, an **OAuth 2.1 auth layer** on both sides, and a validation plan anchored on the official **`@modelcontextprotocol/conformance`** suite plus scenarios ported from the Anubis (Elixir), Python, and TypeScript SDKs.

Three design commitments drive everything else:

1. **Types over strings.** The wire format is stringly typed; the library is not. Strings exist only inside per-revision codec modules and at the HTTP header edge.
2. **Sans-IO core, thin runtime.** All protocol logic (lifecycle, correlation, cancellation, auth flows) is pure `state × input → state × effects`. OTP actors and HTTP servers are shells around it.
3. **Spec revisions are data.** Protocol version is a first-class type, and lifecycle (stateful handshake vs. stateless per-request `_meta`) is a strategy chosen per version.

### Non-goals

- Wrapping or generating LLM-provider clients.
- Reimplementing a full OAuth _authorization server_ (we implement the MCP-relevant client and resource-server roles; an AS is out of scope, though a test AS is part of the test kit).
- Supporting the deprecated HTTP+SSE dual-endpoint transport as a first-class citizen (Anubis 2.x removed it; we ship it, if at all, as an optional `relay_compat_sse` package).
- Supporting spec revisions older than 2025-03-26 (the same floor Anubis 2.x adopted).

---

## 1. Landscape and lessons

| Project                             | What we take                                                                                                                                                                                        | What we avoid                                                                                               |
| ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `mcp_toolkit` (Gleam)               | Server builder shape; stdio + Mist transports; Birdie snapshot habit                                                                                                                                | Public API uses raw JSON strings for tool schemas and string-typed content discriminators (`type_: "text"`) |
| `mcp_client` (Gleam)                | Port-based stdio with large line buffer (truncation is a real bug class)                                                                                                                            | stdio only; 2024-11-05 spec                                                                                 |
| Anubis (Elixir)                     | OTP-per-session design; compile-time component registration idea; auth context passed to handlers; scope-aware tool visibility; clean deprecation policy (floor spec version, majors drop versions) | Auth split across two packages with an impedance mismatch at the frame boundary                             |
| Official TypeScript / Python SDKs   | Test scenarios (§7), transport/session manager semantics (idle timeout, max sessions, resumability), DNS-rebinding protection                                                                       | Dynamic typing of tool arguments                                                                            |
| `@modelcontextprotocol/conformance` | The acceptance gate (§7.2)                                                                                                                                                                          | —                                                                                                           |

Design consequence of the conformance suite: it distinguishes the **stateful lifecycle** (initialize handshake, dated revisions through 2025-11-25) from the **stateless lifecycle** (2026 draft, per-request `_meta`). The session state machine must therefore be parameterized, not hard-wired.

---

## 2. Target design

### 2.1 Package layout (monorepo, path deps during development)

```
relay_core         Pure. Erlang + JavaScript targets.
                   Types, codecs, Schema DSL, JSON-RPC, versions, capabilities,
                   sans-IO session state machines, auth flow state machines.
relay_server       Builder, registries, OTP runtime (Erlang target).
relay_client       Client actor, correlation, server-request handlers (Erlang target).
relay_stdio        Transport (both roles).
relay_http         Streamable HTTP: server side on mist, client side on an HTTP client.
relay_auth         OAuth 2.1 resource-server + client; verifiers, stores, providers.
relay_testkit      In-memory transport, fake clock, scripted peers, test AS/JWKS, fixtures.
relay_conformance  everything_server + everything_client executables, baseline, CI glue.
```

Dependency direction is strictly downward. `relay_core` performs no I/O and starts no processes, so it stays target-agnostic and cheaply testable.

### 2.2 Type-safety rules

Rule: _a `String` or `Dynamic` in a public signature needs a written justification in the doc comment._

| Wire concept                                        | Representation                                                                            |
| --------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Method name                                         | `MethodName` ADT (`Initialize`, `Ping`, `ToolsList`, `ToolsCall`, …, `Extension(String)`) |
| JSON-RPC id                                         | `RequestId { IntId(Int) StringId(String) }`                                               |
| Progress token                                      | opaque `ProgressToken`                                                                    |
| Protocol version                                    | ordered ADT: `Rev20250326 \| Rev20250618 \| Rev20251125 \| Rev20260728`                   |
| Content block                                       | `Text \| Image \| Audio \| ResourceLink \| EmbeddedResource`                              |
| Role, log level, stop reason                        | ADTs                                                                                      |
| Error code                                          | `ErrorCode` ADT with `Custom(Int)`                                                        |
| Binary payloads                                     | `BitArray`; base64 only inside codecs                                                     |
| URIs                                                | `gleam/uri.Uri` wrapped in opaque `ResourceUri`; URI templates parsed into segments       |
| Names, cursors, session ids                         | opaque types with validating constructors                                                 |
| Scopes, bearer tokens, PKCE verifier, OAuth `state` | opaque types (`Scope`, `BearerToken`, `CodeVerifier`, `OAuthState`)                       |
| Capabilities                                        | records of typed sub-capabilities, not maps                                               |

**Where dynamism is unavoidable** it is contained in one small type, `JsonValue` (null/bool/int/float/string/array/object), used only for: `_meta`, extension capabilities and methods, untyped-tool arguments/results, and JSON Schema keywords the library does not model. `Dynamic` never appears in a public signature.

### 2.3 `Schema(a)`: one definition, three outputs

Hand-written decoders next to hand-written JSON Schema drift. A single `Schema(a)` value yields the decoder, the encoder, and the JSON Schema document (for `tools/list` `inputSchema`/`outputSchema`, and for elicitation forms).

```gleam
pub type SearchArgs { SearchArgs(query: String, limit: Option(Int)) }

pub fn search_args() -> Schema(SearchArgs) {
  use query <- schema.field("query", schema.string() |> schema.min_length(1), fn(a: SearchArgs) { a.query })
  use limit <- schema.optional("limit", schema.int_range(1, 50), fn(a) { a.limit })
  schema.success(SearchArgs(query:, limit:))
}

schema.decoder(search_args())   // decode.Decoder(SearchArgs)
schema.encoder(search_args())   // fn(SearchArgs) -> Json
schema.document(search_args())  // JsonSchema (ADT), serialized only at the codec edge
```

`JsonSchema` is itself an ADT (object/array/string/number/enum/oneOf/…) with an `Unmodelled(JsonValue)` escape hatch. Codecs for protocol types use the same `Schema` machinery, so protocol types and user types share round-trip tests.

Constraint (honest limitation): Gleam has no derive/macros, so schemas are written by hand. Mitigation: `gleam run -m relay_gen` (optional dev tool) generates _protocol_ types and codecs from the official spec schema per revision, and CI diffs generated vs. committed output to catch drift.

### 2.4 Typed requests without GADTs

Gleam has no GADTs or type classes. A method value that carries its own codecs gives typed request/response pairing:

```gleam
pub type Method(params, result) {
  Method(name: MethodName, params: Codec(params), result: Codec(result))
}

pub const tools_call: Method(CallToolParams, CallToolResult) = ...
pub const resources_read: Method(ReadResourceParams, ReadResourceResult) = ...

pub fn request(c: Client, m: Method(p, r), params: p) -> Result(r, McpError)
```

Direction is encoded too: `ClientMethod(p, r)` vs. `ServerMethod(p, r)`, so a server cannot accidentally "send" `tools/call`.

### 2.5 Sans-IO core

```gleam
// relay_core/session/server.gleam
pub opaque type ServerSession

pub type Input {
  Received(Message)
  HandlerFinished(RequestId, HandlerOutcome)
  TransportClosed
  Tick(Timestamp)
}

pub type Effect {
  Send(Message)
  RunHandler(RequestId, ClientRequest)
  CancelHandler(RequestId)
  EmitLog(LogEvent)
  CloseSession
}

pub fn new(config: ServerSessionConfig) -> ServerSession
pub fn step(s: ServerSession, i: Input) -> #(ServerSession, List(Effect))
```

The same pattern applies to the client session and to the OAuth flow (`auth/flow.step` with `Http(Request)` and `OpenBrowser(Url)` effects). Payoff: the conformance failures, the property tests, and the spec-version matrix all run without sockets or processes.

**Lifecycle strategy** is selected by negotiated version:

```gleam
pub type Lifecycle { Stateful(InitState) Stateless }   // Stateless for Rev20260728
```

Typestate on the public client (`Client` is only obtainable after a successful handshake) removes "called before initialize" as a runtime error class.

### 2.6 OTP runtime (Erlang target)

- **Server:** a supervisor tree per server: `session_registry` → `factory_supervisor` of session actors. Each session actor owns a `ServerSession` and executes its effects.
- **Handlers:** one supervised task per in-flight request. `CancelHandler` kills the task and the runtime replies according to spec (no response for cancelled requests).
- **Server → client requests** (sampling, elicitation, roots): correlation table `Dict(RequestId, Subject(Result(JsonValue, ProtocolError)))` owned by the session, surfaced to handlers as typed `Result`-returning functions.
- **Session policy** (borrowed from the Python manager's behaviour): configurable idle timeout and max concurrent sessions; defaults documented and tested.
- **Client:** one actor owning the transport and correlation table; user-facing calls are `actor.call` with timeouts; server-initiated requests dispatch to registered typed handlers.

### 2.7 Transports

```gleam
pub type Transport {
  Transport(
    send: fn(Outbound) -> Result(Nil, TransportError),
    inbound: Subject(Inbound),
    close: fn() -> Nil,
  )
}
```

- **stdio:** newline-delimited framing; configurable max line size (default large; tested with multi-MB frames); stderr is never protocol data; clean shutdown ordering (close stdin → wait → terminate).
- **Streamable HTTP (server):**
  POST → `application/json` **or** `text/event-stream`; GET opens the server-initiated stream; DELETE ends the session; typed handling of `Mcp-Session-Id`, `MCP-Protocol-Version`, `Accept`, and `Last-Event-ID`; resumability via an `EventStore` interface (in-memory reference implementation); `Origin`/`Host` validation against DNS rebinding with an explicit allow-list config; stateless mode.
- **Streamable HTTP (client):** SSE parser as a pure function (`Bytes -> List(SseEvent)` with carry-over state); reconnect with `Last-Event-ID` and server-provided retry hints; header injection via the auth provider; a bounded "401 → auth → retry once" policy (no auth loops).
- **In-memory:** paired transports in `relay_testkit`, used for client↔server integration tests without sockets.

### 2.8 Auth layer (`relay_auth`)

Auth is a boundary module, not part of the protocol core. Everything is sans-IO plus small pluggable records of functions.

**Resource-server side**

```gleam
pub type AuthOutcome(p) {
  Authenticated(Principal(p))
  Unauthorized(Challenge)                   // 401 + WWW-Authenticate incl. resource_metadata
  Forbidden(InsufficientScope(ScopeSet))    // 403
}

pub type Verifier(p) = fn(BearerToken, ResourceUri) -> Result(Principal(p), VerifyError)
```

- Verifiers shipped: JWT + JWKS (via a JOSE package, with cache/rotation), RFC 7662 introspection, and a static/test verifier.
- Typed RFC 9728 protected-resource metadata document served at the well-known path.
- Audience binding (RFC 8707): tokens must be issued for _this_ resource; no token passthrough to upstream APIs.
- `ScopePolicy = fn(ClientRequest) -> ScopeRequirement` is exhaustive over `ClientRequest`, so adding a method forces a policy decision at compile time.
- Verified principal is exposed as `ctx.auth` to handlers; scope-aware `tools/list` filtering is opt-in (an Anubis-style behaviour).
- Optional sender-constrained tokens (DPoP/mTLS) as a follow-on, gated on demand.

**Client side**

```gleam
pub type AuthProvider {
  AuthProvider(
    credentials: fn(Option(Challenge)) -> Result(Credentials, AuthError),
    on_forbidden: fn(InsufficientScope) -> Result(Credentials, AuthError),  // step-up
  )
}
```

Provided: `static_bearer`, `oauth.authorization_code_pkce`, `oauth.client_credentials`, and a private-key-JWT variant. The interactive step is one callback, `fn(AuthorizationUrl) -> Result(AuthorizationResponse, AuthError)`; `state` and PKCE verification are internal and unforgeable by construction (opaque types).

Discovery flow (state machine): 401 → parse challenge → protected-resource metadata → authorization-server metadata (RFC 8414 and OIDC discovery fallback) → client registration (pre-registered, dynamic registration, or client-metadata-document, per what the AS advertises) → auth request with PKCE `S256` and `resource` → token exchange → retry once. `TokenStore` is a pluggable record (`load`, `save`, `clear`), with in-memory and file-backed implementations.

> Check `conformance list` for the current auth scenarios in your target revision before finalizing the supported client-registration and grant matrix; that set is evolving.

### 2.9 Version negotiation and deprecation policy

- Supported set is explicit (`[Rev20250326, Rev20250618, Rev20251125]` at launch; `Rev20260728` behind a `draft` flag until the harness and the SDK ecosystem stabilize).
- Codecs are per revision (`relay_core/wire/v20250618.gleam`, …) behind a common `Wire` interface; differences (e.g. batching support, field additions) are data in the codec, not `if` statements in handlers.
- Semver: deprecations live ≥ 1 minor; dropping a spec revision is always a major (mirrors Anubis's stated policy).

### 2.10 Error model

```gleam
pub type McpError {
  Protocol(code: ErrorCode, message: String, data: Option(JsonValue))
  Transport(TransportError)
  Auth(AuthError)
  CapabilityNotNegotiated(Capability)
  VersionUnsupported(offered: List(ProtocolVersion))
  DecodeFailed(List(decode.DecodeError))
  Timeout
  Cancelled
}
```

Tool-handler failure is _not_ a protocol error: handlers return `tool.failed(...)` → `isError: true` in the result. Argument decode failure _is_ a protocol error (`InvalidParams`), produced automatically by the registry.

---

## 3. Library API

### 3.1 Server

```gleam
import relay/server
import relay/tool
import relay/schema

pub type Hit { Hit(title: String, uri: ResourceUri) }

pub fn main() {
  let search =
    tool.new(
      name: tool_name("search"),
      input: search_args(),
      output: hits_schema(),
    )
    |> tool.title("Search")
    |> tool.description("Search the index")
    |> tool.read_only()
    |> tool.handle(fn(ctx, args: SearchArgs) {
      server.progress(ctx, progress: 0.5, total: None, message: Some("querying"))
      use hits <- result.try(run_search(args) |> result.map_error(tool.failed))
      tool.ok(hits)                        // structured content + text mirror
    })

  let assert Ok(srv) =
    server.new(info: server.Info("demo", "1.0.0"))
    |> server.versions([Rev20250618, Rev20251125])
    |> server.tool(search)
    |> server.resource_template(docs_template(), read_doc)
    |> server.prompt(summarize_prompt())
    |> server.auth(auth.bearer(jwt_verifier, prm, scope_policy))
    |> server.start()

  http.serve(srv, http.config(port: 3000, path: "/mcp", allowed_origins: [origin("https://app.example")]))
}
```

Type erasure happens once, in the registry: `ErasedTool(descriptor, call: fn(Ctx, JsonValue) -> CallToolResult)`. The decoder inside the closure is the `Schema(args)` decoder, so handlers never see `Dynamic`.

**Handler context (`Ctx`)**

```gleam
pub fn progress(ctx, progress: Float, total: Option(Float), message: Option(String)) -> Nil
pub fn log(ctx, level: LogLevel, data: JsonValue) -> Nil
pub fn is_cancelled(ctx) -> Bool
pub fn auth(ctx) -> Option(Principal(p))
pub fn client_info(ctx) -> Option(ClientInfo)

// server → client, all capability-checked and typed
pub fn sample(ctx, SamplingRequest) -> Result(SamplingResult, McpError)
pub fn elicit(ctx, message: String, form: Schema(a)) -> Result(Elicited(a), McpError)
pub fn list_roots(ctx) -> Result(List(Root), McpError)

pub type Elicited(a) { Accepted(a) Declined Cancelled }
```

**Dynamic registration and notifications**

```gleam
server.add_tool(handle, tool)       // emits tools/list_changed if negotiated
server.remove_tool(handle, name)
server.notify_resource_updated(handle, uri)
```

### 3.2 Client

```gleam
import relay/client

let assert Ok(c) =
  client.new(client.Info("demo-host", "0.1.0"))
  |> client.versions([Rev20251125, Rev20250618])
  |> client.with_sampling(handle_sampling)         // typed SamplingRequest -> Result(SamplingResult, _)
  |> client.with_roots(fn() { [my_root] })
  |> client.with_elicitation(handle_elicit)
  |> client.with_auth(oauth.authorization_code_pkce(oauth_config))
  |> client.connect(http.transport(uri("https://mcp.example/mcp")))
  // connect performs the handshake; a Client value is always "ready"

// Typed call via a client-side tool reference
let search_ref = client.tool_ref(tool_name("search"), search_args(), hits_schema())
let assert Ok(outcome) = client.call(c, search_ref, SearchArgs("gleam", Some(5)))

// Escape hatch: untyped
let assert Ok(raw) = client.call_raw(c, tool_name("search"), json_object([...]))

// Listing, pagination as a typed stream
client.list_tools(c) |> pagination.all()          // follows cursors
client.read_resource(c, uri)
client.subscribe(c, uri, on_update: fn(u) { ... })
client.complete(c, ref, argument)
client.set_log_level(c, Warning)
client.ping(c)
client.close(c)
```

`CallOutcome(out)` is `Structured(out) | ContentOnly(List(Content)) | ToolError(List(Content))`, so the "tool ran and failed" case is distinguishable from transport/protocol errors.

### 3.3 Transports

```gleam
stdio.server()                                    // serve over stdin/stdout
stdio.spawn(command: "my-server", args: [...], env: [...], max_line: 8 * mib)
http.serve(srv, http.config(...))                 // mist
http.transport(url)                               // client
testkit.pair()                                    // in-memory (client_transport, server_transport)
```

### 3.4 Auth

```gleam
// Server
auth.bearer(verifier, prm, scope_policy)
auth.jwt_verifier(issuer: uri, audience: resource_uri, jwks: jwks.cached(uri, ttl))
auth.introspection_verifier(endpoint, client_credentials)
auth.protected_resource_metadata(resource: uri, authorization_servers: [uri], scopes: [...])

// Client
oauth.authorization_code_pkce(oauth.Config(
  client: oauth.Preregistered(id, secret) | oauth.Dynamic | oauth.MetadataDocument(uri),
  redirect: uri("http://127.0.0.1:0/callback"),
  authorize: open_browser_and_wait_for_redirect,
  store: token_store.memory(),
  scopes: [scope("mcp:tools")],
))
oauth.client_credentials(...)
auth.static_bearer(token)
```

### 3.5 Test kit (public, so downstream users can test their own servers)

```gleam
let #(client_t, server_t) = testkit.pair()
testkit.with_fake_clock(fn(clock) { ... clock.advance(minutes(31)) ... })
testkit.scripted_server([ expect_request(Initialize, reply: ...), ... ])
testkit.test_authorization_server()       // issues JWTs, serves metadata + JWKS, configurable misbehaviour
```

---

## 4. Validation plan

### 4.1 Test pyramid

| Layer             | What                                                                                                                                         | Tools                               | Runs on         |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------- | --------------- |
| L0 Static         | Type-level guarantees, `gleam format --check`, `gleam check`, no-`Dynamic`-in-public-API lint (script over `gleam export package-interface`) | gleam CLI                           | every PR        |
| L1 Codec          | Round-trip properties for every protocol type; snapshot of wire JSON; negative decoding                                                      | `qcheck`, `birdie`, `gleeunit`      | Erlang + JS     |
| L2 State machines | Deterministic tests of `step` for server session, client session, SSE parser, OAuth flow                                                     | `gleeunit`, table-driven            | Erlang + JS     |
| L3 Integration    | Client↔server over in-memory, stdio, and real HTTP; auth end to end with the test AS                                                         | `gleeunit`, `relay_testkit`         | Erlang          |
| L4 Conformance    | Official harness against `everything_server` / `everything_client`                                                                           | `@modelcontextprotocol/conformance` | Erlang, CI      |
| L5 Interop        | Our client ↔ reference TS/Python servers; reference clients ↔ our server; MCP Inspector smoke                                                | npm/uv in CI                        | Erlang, nightly |
| L6 Robustness     | Fuzzing malformed frames, soak (many sessions, cancel storms), memory/leak checks on session churn                                           | `qcheck`, custom load driver        | nightly         |

### 4.2 Conformance gate (L4)

```
# server
npx @modelcontextprotocol/conformance server --url http://localhost:3000/mcp \
    --suite all --expected-failures conformance-baseline.yml

# client (harness launches our everything_client with the scenario)
npx @modelcontextprotocol/conformance client \
    --command "gleam run -m everything_client" \
    --suite all --expected-failures conformance-baseline.yml

# auth suite separately, so auth regressions are visible on their own
npx @modelcontextprotocol/conformance client --command "gleam run -m everything_client" --suite auth
```

Policy:

- **Baseline is a debt list, not a config.** `conformance-baseline.yml` may only shrink; a PR that adds an entry needs a linked issue. CI fails if a baselined scenario starts passing (so the entry gets removed).
- **Scheduled run against `@latest`** (weekly) opens/updates a tracking issue when new or changed scenarios fail; this is how spec drift surfaces.
- **Both modes are run as separate jobs**; a passing server does not excuse a failing client.
- **Per-protocol-version matrix:** run the suite once per supported revision (stateful revisions and, behind a flag, the stateless draft).
- **Traceability:** use the harness's traceability output (requirements-by-SEP, tested vs. untested) to see which spec requirements no scenario exercises, and cover those gaps with our own L1–L3 tests.
- The exact scenario-passing contract for the everything-client (env vars/args) comes from the harness's SDK integration guide; encode it in one place (`relay_conformance/harness.gleam`).

### 4.3 Borrowed tests: sources and how to port them

**Method.** Port _scenarios and assertions_, not code. Check each source's license before copying anything: the Python and TypeScript SDKs are open source (the Python SDK is MIT-licensed), while Anubis's README states LGPL-v3. Reimplementing the scenario in Gleam from its description is safe; copying test source is not, without a license review.

**Provenance note.** The TypeScript and Python items below come from test files, PR diffs and docs I could see. I could **not** inspect Anubis's `test/` tree (the site blocked automated access), so Anubis rows are derived from its documented features. Before implementing, read its `test/` directory and reconcile this table.

#### A. From the TypeScript SDK (client auth, transport)

| Scenario                                                                                                                                                                                     | Source area                             | Gleam test                                                           | Layer |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- | -------------------------------------------------------------------- | ----- |
| Authorization-server discovery order: RFC 9728 metadata → RFC 8414 → OIDC fallback; 4xx on a candidate continues to the next                                                                 | `client/auth.test.ts`                   | `oauth_discovery_test` (table of mocked responses)                   | L2    |
| Authorization URL contains `code_challenge` (S256), `resource`, `scope`, `state`; honours metadata `authorization_endpoint` for both OAuth and OIDC metadata                                 | `client/auth.test.ts`                   | `oauth_authorize_url_test`                                           | L2    |
| **No infinite auth loop:** 401 after a _successful_ auth flow surfaces an error instead of re-authenticating                                                                                 | `client/streamableHttp.test.ts`         | `client_http_401_after_auth_test`                                    | L3    |
| Metadata advertising unsupported PKCE method: assert current spec behaviour (the TS test for this was changed during spec evolution, so re-derive from the current spec, don't blindly port) | `client/auth.test.ts` history           | `oauth_pkce_method_test`                                             | L2    |
| Streamable HTTP client: reconnect with `Last-Event-ID`, JSON-only responses, SSE parsing across chunk boundaries                                                                             | `client/streamableHttp.test.ts`         | `sse_parser_property_test`, `client_resume_test`                     | L2/L3 |
| Server transport: stateless mode (no session tracking), JSON-only response mode, GET+SSE server notifications                                                                                | server streamable-HTTP tests / examples | `http_server_modes_test`                                             | L3    |
| DNS-rebinding protection with allow-listed hosts/origins                                                                                                                                     | server transport options                | `http_origin_host_test`                                              | L3    |
| Structured output validated against `outputSchema`                                                                                                                                           | example + tests                         | `tool_output_schema_test`                                            | L3    |
| Elicitation form + URL mode; sampling; tasks (experimental)                                                                                                                                  | examples                                | `elicit_form_test`, `elicit_url_test`, `sampling_test`, `tasks_test` | L3    |
| JWT-based client authentication (private-key JWT)                                                                                                                                            | `auth-extensions`                       | `oauth_private_key_jwt_test`                                         | L2    |

#### B. From the Python SDK

| Scenario                                                                                                                                                                    | Source area                                     | Gleam test                                                                                                | Layer |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------- | --------------------------------------------------------------------------------------------------------- | ----- |
| Host/Origin security matrix for Streamable HTTP (allowed, wrong host, wrong origin, missing origin, wildcard misconfig)                                                     | `tests/server/test_streamable_http_security.py` | `http_security_matrix_test` (table-driven, one row per case)                                              | L3    |
| Session manager: idle timeout closes a stateful session (default 30 min), max concurrent sessions enforced, single `run()` per manager, manager not reusable after shutdown | `streamable_http_manager`                       | `session_registry_idle_test` (fake clock), `session_registry_max_test`, `session_registry_lifecycle_test` | L3    |
| Stateless flag starts the session as already initialized                                                                                                                    | server session                                  | `stateless_lifecycle_test`                                                                                | L2    |
| Sampling callback returns typed result; client callbacks for roots/elicitation                                                                                              | client session tests                            | `client_callbacks_test`                                                                                   | L3    |
| CORS: `Mcp-Session-Id` must be exposed to browser clients                                                                                                                   | docs/tests                                      | `http_cors_headers_test`                                                                                  | L3    |
| Client/server parity tests (every client method against a real server over in-memory pipes)                                                                                 | `tests/` (client+server)                        | `interop_inmemory_test`                                                                                   | L3    |

#### C. From Anubis (verify against its `test/` tree first)

| Scenario                                                                                                                              | Basis                                 | Gleam test                 | Layer |
| ------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------- | -------------------------- | ----- |
| Static component registration and dispatch to the right handler                                                                       | Component registration model          | `registry_dispatch_test`   | L2    |
| Dynamic tool registration at runtime + `list_changed`                                                                                 | Frame-based runtime registration      | `dynamic_tools_test`       | L3    |
| Auth context visible to handlers; scope helpers; scope-aware tool visibility (tools hidden from `tools/list` when scopes are missing) | Documented frame/context auth helpers | `scope_visibility_test`    | L3    |
| Client `protocol_version` option: requesting an older/newer revision negotiates correctly, mismatch is a typed error                  | client options                        | `version_negotiation_test` | L2/L3 |
| Deprecation behaviour: removed transports/versions fail with a clear typed error                                                      | changelog policy                      | `unsupported_version_test` | L2    |
| Supervision: session crash does not take down the server; client actor restarts and re-initializes                                    | OTP design                            | `supervision_chaos_test`   | L6    |

#### D. From the auth ecosystem (resource-server behaviour)

Modelled on what MCP-auth glue libraries handle at the HTTP boundary:

| Scenario                                                                                          | Gleam test                                |
| ------------------------------------------------------------------------------------------------- | ----------------------------------------- |
| Unauthenticated request → 401 with `WWW-Authenticate` carrying a `resource_metadata` pointer      | `rs_challenge_test`                       |
| Token with wrong issuer / audience / expired / bad signature / unknown `kid` → 401 (parametrized) | `rs_token_rejection_matrix_test`          |
| Token audience-bound to another resource is rejected (RFC 8707)                                   | `rs_audience_test`                        |
| Insufficient scope → 403 with required scopes; client step-up succeeds after re-consent           | `rs_scope_403_test`, `client_stepup_test` |
| JWKS rotation: new `kid` triggers refresh once, no refresh storm                                  | `jwks_rotation_test`                      |
| Token is never forwarded to downstream/upstream requests (passthrough prevention)                 | `rs_no_passthrough_test`                  |
| (If DPoP/mTLS shipped) bound token presented as plain Bearer is rejected; replay rejected         | `rs_sender_constrained_test`              |

### 4.4 Tests we write ourselves (Gleam-specific risks)

1. **Codec round-trip properties** for every protocol type on every supported revision: `decode(encode(x)) == x`; and _cross-revision_ checks that fields absent in an older revision are omitted/tolerated as that revision specifies.
2. **Wire snapshots (Birdie)** for one canonical message per type per revision; PRs must review snapshot diffs.
3. **Spec-schema validation:** validate our encoder's output against the official spec JSON Schema for the matching revision, using a small Node script invoked in CI (Gleam lacks a mature JSON Schema validator, so do this out-of-process as a test-only step).
4. **`Schema(a)` laws:** decoder accepts exactly what `document` describes (generated valid/invalid samples per keyword: min/max, enum, oneOf, optional vs. nullable).
5. **JSON-RPC edge cases:** id `0`, string ids, duplicate ids in flight, response to unknown id, notification with id, malformed JSON mid-stream, oversized frame, unknown method (→ `MethodNotFound`), unknown notification (ignored), batching decoded only on revisions that allow it.
6. **Lifecycle ordering:** requests before `initialize` rejected (stateful), `ping` allowed early, double `initialize`, version-negotiation fallback, capability gating (calling `sample` without client sampling capability yields `CapabilityNotNegotiated`).
7. **Cancellation:** cancel before start, mid-flight, after completion (no-op), cancel of `initialize` (not permitted), handler killed and no response emitted.
8. **Progress:** token uniqueness, monotonic progress, notifications stop after completion.
9. **Pagination:** cursor opacity, invalid cursor → `InvalidParams`, exhaustive traversal helper.
10. **SSE resumability:** kill the connection at every event boundary in a stream; the reconnecting client must deliver each event exactly once, in order.
11. **stdio:** multi-MB line, partial reads split mid-UTF-8, child exit mid-request, stdout noise handling (protocol vs. logging separation), graceful shutdown ordering.
12. **OAuth state machine:** replayed/forged `state` rejected; verifier never leaves the flow; refresh-token rotation persisted before use; concurrent 401s coalesce into a single flow.
13. **Concurrency soak:** N sessions × M concurrent requests with random cancellations; assert no leaked processes, bounded mailbox growth, and correct correlation.
14. **Cross-target:** the L1/L2 suites run on both Erlang and JavaScript targets for `relay_core`.

### 4.5 CI layout

```
jobs:
  lint            gleam format --check, gleam check, public-API lint
  unit-erlang     gleam test (core, server, client, auth)      matrix: OTP 27, 28
  unit-js         gleam test --target javascript (core only)
  integration     stdio + HTTP + auth against test AS
  conformance-server   (per supported protocol revision)
  conformance-client   (per supported protocol revision) + auth suite
  interop         TS + Python reference peers               (nightly)
  soak/fuzz       (nightly)
  spec-drift      conformance @latest + generated-types diff (weekly, opens issue)
```

### 4.6 Exit criteria per milestone

| Milestone                   | Scope                                                                                             | Gate                                                                                                  |
| --------------------------- | ------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| **M1** Core                 | Types, `Schema`, codecs (Rev20250618), JSON-RPC, session state machines                           | L0–L2 green on both targets; snapshot set reviewed; spec-schema validation green                      |
| **M2** stdio E2E            | Server + client over stdio; tools/resources/prompts; progress/cancel/logging/pagination           | L3 stdio suite; conformance server subset that is stdio-agnostic in the in-memory harness             |
| **M3** HTTP                 | Streamable HTTP both roles; resumability; origin protection; stateless mode; more revisions       | Conformance **server** `--suite all` with a shrinking baseline; port groups A/B tests                 |
| **M4** Auth                 | Resource server + OAuth client flows; test AS                                                     | Conformance **client** `--suite auth` green; group D tests green                                      |
| **M5** Full client features | Sampling, roots, elicitation (form/URL), completion, subscriptions, tasks (if in target revision) | Conformance client `--suite all`; baseline empty or ≤ documented, issue-linked entries                |
| **M6** Hardening            | Soak/fuzz, JS-target core, docs, examples, 1.0 API freeze                                         | Nightly green for 14 days; traceability shows no untested requirement without a written justification |

### 4.7 Definition of "feature complete" (checklist)

- [ ] Lifecycle: version + capability negotiation, ping, stateful and stateless
- [ ] Tools: list/call, list-changed, annotations, structured output + output schema, resource links, embedded resources, image/audio content
- [ ] Resources: list/read, templates, subscribe/updated, list-changed, completion
- [ ] Prompts: list/get, list-changed, arguments completion
- [ ] Logging: set level + notifications
- [ ] Utilities: pagination, progress, cancellation, `_meta` handling
- [ ] Client features: sampling, roots, elicitation (form; URL mode where the target revision defines it)
- [ ] Transports: stdio, Streamable HTTP (+ resumability, stateless, origin protection)
- [ ] Auth: RS challenge/metadata/verification/scopes; client discovery/registration/PKCE/step-up/refresh
- [ ] Conformance: server and client suites, all supported revisions, baseline documented
- [ ] Experimental features (e.g. tasks) behind an explicit `experimental` module boundary

---

## 5. Risks and open questions

| Risk / question                                                                         | Mitigation / next step                                                                                                                   |
| --------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Spec moving (2026 draft with stateless lifecycle; TS/Python SDKs are in v2 transitions) | Version-as-data design; draft behind a flag; weekly spec-drift job                                                                       |
| No JSON Schema validator in Gleam                                                       | Model the subset we emit; validate output out-of-process in CI; `Unmodelled` escape hatch                                                |
| Hand-written codecs drift from spec                                                     | `relay_gen` from official schema + CI diff                                                                                               |
| Gleam ecosystem gaps (JOSE, SSE client, HTTP client streaming)                          | Prefer existing packages; isolate each behind a small interface so replacement is cheap; vendor a minimal SSE parser (pure, well-tested) |
| Dual-target ambition (Erlang + JS) stretching scope                                     | Only `relay_core` is dual-target; runtime packages are Erlang-first                                                                      |
| Conformance auth scenario set changes                                                   | Keep auth behind provider records; run `--suite auth` as its own job                                                                     |
| Licensing of borrowed tests                                                             | Port scenarios, not code; record provenance per test in a header comment (`Scenario inspired by: <project>/<file>`)                      |
| Anubis test tree not yet reviewed                                                       | First task of M1: read it and reconcile table 4.3-C                                                                                      |

---

## 6. Sources consulted

- Gleam ecosystem: `mcp_toolkit` (hexdocs / GitHub), `mcp_client` (hexdocs), Gleam package index
- Anubis MCP: <https://github.com/zoedsoupe/anubis-mcp>, <https://hexdocs.pm/anubis_mcp/readme.html>
- MCP auth glue for Elixir (`attesto_mcp`): <https://hex.pm/packages/attesto_mcp>
- Conformance harness: <https://github.com/modelcontextprotocol/conformance> (server/client modes, `--suite`, `--expected-failures`, traceability, SDK integration guide)
- Python SDK: <https://github.com/modelcontextprotocol/python-sdk>, session manager docs at <https://py.sdk.modelcontextprotocol.io/>
- TypeScript SDK: <https://github.com/modelcontextprotocol/typescript-sdk> (auth/streamable-HTTP tests via PRs #945 and #992; server examples README)
