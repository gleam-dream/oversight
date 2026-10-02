# relay — release API review

Reviewed 2 October 2026 against `/code/gleam-dream/relay` at `5caff50`. Inputs
were the [relay design](../../relay-design.md), the
[API card](../composition/scan/relay.md), the
[cross-package review](../composition/FEEDBACK.md) and the secure_mcp (SMCP-_)
and tool_hub (TH-_) findings. A scratch consumer of stub modules confirmed that
the proposed tool, server, http and client shapes compile (marked "probe").

## 1. Verdict

Relay is not release-ready as an API. Its protocol core is sound, but the
surface is the largest in the ecosystem (227 functions, 17 modules, 46 public
records), and about a third of it is twin families or machinery: `handle_*` ×8,
`content_*`, `dispatch_*` ×4, `list_*_json` ×4, `emit_*`, the stdio framer,
`*_to_json`, and a shipped conformance `main`. The biggest problems block real
deployments: the HTTP endpoint cannot be mounted and its context cannot see the
request (SMCP-2); the client cannot send headers or cancel a call, and its
timeout leaves the server working (SMCP-6, TH-2); and client failures arrive as
`String` or `Dynamic`, dropping the JSON-RPC code, HTTP status and send evidence
(TH-4).

## 2. First ten minutes

Main job: serve a typed tool over HTTP and call it with the same definition.

<table>
<tr><th>Today (card common path; compiles at 5caff50)</th><th>Proposed (probe)</th></tr>
<tr><td>

```gleam
import json/blueprint/codec
import relay/client
import relay/server
import relay/tool
import relay/transport/http

let assert Ok(name) = tool.tool_name("greet")
let assert Ok(greet) =
  tool.definition(name, input_codec, codec.string())
let greet = tool.with_description(greet, "Greets")
let bound = tool.handle(greet,
  fn(who) { Ok("Hello, " <> who <> "!") })
let assert Ok(registry) = tool.registry([bound])
let assert Ok(running) =
  http.listener(server.server(registry),
    fn() { Nil })
  |> http.start
let port = http.http_server_port(running)
let assert Ok(config) = client.http_config(url(port))
let assert Ok(peer) = client.connect_http(config)
case client.call_definition(peer, greet, "Ada") {
  client.StructuredSuccess(text, _) -> ok(text)
  client.ToolFailure(_) -> tool_error()
  client.TransportFailure(_) -> transport()
  _ -> protocol_or_input()  // 5 more variants
}
client.close(peer)
http.stop_http_server(running)
```

</td><td>

```gleam
import json/blueprint/codec
import relay/client
import relay/http
import relay/server
import relay/tool

let assert Ok(greet) =
  tool.define("greet", input_codec, codec.string())
let greet = tool.with_description(greet, "Greets")
let assert Ok(service) =
  server.new([tool.handle(greet,
    fn(who) { Ok("Hello, " <> who <> "!") })])
let assert Ok(running) =
  http.start(http.new(service))
let port = http.port(running)
let assert Ok(config) = client.http(url(port))
let assert Ok(peer) = client.connect(config)
case client.call(peer, greet, "Ada") {
  Ok(client.Completed(text, _)) -> ok(text)
  Ok(client.ToolFailed(..)) -> tool_error()
  Ok(client.InputRequired(..)) -> needs_input()
  Error(e) -> fail(client.describe_error(e))
}
client.close(peer)
http.stop(running)
```

</td></tr>
</table>

| Count                           | Today                               | Proposed                       |
| ------------------------------- | ----------------------------------- | ------------------------------ |
| Relay imports (plus `codec`)    | 4                                   | 4                              |
| Relay types touched             | 10                                  | 8                              |
| Relay calls                     | 15                                  | 12                             |
| Fallible steps (`let assert`)   | 6                                   | 5                              |
| Outcome cases                   | 8 variants, 3 of them prose         | 3 outcomes + one typed `Error` |
| Server-only stdio path (README) | 8 calls, 3 asserts, 3 relay imports | 4 calls, 3 asserts, 3 imports  |

The stdio path drops from `tool_name`, `definition`, `with_description`,
`handle`, `registry`, `server.server`, `default_stdio_config`,
`run_local_unprotected_stdio_server` to `define`, `handle`, `server.new`,
`stdio.serve`. Three imports are the floor for an MCP server (§6).

