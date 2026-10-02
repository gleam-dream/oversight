# relay — API card

## Health

- Head: `906e1ac fix: admit described Blueprint schemas in Relay tools` (`/code/gleam-dream/relay`, master).
- Gate, run through `nix develop --command` on 2026-10-01:

| Command                                      | Result                                                               |
| -------------------------------------------- | -------------------------------------------------------------------- |
| `gleam format --check src test`              | pass                                                                 |
| `gleam build`                                | pass (`--warnings-as-errors` also passes)                            |
| `gleam test`                                 | **fail: 136 passed, 2 failures**                                     |
| `python3 scripts/check_negative_fixtures.py` | pass                                                                 |
| `python3 scripts/relay_schema_check.py`      | pass                                                                 |
| `./scripts/verify_checksums.sh`              | **fail**: frozen MCP schema checksum passes; sibling pin check fails |

- Both failures have one cause: `provenance_test.sibling_blueprint_pin_test` and `sibling_sinal_pin_test` compare `../json_blueprint` and `../sinal` git heads with `sibling-revisions.txt` (`ecf5c60`, `13105bb`). The siblings have moved to `129c963` and `8acec45`. No functional test failed. The pin is a release-provenance check, so the failure means "re-pin or revert the siblings", not a behavior regression.
- `./scripts/conformance/run-server-suite.sh` (needs the npm conformance package) and `nix flake check` were not run. The README reports a previous result of 109 passed checks and 0 failures over 40 scenarios.
- An external consumer package (scratchpad, path dependency, public imports only) compiled and ran the common path below over real HTTP and printed `Hello, Ada!`.
- No `TODO`/`FIXME` in `src/`. Open items from `README.md`, `CHANGELOG.md`, `REVIEW-STATUS.md`:
  - Path dependencies on `../json_blueprint` and `../sinal`; a standalone checkout or Hex install cannot resolve. CI checks out only Relay, so a green hosted run is not established.
  - Both bundled listeners are unprotected; authorization primitives are not wired into any transport.
  - Deferred: legacy `2025-11-25`, `logging/setLevel`, resource-read continuation, RFC 9728 metadata/challenges, client authorization, Tasks/Apps, public test kit, direct TS/Python client fixtures.
  - Working tree also carries `WAVE-1..4-{PROGRESS,REPORT}.md`, `REVIEW-STATUS.md` and an `erl_crash.dump` at the root.

## Purpose and scope delivered vs design

Relay implements the frozen MCP `2026-07-28` revision on Erlang. It ships a pure server reducer (`server.step`), an OTP runtime for custom transports, a stdio server, a Streamable HTTP server on mist with Host/Origin and size/timeout policy, and a typed client over raw gun (HTTP) or a child process (stdio). Tools are defined once with Blueprint codecs and reused for registration and typed calls. Resources, templates, prompts, completion, progress, multi-round input (`InputRequired`), subscriptions (`subscriptions/listen`) and dynamic tool registration are present on both sides. The design (`relay-design.md` §2.6–§3.3, §5) still holds these capabilities that the implementation lacks:

- **Resource-server authorization on a transport**: bearer extraction, RFC 9728 metadata, `WWW-Authenticate` challenges, insufficient-scope mapping. Only the pure `relay/authorization` primitives exist.
- **Client authorization** (§2.8): PKCE, client credentials, static bearer, private-key JWT, discovery, token storage, step-up. The client cannot even attach a header today.
- **Legacy `2025-11-25`** codec and session transport (GET stream, DELETE, resumability, `Last-Event-ID`).
- **Logging** (`logging/setLevel`, log notifications; `relay/logging` is only a level enum), ping/cancel from the client, client-side registered sampling/roots/elicitation handlers (the app answers `InputRequired` manually).
- **Protected pagination/cursors** bound to grant and tenant; resource-read continuation.
- **Public test kit** (paired in-memory transports, fake clock, scripted peers, test authorization server) and Tasks/Apps extensions.
- **Supervision integration** (child specs) and a mountable HTTP handler; see Lifecycle.

## Public modules