## 3. Target surface

| Module (today → proposed)               | Decision               | Key types and functions after                                                                                                                                                                                                                                                                                                                         |
| --------------------------------------- | ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `relay/tool`                            | keep, shrink           | `Definition(i, o)`, `DefineError`, `define`, `define_content`, `with_*` (description, title, four hints, capabilities, input schema, icons, meta), `name`, `input_codec`, `output_codec`, `Tool(ctx)`, `handle`, `handle_with_error_renderer`, `handle_call`, opaque `Call(ctx)`, `Reply(o)`, `ToolError`, `Declaration`, `DispatchError`, `dispatch` |
| `relay/server`                          | description only       | `Server(ctx)`, `new(tools)`, `with_resources`, `with_prompts`, `with_completion`, `with_dispatch`, `register_tool`, `unregister_tool`, `ServerError`, `describe_error`                                                                                                                                                                                |
| `relay/reducer` (new, from `server`)    | advanced machinery     | `State(ctx)`, `init`, `step`, `perform`, `Input`, `Effect`, `Invocation` accessors, `ExchangeId`, `InvocationId`                                                                                                                                                                                                                                      |
| `relay/runtime`                         | keep                   | opaque `Config` + setters, `start`, `supervised`, `send_frame`, `exchange_closed`, `close`, `stop`, `notify(rt, Notification)`, `register_tool`, `unregister_tool`, `StartError`                                                                                                                                                                      |
| `relay/transport/http` → `relay/http`   | keep, flatten          | `Listener(ctx)`, `new`, `new_with_context`, policy setters, `with_tls`, `with_protection`, `start`, `supervised`, `stop`, `port`, `handler`, `notify`, `register_tool`, `unregister_tool`, `StartError`                                                                                                                                               |
| `relay/transport/stdio` → `relay/stdio` | keep, flatten, shrink  | `serve`, `serve_with`, opaque `Config`, `StdioError`; framer, writer, `stream_read_loop`, `log_stderr` → internal                                                                                                                                                                                                                                     |
| `relay/client`                          | keep, one error        | `Config` (`http`, `stdio`, shared setters, `with_headers`), `connect`, `close`, `call`, `call_with`, `call_discovered`, `resume`, `discover`, `capability`, `list_*` ×4, `list_raw`, `call_raw`, `read_resource`, `get_prompt`, `complete`, `listen`, `next_notification`, `Error`, `describe_error`                                                  |
| `relay/resources`                       | merge entry types      | opaque `Resource(ctx)` for static and template entries, one set of `with_*`                                                                                                                                                                                                                                                                           |
| `relay/prompts`                         | symmetric binders      | opaque `Prompt(ctx)`, `prompt`, `prompt_call`, `PromptResult`, `PromptMessage`, `PromptError`                                                                                                                                                                                                                                                         |
| `relay/completion`                      | one constructor        | opaque `Completion(ctx)`, `completion`, `Values`                                                                                                                                                                                                                                                                                                      |
| `relay/content`                         | spec-exact             | `ContentBlock` (+ `meta`), spec `Annotations`, `text`/`image`/`audio`/`resource_link`/`embedded`                                                                                                                                                                                                                                                      |
| `relay/authorization`                   | readable, wired        | value readers, `verifier`, `admit`, `challenge`, `resource_metadata`, `tool_policy`                                                                                                                                                                                                                                                                   |
| `relay/telemetry`                       | descriptors only       | seven `*_event()` descriptors and metadata records; `emit_*` → internal                                                                                                                                                                                                                                                                               |
| `relay/testing` (new)                   | add (design §3.3)      | `connect(server, context) -> client.Client` over paired in-memory transports                                                                                                                                                                                                                                                                          |
| `relay/subscriptions`                   | merge                  | `client.listen(peer, List(Notification))` replaces `SubscriptionFilter`                                                                                                                                                                                                                                                                               |
| `relay/logging`                         | internal until shipped | no protocol method uses it; return as `server.with_logging` with `logging/setLevel`                                                                                                                                                                                                                                                                   |
| `relay/protocol/jsonrpc`, `…/revision`  | internal               | `RpcError` fields move into `client.Error`; `Revision20251125` is unimplemented                                                                                                                                                                                                                                                                       |
| `relay_conformance_server`              | delete from `src/`     | move to `dev/` so it is not published                                                                                                                                                                                                                                                                                                                 |