| Module                     | Responsibility                                                                                                                                   |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `relay/tool`               | `ToolName`, `Definition(input, output)`, `ContentDefinition(input)`, metadata/annotations, eight `handle_*` binders, `Registry`, `dispatch*`     |
| `relay/server`             | `Server(context)` description plus reducer state, service modifiers, `step`, `Invocation`/`perform`, exchange ids, HTTP admission helpers        |
| `relay/runtime`            | OTP actor that owns invocations, timeouts, crash isolation and live-exchange bounds for a custom transport (`RuntimeConfig`, `RuntimeOutput`)    |
| `relay/transport/http`     | `HttpListener` description, `HttpOptions`, `HttpPolicy`, `start`/`stop_http_server`, notifications, dynamic register/unregister                  |
| `relay/transport/stdio`    | Framer, writer, `run_local_unprotected_stdio_server` (blocking server over stdin/stdout)                                                         |
| `relay/client`             | HTTP and stdio client config, connect, discovery, listings, typed/discovered/content calls, resume, resources, prompts, completion, `listen`     |
| `relay/resources`          | `ResourceUri`, static resources, URI templates (built-in or caller matcher)                                                                      |
| `relay/prompts`            | Prompt declarations, arguments, simple and multi-round handlers                                                                                  |
| `relay/completion`         | Completion refs/values and handler wrappers                                                                                                      |
| `relay/content`            | `ContentBlock` (text/image/audio/resource link/embedded), `Annotations`, `Role`                                                                  |
| `relay/subscriptions`      | `SubscriptionFilter` for `subscriptions/listen`                                                                                                  |
| `relay/authorization`      | Bearer/resource/scope values, `Verifier`, `admit`, `GrantedRequest`, `ToolPolicy`, `ProtectedRegistry`, `dispatch_granted` (not transport-wired) |
| `relay/telemetry`          | Sinal event descriptors and the `emit_*` helpers the runtime uses                                                                                |
| `relay/logging`            | `LogLevel` enum, `permits`, parse/name (no protocol method)                                                                                      |
| `relay/protocol/jsonrpc`   | `RequestId`, `ProgressToken`, `RpcError`, standard codes                                                                                         |
| `relay/protocol/revision`  | `ProtocolRevision`, supported version strings                                                                                                    |
| `relay_conformance_server` | Top-level `main` for the conformance suite; shipped in `src/`, so it is part of the published package                                            |

`relay/internal/*` is declared internal in `gleam.toml`.

## Common path

Verified from an external consumer package (public imports only):

```gleam
pub fn main() {
  let assert Ok(name) = tool.tool_name("greet")
  let assert Ok(greet) =
    tool.definition(name, codec.field("name", codec.string()), codec.string())
  let greet = greet |> tool.with_description("Greets a user by name")
  let bound = tool.handle(greet, fn(who) { Ok("Hello, " <> who <> "!") })
  let assert Ok(registry) = tool.registry([bound])
  let assert Ok(running) =
    http.listener(server.server(registry), fn() { Nil }) |> http.start
  let port = int.to_string(http.http_server_port(running))
  let assert Ok(config) = client.http_config("http://127.0.0.1:" <> port <> "/")
  let assert Ok(peer) = config |> client.with_timeout(5000) |> client.connect_http
  case client.call_definition(peer, greet, "Ada") {
    client.StructuredSuccess(text, _content) -> io.println(text)
    client.ToolFailure(_content) -> io.println("tool reported isError")
    client.TransportFailure(_reason) -> io.println("transport failure")
    _other -> io.println("protocol or input failure")
  }
  client.close(peer)
  http.stop_http_server(running)
}
```

Imports: `json/blueprint/codec`, `relay/{client, server, tool}`, `relay/transport/http`. The same `greet` definition drives listing, server decode/encode, and client encode/decode.

## Configuration and advanced paths

- **Tool definitions**: `tool.definition` (structured) and `tool.content_definition` (content only). Modifiers: `with_description`, `with_title`, `with_annotations` (`empty_annotations |> with_read_only_hint(Some(True))`; `None` omits, `Some(False)` publishes false), `with_required_client_capabilities`, `with_metadata`/`content_with_metadata`, `with_input_schema_override`/`content_with_input_schema_override` (discovery schema only; the codec still decodes).
- **Handlers**: `handle`, `handle_with_error_renderer` (publish a caller-rendered message), `handle_advanced` (gets `HandlerCallContext(application, input_responses, report_progress)`, returns `Complete | Content | NeedsInput`), and the same four for content-only tools.
- **Server services**: `server.with_resources`, `with_resource_templates`, `with_prompts`, `with_completion(Option(_))`. `resources.resource_template_with_matcher` accepts a caller matcher.
- **Dispatch override**: `server.with_dispatch(server, fn(Registry, context, ToolName, Value, Option(Value), ProgressReporter) -> Result(ToolOutput, DispatchError))` receives the live registry on every call; this is the only interception point for authorization or middleware.
- **Dynamic tools**: `server.register_tool`/`unregister_tool` (pure), `runtime.register_tool`, `http.register_tool`/`unregister_tool` (live, emit list-changed); `http.notify_*_list_changed`, `notify_resource_updated`.
- **HTTP listener**: `http.listener(server, fn() -> context)` defaults to `127.0.0.1:0` with `local_http_policy`. `with_options(HttpOptions(port, host))`, `with_policy(HttpPolicy(max_body_bytes, max_response_bytes, request_timeout_ms, sse_keepalive_ms, allowed_hosts, allowed_origins))`, `with_tls(certfile, keyfile)`. Widening the bind never widens the Host/Origin policy; `start` validates everything before allocating.
- **Stdio server**: `stdio.default_stdio_config()` (`chunk_size`, `runtime_config`) then `run_local_unprotected_stdio_server(server, config, context)`.
- **Custom transport**: `runtime.start(server, RuntimeConfig, sink)` with `send_frame`, `exchange_closed`, `close`, `stop`; or drive `server.step`/`server.perform` directly.
- **Client config**: `client.http_config(url)` (opaque) `|> with_timeout |> with_max_response_bytes |> with_ca_cert_file |> with_input_methods([Elicitation, Sampling, Roots]) |> with_listing_limits`; `client.stdio_config(exe, args)` is a public record updated by field.
- **Discovered and raw calls**: `client.list_tools` gives `client.ToolDeclaration` with `json.Json` schemas; `call_discovered(peer, declaration, blueprint Value)` returns `ToolCallOutcome(Value)`; `raw_json_call` covers uncovered methods; `list_*_json` returns checked JSON strings.
- **Input rounds**: `InputRequired(continuation, requests)` then `resume_tool(continuation, Dict(String, json.Json))`; no automatic responder.

## Lifecycle and supervision

- **Processes started**: `http.start` starts a mist supervisor plus a subscription hub actor, and **one runtime actor per HTTP POST**. `runtime.start` starts an actor that spawns a monitored worker per invocation. `run_local_unprotected_stdio_server` blocks the calling process and starts a writer and runtime. `client.connect_http` opens one gun connection per `Client`; `listen` spawns an SSE reader process. `connect_stdio` starts an actor that owns the child port.
- **No supervision integration.** No module exposes a child spec, `supervised`, or factory builder. `http.start` explicitly calls `process.unlink(started.pid)` (`src/relay/transport/http.gleam:489`), so the listener survives caller death and must be stopped by hand with `stop_http_server`. Siblings expose supervision (`http_gun.child`, `warden.supervised`).
- **Not mountable.** The request handler (`handle_request`, `src/relay/transport/http.gleam:518`) is private; Relay owns the listener and port. An application cannot mount MCP at `/mcp` inside an existing mist or wisp router, share TLS/port, or put its own middleware in front. `server.http_admission_failure` and `http_custom_headers_valid` are exposed but are not a handler.
- **Cleanup owner**: the caller. `http.stop_http_server` stops hub then supervisor; `client.close` closes gun or the child; `client.close_subscription` stops the SSE reader; `runtime.stop`/`close` for custom transports. An `InputRequired` continuation holds the client, so the caller must keep the peer open until the terminal outcome.

## Failure model

- **Definition time**: `ToolNameError` (`EmptyName | NameTooLong | InvalidCharacters`), `ToolAdmissionError` (`MissingInputSchema | InputSchemaMustBeObject(String) | MissingOutputSchema | UnsupportedSchemaFeature(String)`), `RegistryError` (`DuplicateToolName | InvalidToolDeclaration`), `TemplateError`.
- **Server dispatch**: `DispatchError` (`UnknownTool | InvalidInput(DecodeError) | PublicApplicationFailure(String) | ContentOnlyOutput | InvalidOutput(EncodeError) | InputRequiredOutput`). Application errors are erased at bind time to a fixed message or a caller-rendered string; they become `isError: true` results.
- **Startup**: `runtime.RuntimeStartError` and `RuntimeConfigError(field, value)` are structured; `stdio.StdioError` is structured; **`http.start` returns `Result(HttpServer, String)`** with three fixed messages.
- **Client tool calls (well structured)**: `ToolCallOutcome` = `StructuredSuccess | ContentOnlySuccess | InputRequired | ToolFailure(content) | ProtocolFailure(String) | TransportFailure(TransportError) | InputEncodingFailure | InvalidInputResponses`; `TransportError` = `ConnectionClosed | RequestCancelled | RequestTimedOut | ResponseLimitExceeded | TransportFault(String)`. `ContentCallOutcome` mirrors it with `Content*` names.
- **Client everything else (stringly)**: `discover`, `list_*`, `read_resource`, `get_prompt`, `complete`, `listen`, `raw_json_call` return `Result(_, String)`; timeouts, closures, JSON-RPC errors and HTTP statuses are indistinguishable without parsing. `ClientError` is `InvalidClientConfiguration | ConnectionFailed(String)`.
- **Authorization**: `AdmissionError`, `GrantUseError`, `ProtectedDispatchError(GrantUseFailed | Inaccessible(cause) | InvocationFailed(DispatchError))`; unknown/hidden/denied causes stay distinct internally.