| Count                        | Before | After (estimate)                                                                     |
| ---------------------------- | -----: | ------------------------------------------------------------------------------------ |
| Public modules               |     17 | 14 (13 kept or reshaped, plus `testing`)                                             |
| Public functions             |    227 | about 185, after adding mount, supervision, headers, cancel, auth wiring and testing |
| Public records (single ctor) |     46 | about 22 (read-only protocol data, telemetry metadata)                               |
| Opaque types                 |     29 | about 33 (configs, `Call`, `ToolError`, service entries)                             |
| Public unions and enums      |     47 | about 30                                                                             |

## 4. Proposals

Ranked by user impact. Relay is unreleased, so "breaks" costs only the two apps
and the README.

### RELAY-R1 Mountable HTTP handler with a request-aware context (L, breaks)

- **Problem.** `http.listener(server, context: fn() -> context)` never sees the
  request (`http.gleam:59`) and `handle_request` is private (`http.gleam:518`).
  secure_mcp re-implemented the buffered handler in 114 lines and lost
  Host/Origin policy, header checks, status mapping, SSE and 5caff50's
  disconnect cancellation (SMCP-2, theme 7). `server.http_admission_failure`
  and `http_custom_headers_valid` (`server.gleam:53,84`) are fragments of that
  handler.
- **Sketch.** `start` becomes `handler` plus `mist.start`; the `Error` branch
  answers 401/403 before Relay reads the body; the `server` HTTP helpers go
  internal.

  ```gleam
  pub fn new(server: Server(Nil)) -> Listener(Nil)
  pub fn new_with_context(server: Server(ctx),
    context: fn(Request(mist.Connection)) -> Result(ctx, Response(mist.ResponseData)),
  ) -> Listener(ctx)
  pub fn handler(listener: Listener(ctx)) -> Result(Handler(ctx), StartError)
  pub fn handle(handler: Handler(ctx), request: Request(mist.Connection))
    -> Response(mist.ResponseData)
  ```

### RELAY-R2 One typed client error; calls return `Result` (M, breaks)

- **Problem.** Ten operations return `Result(_, String)`
  (`client.gleam:665-1215`): a 401 is `"server discovery returned HTTP 401"`
  (`:673`, SMCP-6), the JSON-RPC error object is checked and dropped
  (`:1604-1612`), and a non-200 `tools/call` without a JSON-RPC body becomes
  `TransportFault("tool call returned HTTP 401")` (`:815-821`). Every gun
  failure maps to `ConnectionClosed` with no send evidence (TH-4).
  `ToolCallOutcome` mixes outcomes and failures in 8 variants (three with
  prose), and `ContentCallOutcome` repeats them. `ClientError` has a `String`
  payload and a field-less `InvalidClientConfiguration`.
  `Discovery.capabilities` is `Dynamic` (`:335`). Elicitation and sampling
  request params reach the client as write-only `json.Json` (`:1738`), so an
  app cannot read the form it must fill.
- **Sketch.** The docs say `Error` may gain variants; callers branch on
  `Evidence` and use `describe_error`.

  ```gleam
  pub type Evidence { NotSent MaybeSent }
  pub type Error {
    InvalidConfig(field: ConfigField)  ConnectFailed(cause: ConnectCause)
    TimedOut(evidence: Evidence)  Cancelled(evidence: Evidence)
    ConnectionClosed(evidence: Evidence)  ResponseTooLarge(limit: Int)
    HttpStatus(status: Int, www_authenticate: Option(String))
    RpcError(code: Int, message: String, data: Option(String))
    MalformedResponse(detail: String)  InvalidArguments(detail: String)
    InvalidInputResponses  ListingLimitExceeded
  }
  pub type ToolResult(o) {
    Completed(output: o, content: List(ContentBlock))
    ToolFailed(content: List(ContentBlock), structured: Option(String))
    InputRequired(continuation: Continuation(o), requests: Dict(String, InputRequest))
  }
  pub fn call(peer: Client, d: Definition(i, o), input: i) -> Result(ToolResult(o), Error)
  pub fn request_params(r: InputRequest, decoder: decode.Decoder(a)) -> Result(a, _)
  pub fn capability(d: Discovery, path: List(String), decoder: decode.Decoder(a)) -> Result(a, _)
  ```