## Composition seams

- **json_blueprint (mandatory for every tool).** Every `ContextTool` comes from a `handle_*` over a `Definition`/`ContentDefinition`, both of which require a Blueprint `Codec` with an object-root schema (`src/relay/tool.gleam:249,308`). There is no constructor from a plain `json.Json` schema plus a `gleam/dynamic/decode` decoder, and `with_dispatch` cannot add undeclared tools to listings. Blueprint `Value` also appears in non-schema positions: `HandlerCallContext.input_responses: Option(Value)` (`tool.gleam:447-452`), `call_discovered` arguments, `with_input_schema_override(Value)`. Meanwhile `InputRequest.params` and `resume_tool` responses use `json.Json`. Blueprint on the tool path matches the guideline (tools are JSON Schema paths); mixing `Value` and `json.Json` for ordinary protocol JSON does not.
- **warden / authorization.** Warden is an OIDC relying party: it yields `VerifiedIdentity` and `AccessToken` with `authorization_header(token) -> #(String, String)`; it has no resource-server bearer verification. Relay's `authorization.verifier(name, version, fn(BearerToken) -> Result(VerifierAttestation(p), VerificationError))` is the slot for a JWT/JWKS or introspection verifier (e.g. built on gose), not for Warden. Today it cannot plug into a transport: `http.listener` builds context from `fn() -> context` (`src/relay/transport/http.gleam:58`) with no access to the request, so no `Authorization` header reaches `admit`; `dispatch_granted` (`src/relay/authorization.gleam:264`) returns only `Value` and drops content, progress and input rounds, so it cannot back `server.with_dispatch`. On the client side, `HttpClientConfig` has no header hook, so `warden.authorization_header` cannot be attached. Needed seams: a per-request context builder `fn(Request(_)) -> Result(context, Response)` (or a mountable handler), protected dispatch that returns `ToolOutput`, and a client header or token-provider hook.
- **http_gun (client transport).** The client uses a private gun FFI (`src/relay_gun_ffi.erl`) with one connection per `Client`, its own SSE parser, TLS via `cacerts_get`/`cacertfile`, no pooling, no destination policy, no cassettes, no correlation ids and no sinal events. Moving POST calls to `http_gun` would give shared pools across llm_wire and relay, recorded MCP exchanges for tests, a single TLS/destination/egress policy, and consistent transport telemetry. Two prerequisites: http_gun must support long-lived streamed SSE responses with backpressure and cancellation for `subscriptions/listen` and request-scoped progress, and Relay's `TransportError` classes must map from http_gun's failure type. Recommendation: move it; it is the more composable choice once http_gun's streaming API covers SSE. Stdio stays separate.
- **sinal.** `relay/telemetry` defines seven events, emitted only by the server runtime and stdio framer: `[relay, frame, rejected]` (exchange_id, reason), `[relay, request, admitted]` (exchange_id, method), `[relay, invocation, started]` (exchange_id, invocation_id, `tool_name`), `[relay, invocation, completed]` (measurement `duration_ms`; exchange_id, invocation_id, `status` = "success"/"error"), `[relay, invocation, cancelled]`, `[relay, invocation, crashed]` (reason), `[relay, exchange, closed]`. None from the HTTP listener (body limits, Host/Origin rejections), the client, or authorization. `invocation.started.tool_name` actually carries the JSON-RPC method (`src/relay/runtime.gleam:525-529`), so no event identifies the tool.
- **llm_wire / fabric.** All three packages define tools from Blueprint codecs but share no type: `relay/tool.definition(ToolName, Codec, Codec)` returns `Result`; `fabric/tool.define(String, String, Codec, Codec)` is infallible with a required description; `llm_wire` `tool_from_codec(name, description, input_codec)`/`tool_from_contract`. Exposing a local Relay tool to a model works by reusing the same codecs (`tool.definition_input_codec`). Exposing a remote MCP tool to a model goes `client.list_tools` -> `ToolDeclaration.input_schema: json.Json` -> Blueprint runtime contract -> `llm_wire.tool_from_contract`, and the model's arguments go back through `call_discovered(Value)`. That adapter (schema re-parse, name re-admission, `ToolCallOutcome` -> fabric `Failure` classification where `TransportFailure(RequestTimedOut)` must be `Uncertain`) belongs in fabric or the application; no package provides it yet.

## Ergonomics concerns

1. **Eight overlapping binder functions.** `handle`, `handle_with_error_renderer`, `handle_advanced`, `handle_advanced_with_error_renderer`, and four `handle_content*` twins (`src/relay/tool.gleam:498-690`), plus parallel `content_with_metadata`/`with_metadata`, `content_with_input_schema_override`/`with_input_schema_override`, `content_definition_name`/`definition_name` (`tool.gleam:258-342`). Guideline: "Avoid overlapping constructor families for the same operation." The error renderer is an independent choice and could be a modifier on the bound tool or an optional field; content-only could be an output mode of one `Definition`.
2. **Common path needs two fallible steps before any behavior.** `tool.tool_name` then `tool.definition` both return `Result` (`tool.gleam:28,308`); every example opens with two `let assert`. Siblings take the name as a `String` (`fabric/tool.define`). Folding name validation into `definition` gives one error and one step.
3. **Stringly-typed client errors outside tool calls.** `discover`, `list_tools`, `read_resource`, `get_prompt`, `complete`, `listen` return `Result(_, String)` (`src/relay/client.gleam:665,714,1047,1067,1090,1131`); `ProtocolFailure(reason: String)` (`client.gleam:426`), `ConnectionFailed(String)` (`client.gleam:323`), `http.start -> Result(_, String)` (`src/relay/transport/http.gleam:430`). Guideline: callers must distinguish deadline, closure, size and protocol outcomes without parsing. `TransportError` already exists and should be reused.
4. **Dynamic leak.** `Discovery.capabilities: Dynamic` (`client.gleam:335`). Guideline: do not spread `Dynamic` through ordinary callers. Use a typed capabilities record or `json.Json` like the declarations do.
5. **No supervision and no mountable handler.** `http.start` unlinks the listener (`http.gleam:489`), there is no child spec, and the handler is private (`http.gleam:518`). Compare `http_gun.child` and `warden.supervised`. The request-blind `fn() -> context` (`http.gleam:58`) also blocks per-request auth and tenancy.
6. **Server module mixes description, mutable reducer state and transport helpers.** `Server(context)` holds `exchanges`, `subscriptions` and a random `cursor_key` (`src/relay/server.gleam:474-520`), so `server.server(registry)` is not a pure description and a "description" value carries live state. HTTP-only helpers `http_admission_failure`/`http_custom_headers_valid` (`server.gleam:53,84`) and a raw `exchange_id(n: Int)` constructor for an opaque id (`server.gleam:39`) sit in the same public module. Guideline: group modules by owned decisions.
7. **Name collisions and sibling inconsistencies.** Two `ToolDeclaration` types with different shapes (`tool.gleam:424` vs `client.gleam:363`), two `Annotations` (`content.gleam:25` vs `client.gleam:353`), two `Resource` (`resources.gleam:33` vs `authorization.gleam:13`), two `UnknownTool` constructors (`tool.gleam:488` vs `authorization.gleam:153`). Lifecycle names are prefixed (`http.http_server_port`, `http.stop_http_server`, `stdio.run_local_unprotected_stdio_server`) where siblings use `start`/`stop`/`child`. `relay/telemetry` publishes its `emit_*` helpers (`src/relay/telemetry.gleam:195-258`), which should be internal. `relay_conformance_server` ships as a top-level public module.
8. **Config shape is inconsistent between client transports.** `HttpClientConfig` is opaque with builders (`client.gleam:41`); `StdioConfig` is a public record updated by field (`client.gleam:288`); input methods and listing limits are set differently for each.