### RELAY-R3 Client headers, per-call cancellation, and a deadline that disconnects (M–L)

- **Problem.** `HttpClientConfig` has no headers (`client.gleam:41-48`), so a
  bearer token cannot be sent (SMCP-6, 109 lines of raw client). No call can
  be cancelled (TH-2). On timeout the FFI calls `gun:cancel`
  (`relay_gun_ffi.erl:84-86,108-110`), which keeps the HTTP/1.1 connection
  open. In MCP 2026-07-28 a closed connection is the only HTTP cancellation, so
  the server keeps working until `client.close` drops every call (FEEDBACK,
  new finding 4). The connection opens with `retry => 0` (`:20`), so one
  server restart kills the `Client` for good.
- **Sketch.** `headers` runs per request, so a refreshing token source plugs
  in. Each in-flight call owns a connection from a small per-client pool;
  timeout or cancel closes it, and the next call reconnects. Headers over plain
  HTTP to a non-loopback host are refused unless explicitly allowed. This is
  the case for moving to http_gun (§7 Q1).

  ```gleam
  pub fn with_headers(config: Config, headers: fn() -> List(#(String, String))) -> Config
  pub fn call_with(peer, d, input, options: CallOptions) -> Result(ToolResult(o), Error)
  pub fn call_options() -> CallOptions
  pub fn with_deadline(options: CallOptions, ms: Int) -> CallOptions
  pub fn with_cancellation(options: CallOptions, token: Cancellation) -> CallOptions
  ```

### RELAY-R4 One fallible definition step, three binders, opaque call context (M, breaks)

- **Problem.** The common path needs `tool_name` then `definition`, two
  `Result`s (`tool.gleam:28,308`; TH-8). There are eight binders
  (`:498-690`), four content twins (`content_with_metadata`,
  `content_with_input_schema_override`, `content_definition_name`,
  `content_definition_input_codec`, `:249-342`) and four dispatch variants
  (`:838-884`); content definitions lack `with_description`. Apps used the
  renderer binders 5 times and plain `handle` once, so error rendering is
  common, but the renderer returns only `String` (TH-9).
  `HandlerCallContext` is a public record (`:447`), so adding the invocation
  id (SMCP-9, TH-7) or a cancellation signal (TH-3) breaks callers.
  `ProgressReporter = fn(Int) -> Nil` (`:469`) cannot send the `total`,
  `message` or fractional progress of `ProgressNotificationParams`.
- **Sketch (probe).** A content-only tool is `Definition(i, List(ContentBlock))`,
  so `handle`, `client.call` and `ToolResult` serve both kinds; this deletes
  `ContentDefinition`, `ContentHandlerResult`, `ContentCallOutcome`,
  `ContentContinuation` and `resume_content`. `ToolName` leaves the public API
  (validated once in `define`, `String` elsewhere). `ToolMetadata` and the
  annotations builder fold into `with_*` hints on `Definition`.

  ```gleam
  pub fn define(name: String, input: Codec(i), output: Codec(o))
    -> Result(Definition(i, o), DefineError)   // InvalidName(..) | InputSchemaNotObject | …
  pub fn define_content(name: String, input: Codec(i))
    -> Result(Definition(i, List(ContentBlock)), DefineError)
  pub fn handle(d: Definition(i, o), handler: fn(i) -> Result(o, e)) -> Tool(ctx)
  pub fn handle_with_error_renderer(d: Definition(i, o),
    handler: fn(i) -> Result(o, e), render: fn(e) -> ToolError) -> Tool(ctx)
  pub fn handle_call(d: Definition(i, o),
    handler: fn(Call(ctx), i) -> Result(Reply(o), ToolError)) -> Tool(ctx)
  pub fn error_message(text: String) -> ToolError
  pub fn error_with(content: List(ContentBlock), structured: Option(json.Json)) -> ToolError
  pub fn report_progress(call: Call(ctx), progress: Float, total: Option(Float),
    message: Option(String)) -> Nil
  pub fn cancelled(call: Call(ctx)) -> process.Selector(Nil)
  ```

### RELAY-R5 Readable authorization values, rendered challenges, protected transport (M values, L wiring; additive)

- **Problem.** `BearerToken`, `Resource` and `Scope` are opaque with no readers
  (`authorization.gleam:8-21`), so a verifier cannot read its own token
  (SMCP-3). RFC 6750 challenges and RFC 9728 metadata are app code (41 lines).
  `dispatch_granted` returns only `Value` (`:264`) and cannot back a server.
  Both bundled listeners are unprotected (design §2.7). `verifier` and
  `trust_verifier(VerifierDeclaration)` overlap (`:105-128`).
- **Sketch.**

  ```gleam
  pub fn token_value(token: BearerToken) -> String
  pub fn scope_name(scope: Scope) -> String
  pub fn resource_uri(resource: ProtectedResource) -> String   // was `Resource`
  pub fn challenge(error: AdmissionError, metadata_url: String) -> #(Int, String)
  pub fn resource_metadata(p: Protection, authorization_servers: List(String)) -> json.Json
  // relay/http
  pub fn with_protection(l: Listener(ctx), verifier: Verifier(p), protection: Protection,
    policy: ToolPolicy(ctx, p),
    context: fn(Request(mist.Connection), GrantedRequest(p)) -> Result(ctx, Response(_)),
  ) -> Listener(ctx)
  ```

### RELAY-R6 Lifecycle: supervision, plain names, typed start error (M, breaks)

- **Problem.** `http.start` returns `Result(_, String)` with three fixed
  messages (`http.gleam:434-498`) and unlinks the listener (`:489`), so it
  survives its caller. No child specification exists, and the hub sits outside
  any supervisor. `http_server_port`, `stop_http_server` and
  `run_local_unprotected_stdio_server` differ from the siblings'
  `start`/`stop`/`supervised` (theme 7). `runtime.start` has no supervised
  form.
- **Sketch.** Document ownership: a started listener is linked to its caller
  unless supervised; a client's gun connection closes when the connecting
  process exits; an `InputRequired` continuation needs its peer open.

  ```gleam
  pub type StartError { InvalidConfig(field: ConfigField, value: String)
                        HubFailed(actor.StartError) BindFailed(reason: String) PortNotReported }
  pub fn start(l: Listener(ctx)) -> Result(Running(ctx), StartError)
  pub fn supervised(l: Listener(ctx), name: process.Name(Message(ctx)))
    -> supervision.ChildSpecification(Running(ctx))      // handle resolves by name
  pub fn stop(running: Running(ctx)) -> Nil
  pub fn port(running: Running(ctx)) -> Int
  pub fn serve(server: Server(ctx), context: ctx) -> Result(Nil, StdioError)  // relay/stdio
  ```

### RELAY-R7 Opaque configuration and service entries (M, breaks)

- **Problem.** Callers build these records positionally or by label, so a new
  option breaks them (FEEDBACK, new finding 1): `HttpOptions`, `HttpPolicy`
  (`http.gleam:30-45`), `RuntimeConfig` (`runtime.gleam:12`),
  `client.StdioConfig` (`client.gleam:288`), `ListingLimits`,
  `LocalUnprotectedStdioConfig` (`stdio.gleam:227`), `ToolMetadata`,
  `ToolAnnotations`, `SubscriptionFilter`. `ContextResource`
  (`resources.gleam:62`), `ContextPrompt` (`prompts.gleam:53`) and
  `ContextCompletion` (`completion.gleam:32`) have public function fields, so
  callers can bypass the constructors' error hiding. The two client transports
  are configured differently (opaque config vs record).
- **Sketch.** `http.new(s) |> http.with_max_body_bytes(n)`,
  `runtime.config() |> runtime.with_invocation_timeout(ms)`, and
  `client.http(url)` / `client.stdio(exe, args)` returning one opaque `Config`
  with shared setters and one `connect`. Validation happens once at
  `start`/`connect` and names the failing field.

### RELAY-R8 Hide machinery; ship no executable (S)

No app uses these public items: `telemetry.emit_*` ×7
(`telemetry.gleam:195-258`); the stdio framer, writer, `stream_read_loop` and
`log_stderr` (`stdio.gleam:34-220,453`); 11 `*_to_json` encoders, whose wire
shape the design gives to revision codecs (§0); `server.exchange_id(n)`, a raw
constructor for an opaque id (`server.gleam:39`), and `exchange_is_known`;
`resources.matching_template_reader`, `template_description` and `ResourceUri`,
which no public function accepts; and `relay/protocol/*` and `relay/logging`.
`relay_conformance_server` sits in `src/`, so it is published. Move all of
these to `relay/internal/*`, and move the conformance server to `dev/`.

### RELAY-R9 Separate the server description from reducer state (M, breaks advanced callers)

`server.server(registry)` is documented as an immutable description, yet it
holds a random `cursor_key`, exchange tombstones and subscriptions
(`server.gleam:474-492`). The module also carries the reducer's 11-variant
`ServerInput` and 7-variant `ServerEffect`, and `with_dispatch` takes six
positional arguments (`:559`). Move the reducer to `relay/reducer`
(`init(server) -> State(ctx)`, `step`) and simplify the hook to
`with_dispatch(server, fn(Registry(ctx), Call(ctx), String, Value) ->
Result(ToolOutput, DispatchError))`. Document `Input`/`Effect` as
revision-bound.

### RELAY-R10 One name per meaning (S–M, breaks)

| Collision or unclear name                                                                                    | Change                                                                       |
| ------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------- |
| `tool.ToolDeclaration` vs `client.ToolDeclaration` (different shapes)                                        | one read record `tool.Declaration` (JSON schemas), for listings and policies |
| `content.Annotations` vs `client.Annotations`                                                                | one spec-exact `content.Annotations` (R11)                                   |
| `resources.Resource` vs `authorization.Resource`                                                             | `authorization.ProtectedResource`                                            |
| `UnknownTool` (tool, authorization), `InvalidRuntimeConfig` (runtime, stdio), `InputRequired` (tool, client) | server side: `NotRegistered`, `RuntimeConfigRejected`, `NeedsInput`          |
| `ContextTool`, `HandlerCallContext`, `ContextResource`, `ContextPrompt`                                      | `Tool`, `Call`, `Resource`, `Prompt` (the type parameter already says it)    |
| `relay/transport/http`, `relay/transport/stdio`                                                              | `relay/http`, `relay/stdio`                                                  |
| `fresh_exchange`, `PublicApplicationFailure`, `OutcomeJsonSuccess`                                           | `new_exchange_id`, `ApplicationFailure`, internal                            |

### RELAY-R11 Protocol data that matches the pinned revision (M, breaks)

The frozen 2026-07-28 schema defines `Annotations` as `audience`,
`lastModified` and `priority`, but `content.Annotations` has `title` and
`description` and no `lastModified` (`content.gleam:25-32`). Only
`client.Annotations` has the spec shape. Content blocks lack the `_meta` that
the schema's TextContent and ImageContent carry. Image and audio `data` and
resource `blob` are base64 `String`s (`content.gleam:145-159`), but design §2.2
keeps bytes native and base64 inside codecs. Server tools cannot publish
`icons` or `_meta`, yet the client reads both (`client.gleam:363-375`). Adopt
the spec shape and byte constructors (`content.image(bytes: BitArray,
mime_type:)`). Add `meta` to every block and declaration now, so the spec's
optional fields exist at 1.0.

### RELAY-R12 Telemetry that names the tool and joins requests (S–M, additive)

`invocation.started.tool_name` carries the JSON-RPC method
(`runtime.gleam:525-529`; TH-7, SMCP-9), and `status` is the `String`
`"success"`/`"error"`. No event carries a correlation, a listener name or the
tool. The HTTP listener (413s and Host/Origin rejections), the client and
`admit` emit nothing. Add `method`, `tool: Option(String)`, `listener`,
`correlation` and a typed `Status`. Add events `[relay, http, rejected]`,
`[relay, client, call]` and `[relay, authorization, decided]`. Expose
`invocation_id` and `correlation` on `Call`.

### RELAY-R13 Bounded, fail-closed defaults (M, mostly additive)

Cap concurrent HTTP requests and `listen` streams, raise the SSE keepalive
from 250 ms to 15 s, bound JSON depth at admission, cap tombstones, and cap
the stdio client's pending-call queue. A non-loopback bind without
`with_protection` should fail unless the caller writes
`http.allow_unauthenticated()`. See §5.

### RELAY-R14 Services: one entry type each, and list-based `listen` (M, breaks)

Static resources have no `with_*` (callers update nested records), while
templates have four (`resources.gleam:146-176`).
`prompt(name, args, get)` and `prompt_with_inputs(prompt: Prompt, get)` take
different shapes (`prompts.gleam:65,85`). `completion` hides application
errors, but `completion_with_context` takes `CompletionError`
(`completion.gleam:43,53`). `SubscriptionFilter` restates the four
`SubscriptionNotification` kinds as booleans. Proposed:
`resources.static(uri, name, read)` and `resources.template(..)` share one set
of `with_*` plus `with_matcher`; `prompts.prompt`/`prompt_call` mirror the
tool binders; one `completion.completion(fn(ctx, Request) -> Result(Values,
e))`; and `client.listen(peer, [ToolsListChanged, ResourceUpdated(uri)])`
takes the union it yields.

### RELAY-R15 A public test kit (M, additive; design §3.3, theme 8)

`relay/testing.connect(server, context) -> client.Client` runs a client over
paired in-memory transports, with no port and no mist. Later, add scripted
peers and a test authorization server serving RFC 9728 metadata and JWKS;
secure_mcp wrote a 459-line provider for this.

### RELAY-R16 Docs and dependency readiness (S, release blocker)

No public module has a `////` doc, and 123 of 227 public functions are
undocumented. The README opens with stdio; the HTTP and client path exists
only in prose, and no defaults table exists. `json_blueprint` and `sinal` are
path dependencies, so a Hex install cannot resolve. `relay_ffi.erl` reads
mist's private `Connection` record while `gleam.toml:19-23` admits any mist
below 7.0.0; replace it with public mist API or an upstream hook. `gun` drops
out if R3 moves the client to http_gun.

## 5. Defaults table

| Operation                                       | Current default                                             | Proposed default                                                     |
| ----------------------------------------------- | ----------------------------------------------------------- | -------------------------------------------------------------------- |
| HTTP body; request and invocation timeout       | 1 MiB; 30 s                                                 | same                                                                 |
| HTTP response (buffered, or one SSE stream)     | 1 MiB                                                       | 1 MiB per call; separate per-event cap for `listen` streams          |
| SSE keepalive                                   | 250 ms                                                      | 15 s                                                                 |
| Concurrent HTTP requests (one runtime per POST) | **none**                                                    | 1,024, then 503                                                      |
| Concurrent `subscriptions/listen` streams       | **none**                                                    | 64, then 503                                                         |
| `listen` stream lifetime                        | until close or 1 MiB written; keepalive detects dead peers  | same, documented; no time cap (§6)                                   |
| Host and Origin allow-list                      | loopback only                                               | loopback only                                                        |
| Authentication on a non-loopback bind           | **none** (an unprotected listener starts)                   | `start` fails without `with_protection` or `allow_unauthenticated()` |
| JSON nesting depth at admission                 | **none** (bounded only by frame size)                       | 64 levels (Blueprint parser limits)                                  |
| Hub calls (register, unregister, stop)          | fixed 5 s and 2 s                                           | same, documented                                                     |
| Runtime live exchanges, frame size, invocation  | 100; 1 MiB; 30 s                                            | same                                                                 |
| Runtime tombstones                              | 60 s retention, **no count cap**                            | 60 s and 10,000 entries                                              |
| Progress notifications per invocation           | bounded by HTTP response bytes; **none on stdio**           | coalesce to the latest value                                         |
| Work started by a cancelled handler             | worker killed, no signal (TH-3)                             | `tool.cancelled(call)`, then kill after a grace period               |
| Stdio server read chunk and frame               | 4 KiB; 1 MiB                                                | same                                                                 |
| Client request timeout (also the connect wait)  | 30 s                                                        | 30 s request; 10 s connect                                           |
| Client response size; listing                   | 1 MiB; 256 pages, 10,000 items                              | same                                                                 |
| Client timeout or cancel                        | stream cancelled, **connection kept**, server keeps working | close that call's connection                                         |
| Client concurrency per HTTP client              | one shared gun connection (HTTP/1.1 queueing to verify)     | per-call connection, pool of 8                                       |
| Client reconnect after a drop                   | none; the `Client` stays dead                               | reconnect on next call; `NotSent` when nothing was written           |
| Client retries                                  | none                                                        | none; the application decides with `Evidence`                        |
| Stdio client pending calls                      | serialized, **queue unbounded**                             | 64, then an error                                                    |
| Client input methods; TLS                       | `[]`; `verify_peer` with system CAs                         | same                                                                 |
| Headers over plain HTTP to a remote host        | n/a (no headers)                                            | refused unless allowed explicitly                                    |
| `next_notification` wait, input rounds          | caller-supplied; caller-driven                              | same, documented                                                     |

No README table lists these defaults; add one next to the common path.

## 6. Convention feedback

- **One or two imports.** This target does not fit an MCP package. A server
  needs at least three relay modules (tool, server, transport); the client
  adds one more, and Blueprint supplies the codec. A root `relay` facade
  would only re-export them. Better targets: one fallible step per concept,
  and no machinery types on the common path.
- **Constructed data is opaque.** Protocol data that callers both build and
  read (`ContentBlock`, `PromptResult`, `ResourceContents`, declarations)
  would double in surface behind accessors. Proposed rule: protocol records
  mirror the pinned revision and include every optional field it defines
  (including `_meta`) at 1.0. Their fields change only with a protocol
  revision, which is a major release, and callers match with `..`.
  Library-defined configuration stays opaque.
- **Growing unions get `kind`/`describe`.** This fits `client.Error`. It does
  not help a reducer `Input`/`Effect` that every transport must match
  exhaustively. Label those types "revision-bound: new variants only in a
  major release".
- **Lifecycle names.** Add `serve` for a blocking runner (stdio owns the
  calling process), `connect`/`close` for a peer connection (not a service),
  and `handler` for the mountable form that theme 7 requires.
- **Bounded by default.** Bound a `listen` stream by a per-event byte cap and
  keepalive write timeouts, not by wall-clock duration; a duration cap makes
  every MCP client reconnect without cause.
- **One error per boundary.** `tool` has two boundaries (definition and
  dispatch), so `<Thing>Error` fits there. Every client operation crosses one
  wire boundary, so a single `client.Error` fits.
- **JSON currency.** Blueprint `Value` is right on tool paths (JSON Schema).
  Peer-supplied JSON that a caller must read (input-request params,
  capabilities, input responses in a handler) should go through a
  `decode.Decoder` accessor. The convention should say that `json.Json` alone
  is never a read type.

## 7. Open questions

1. **Move the client onto http_gun?** Recommended, if http_gun closes the
   connection when a streamed body is closed early, its pool keeps one
   in-flight request per HTTP/1.1 connection, and its
   `NotSubmitted`/`MayHaveBeenSent` maps onto `Evidence`. Its `open` plus
   `body.next` with cancellation tokens already covers SSE. The client gains
   pooling, cassettes, destination policy, correlation and telemetry. The
   cost: stdio-only users pull http_gun and its exact gun pin, and
   `CallOptions` must expose or wrap `http_gun/cancellation.Token`.
2. **Split the mist server into `relay_mist`?** The design keeps one
   distribution (§2.1). Today mist and its private-record FFI are paid for by
   every stdio-only and client-only user.
3. **Content-only tools as `Definition(i, List(ContentBlock))`?** On success
   the content appears as both `output` and `content`. The alternative is a
   phantom output marker with its own handler signature.
4. **Fail closed on a non-loopback bind without protection?** This breaks
   deployments that run Relay behind a trusted proxy today.
5. **Audience policy.** Keep exactly one audience (design §2.7), or accept any
   audience list that contains the resource (SMCP-10)?
6. **Reducer tier.** Should `relay/reducer` be public at 1.0, as design §2.4
   keeps the pure core a capability, or `@internal` until a second transport
   author needs it?
7. **`server.with_dispatch` after R5?** It is the only middleware hook. Once
   protection is wired, decide whether it remains public or becomes
   `with_middleware(fn(Call, next) -> …)`.
