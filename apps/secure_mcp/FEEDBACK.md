# secure_mcp — composition feedback

## Verdict

The combination works with about 480 lines of adapter glue and a 459-line
scripted OpenID provider; since 2 Oct 2026 it resolves from its manifest with
no dependency workaround. A user signs in through Warden in a wisp app, the MCP endpoint
`/mcp` runs inside the same mist listener, each request is admitted by
Relay's `authorization.admit` with a verifier backed by `warden.introspect`,
tool handlers receive the authenticated principal, and `generate_report` /
`report_status` run through Grind jobs that only their owner can read.
10 tests pass and `gleam run` narrates the session and its telemetry.

- **The packages now resolve together (SMCP-1, blocker, resolved).** Warden
  pinned `gleam_crypto == 1.6.0` (stdlib >= 1.0) while Relay and Grind capped
  `gleam_stdlib < 1.0.0`, so the app vendored gleam_crypto. With warden
  845b75e, relay 5caff50 and grind 7a04831 the app resolves gleam_stdlib
  1.0.5, gleam_crypto 1.6.0 and mist 6.0.3 from Hex, and the vendored copy is
  gone.
- **Relay has authorization primitives but no resource-server transport.**
  Mounting MCP in wisp meant re-implementing Relay's buffered HTTP handler on
  its custom-transport runtime (SMCP-2, 114 lines). A verifier cannot read
  the bearer token it is given (SMCP-3). Relay's own client cannot send a
  token at all (SMCP-6).
- **Warden supplies the provider call, not the resource-server decision.**
  Introspection returns no audience and does not check `exp` (SMCP-4), and
  Warden ships no testing support, so the app carries its own OpenID provider
  (SMCP-5, 459 lines).
- **One Grind defect** blocked typed errors: a worker with an error codec
  could not be re-bound by id after it succeeded (SMCP-7). Fixed by grind
  7a04831; the report worker has its error codec back.

## Answers to the brief's questions

- **Can relay + warden deliver an OAuth-protected MCP server with public
  APIs?** Yes, with workarounds. Every protocol duty is met: 401 without a
  token, 401 `invalid_token` for an expired, revoked or wrong-audience token,
  403 `insufficient_scope`, RFC 9728 metadata, and the principal in the
  handler. The decisive pieces come from the packages: Relay's `admit`
  checks the audience and scope, and Warden's `introspect` makes the
  authenticated provider call. The app supplies the transport, the token
  plumbing between the two and the challenge text.
- **What exactly is missing, and in which package?**

  | Missing piece                                                                     | Owner                                                | Finding |
  | --------------------------------------------------------------------------------- | ---------------------------------------------------- | ------- |
  | Resolvable dependency ranges (`gleam_crypto` pin, `gleam_stdlib < 1.0`)           | warden, relay, grind                                 | SMCP-1  |
  | A mountable HTTP handler or a per-request context builder                         | relay                                                | SMCP-2  |
  | Reading a `BearerToken`, `Scope` and `Resource`; challenge and metadata rendering | relay                                                | SMCP-3  |
  | Audience in `TokenInfo`; inactive result for an expired token                     | warden                                               | SMCP-4  |
  | A public scripted provider for tests                                              | warden                                               | SMCP-5  |
  | A header or token hook on the client; a typed 401 with its challenge              | relay                                                | SMCP-6  |
  | A way for an MCP client to obtain a token (Warden is an RP only)                  | relay (client authorization), outside Warden's scope | SMCP-6  |

- **Mount `/mcp` in the same wisp/mist app (advanced a).** Possible only by
  driving `relay/runtime` from a wisp handler; `relay/transport/http` owns its
  own listener. One listener serves both the browser routes and MCP.
- **Principal into tool handlers (advanced b).** Clean once the mount exists:
  the mount passes `McpContext(request_id, principal)` to
  `runtime.send_frame`, and `tool.handle_advanced` hands it to the handler as
  `call.application` (tools.gleam:92-107, :111-130).
- **Expired or revoked token (advanced c).** Works:
  `Bearer error="invalid_token", error_description="...", resource_metadata="..."`
  (test `expired_and_revoked_tokens_test`). The challenge text is app code.

## Findings

### SMCP-1 Warden cannot be combined with Relay or Grind: `gleam_crypto == 1.6.0` against `gleam_stdlib < 1.0.0`

- **Packages**: warden, relay, grind. **Kind**: ecosystem-interop. **Severity**: blocker.
- **Evidence**:
  - Solver output for this app before the workaround:

    ```
    There's no compatible version of `gleam_stdlib`:
      - You require warden 0.1.0
        - warden requires gleam_crypto 1.6.0
        - gleam_crypto requires gleam_stdlib >= 1.0.0 and < 2.0.0
      - You require grind 0.1.0
        - grind requires gleam_stdlib >= 0.70.0 and < 1.0.0
    ```

    A scratch package with only `relay` and `warden` fails the same way
    (`relay requires gleam_stdlib >= 0.70.0 and < 1.0.0`).

  - Causes: warden/gleam.toml:17 (`gleam_crypto = "== 1.6.0"`),
    relay/gleam.toml:11 and grind/gleam.toml:10 (`gleam_stdlib < 1.0.0`).
    Warden calls only `crypto.hash`, `strong_random_bytes` and
    `secure_compare` (warden/src/warden/internal/secure.gleam,
    native/jose.gleam, native/client.gleam), which every gleam_crypto 1.x
    provides.
  - Workaround: apps/secure_mcp/gleam.toml:22-25 and
    apps/secure_mcp/vendor/gleam_crypto (unmodified 1.6.0 source; one line
    of its gleam.toml widened to `>= 0.70.0`). This only works for an
    application; a library cannot ship it.
  - Relay also pins `mist = "== 6.0.2"` and `gun = "== 2.6.0"`
    (relay/gleam.toml:18-19). wisp 2.2.2 accepts 6.0.2, but Warden's own
    reference consumer uses mist 6.0.3 (warden/consumer/gleam.toml), so an
    app combining them is held back a patch release.
  - Related: apps/extractor EXT-10 (Grind and llm_wire cap stdlib below 1.0).
- **Proposal**: warden: `gleam_crypto = ">= 1.0.0 and < 2.0.0"`. relay and
  grind: `gleam_stdlib = ">= 0.70.0 and < 2.0.0"`. relay: `mist = ">= 6.0.2 and < 7.0.0"`.
  Each package's gate should resolve against the newest allowed versions.
- **Status (2 Oct 2026):** resolved by warden 845b75e (`gleam_crypto = ">= 1.6.0 and < 2.0.0"`),
  relay 5caff50 and grind 7a04831 (`gleam_stdlib < 2.0.0`; relay also
  `mist >= 6.0.2 and < 7.0.0`, `gun < 3.0.0`). The app deleted
  `vendor/gleam_crypto` (8 files, 759 lines) and the 4-line path override in
  gleam.toml. `gleam update` resolves gleam_stdlib 0.71.0 → 1.0.5,
  gleam_crypto 1.6.0 (now from Hex instead of `vendor/`), mist 6.0.2 → 6.0.3,
  glisten 9.0.0 → 9.0.1, gramps 6.0.0 → 6.0.1 and gun 2.6.0. Because
  `dev_provider.gleam` imports `gleam/crypto` itself, gleam.toml:17 now
  declares `gleam_crypto = ">= 1.6.0 and < 2.0.0"` as an ordinary dependency.

### SMCP-2 Relay cannot be mounted in an application router; the app re-implements the HTTP handler

- **Packages**: relay (+ wisp, mist). **Kind**: composition. **Severity**: major.
- **Evidence**:
  - `http.listener(server, context: fn() -> context)` builds context without
    the request (relay/src/relay/transport/http.gleam:58-70), and the request
    handler is private and bound to Relay's own mist listener (`handle_request`,
    http.gleam:518; `start`, :430-460). No per-request authentication or
    principal can reach a handler through the shipped listener.
  - Glue: apps/secure_mcp/src/secure_mcp/mcp_mount.gleam:28-157 (114 lines)
    starts one `relay/runtime` per POST, sends the frame with a per-request
    context, collects writes until a JSON-RPC response and stops the runtime,
    which is what `handle_buffered_request` does (http.gleam:785-850).
  - The glue cannot reach what Relay keeps internal: Host/Origin policy
    (http.gleam:568-602), `MCP-Method`/`MCP-Name`/version header checks
    (:1342-1376), custom-parameter header checks (:1378-1398), response
    status mapping through `v2026.http_response_status` (:1437-1452), SSE
    responses and `subscriptions/listen`. The app re-derives "has an id" and
    "is a response" by parsing JSON (mcp_mount.gleam:117-136). The only
    public admission helper, `server.http_admission_failure`, is used
    (mcp_mount.gleam:138-151).
  - Adds evidence to the relay card's concern 5 (no mountable handler,
    request-blind context).
- **Proposal** (relay): expose the handler that `start` already builds, with
  a request-aware context:
  `http.handler(listener) -> fn(Request(mist.Connection)) -> Response(mist.ResponseData)`
  and `http.listener_with_request(server, fn(Request(mist.Connection)) -> Result(context, Response(mist.ResponseData)))`.
  The `Error` branch lets the application answer 401/403 before Relay reads
  the body. A wisp app then mounts it with `wisp_mist` passthrough, and the
  existing listener becomes `handler` plus `mist.start`.
- **Status (2 Oct 2026):** still open; relay 5caff50 changed no public API.
  Its new behavior (a buffered call is cancelled when its client
  disconnects) lives in the private `handle_buffered_request`
  (relay/src/relay/transport/http.gleam:826), which mcp_mount.gleam
  re-implements, so the mounted endpoint does not inherit it. Each Relay fix
  to the buffered handler widens this gap.
- **Status (wave 2):** not resolved by relay 23e4063; relay kept its
  signatures and exposes no mountable handler. `mcp_mount.gleam` compiles and
  passes its tests against relay 23e4063 with no edit: it uses only
  `relay/runtime` (`RuntimeConfig`, `start`, `send_frame`, `stop`,
  `OutputWrite`/`OutputClose`) and `relay/server` (`fresh_exchange`,
  `http_admission_failure`), none of which changed shape. 114 lines remain.

### SMCP-3 Relay's authorization values cannot be read, so a verifier cannot see its token

- **Packages**: relay. **Kind**: ergonomics. **Severity**: major.
- **Evidence**:
  - `BearerToken`, `Resource` and `Scope` are opaque with constructors only
    (relay/src/relay/authorization.gleam:8-21). `verifier(name, version, fn(BearerToken) -> ...)`
    (:105-112) hands the closure a value it cannot open.
  - Glue: the app builds a new verifier per request that captures the raw
    string and ignores its argument (apps/secure_mcp/src/secure_mcp/auth.gleam:47-53).
    The scope named in `MissingEndpointScope(Scope)` is recovered by
    comparing against a freshly built `scope("reports")` (auth.gleam:135-142).
  - Relay renders neither the RFC 6750 challenge nor the RFC 9728 metadata,
    although both follow from `ProtectionConfig` and `AdmissionError`:
    auth.gleam:144-175 (31 lines) and web.gleam:155-164 (10 lines).
  - `admit` then works well: audience and scope decisions come from Relay,
    and the app only maps four error variants (auth.gleam:54-67).
  - Adds evidence to the warden card's relay seam note (opaque `BearerToken`).
- **Proposal** (relay): `authorization.bearer_token_value(BearerToken) -> String`,
  `scope_to_string`, `resource_to_string`; plus
  `authorization.challenge(AdmissionError, metadata_url: String) -> #(Int, String)`
  (status and `WWW-Authenticate`) and
  `authorization.resource_metadata(ProtectionConfig, authorization_servers: List(String)) -> json.Json`.
- **Status (2 Oct 2026):** still open (relay 5caff50 changed no public API).

### SMCP-4 Warden introspection is not ready for a resource-server decision: no audience, no `exp` check

- **Packages**: warden, relay. **Kind**: composition. **Severity**: major.
- **Evidence**:
  - `TokenInfo` has no audience; it is only in `claims: Dynamic`
    (warden/src/warden.gleam:1921-1932). The app decodes `aud` as a string or
    a list (apps/secure_mcp/src/secure_mcp/auth.gleam:103-106, :126-133).
    Relay's `admit` needs exactly that list (authorization.gleam:210).
  - `introspect` maps `active: true` to `ActiveToken` without comparing `exp`
    with the clock (warden/src/warden/internal/native/client.gleam:496-529;
    warden.gleam:1940-1960), while ID-token verification applies Warden's
    clock tolerance. The app re-checks `expires_at` (auth.gleam:98-101).
  - The rest of the mapping (`InactiveToken` to `BearerRejected`,
    `IntrospectionFailed` to `VerifierUnavailable`, the principal from
    `subject`, `client_id`, `scopes`) is 25 lines and reads cleanly.
  - Adds evidence to the warden card's concern 4 (`TokenInfo.claims: Dynamic`).
- **Proposal** (warden): add `audiences: List(String)` to `TokenInfo`, and
  return `InactiveToken` when `exp` is past the configured clock tolerance.
  Optionally `decode_token_claims(TokenInfo, decoder)`, matching
  `decode_claims`/`decode_userinfo`.

### SMCP-5 Warden ships no testing support; the app writes its own OpenID provider

- **Packages**: warden. **Kind**: extensibility. **Severity**: major.
- **Evidence**:
  - Warden's scripted provider, TLS server and PKI are Erlang under
    `warden/test` (warden_test_provider.erl, 258 lines, using erlang-jose;
    warden_test_server.erl; warden_test_pki.erl calling an OpenSSL script).
    None is importable.
  - Warden correctly requires `https` for the issuer and the authorization
    endpoint (warden/src/warden/config.gleam:561-575; warden.gleam:389), so
    any test provider needs a TLS certificate and a trust anchor.
  - Glue: apps/secure_mcp/src/secure_mcp/dev_provider.gleam (404 lines:
    discovery, JWKS, authorize, token with PKCE, introspection, mint, revoke)
    and src/secure_mcp_dev_ffi.erl (55 lines: RSA key, JWK, RS256 signing, a
    throwaway CA through `public_key:pkix_test_data`).
  - Every application that tests a Warden integration pays the same cost.
- **Proposal** (warden): publish a `warden/testing` module (or a
  `warden_testing` package) with `start_provider(ProviderOptions) -> Provider`,
  `issuer`, `trust_anchor_pem`, `issue_access_token(subject, audience, scopes, ttl)`,
  `revoke` and `stop`, built on OTP `public_key` so it needs no test-only
  Hex dependencies.

### SMCP-6 Relay's client cannot authenticate, and a 401 reaches the caller as prose

- **Packages**: relay. **Kind**: composition. **Severity**: major.
- **Evidence**:
  - `HttpClientConfig` holds no headers or token source
    (relay/src/relay/client.gleam:41-48), so `warden.authorization_header`
    has nowhere to go.
  - Test `relay_client_cannot_authenticate_test`
    (apps/secure_mcp/test/secure_mcp_test.gleam:272-282): `client.discover`
    returns `Error("server discovery returned HTTP 401")`
    (client.gleam:673). The status is inside a string and the
    `WWW-Authenticate` challenge, which tells a client where to get a token,
    is dropped.
  - Glue: a raw JSON-RPC client that sets `Authorization`, `MCP-Method` and
    `MCP-Name` itself (apps/secure_mcp/src/secure_mcp/client.gleam:100-219,
    109 lines).
  - Warden is a relying party only, so the app has no way to issue tokens to
    MCP clients; it hands the user's own access token out at `/me/token`
    (web.gleam:121-153). A real MCP client would run its own authorization
    code flow with `resource`, which is Relay's deferred client
    authorization (relay-design §2.8).
  - Adds evidence to the relay card's warden seam note.
- **Proposal** (relay): `client.with_headers(HttpClientConfig, List(#(String, String)))`
  as the minimum, or `client.with_token_source(config, fn() -> Result(String, Nil))`
  so a refreshing source can be plugged in; and a typed
  `HttpRejected(status: Int, www_authenticate: Option(String))` in the
  client's errors instead of the string.
- **Status (2 Oct 2026):** still open (relay 5caff50 changed no public API);
  `relay_client_cannot_authenticate_test` (secure_mcp_test.gleam:272) still
  observes the prose 401.

### SMCP-7 `bind_handle` rejects a succeeded job when the worker has an error codec

- **Packages**: grind. **Kind**: defect. **Severity**: major.
- **Evidence**:
  - The success acknowledgement writes `error = NULL, error_version = NULL`
    (grind/src/grind/internal/attempt/acknowledgement.gleam:181).
    `bind_handle` compares the stored `error_version` with the worker's
    (grind/src/grind/internal/postgres/job_reads.gleam:108-114), so after
    success it returns `CodecContractMismatch(ErrorCodec, "text-v1", "none")`.
  - Test `grind_bind_handle_after_success_defect_test`
    (apps/secure_mcp/test/secure_mcp_test.gleam:287-316): the id binds
    before the attempt; after `process_one` the original handle reads
    `SucceededWith("hello")`, but re-binding the id fails.
  - `report_status` receives only a job id, so it must re-bind. The first
    run of this app reported alice's finished report as "No such report job".
  - Workaround: the worker uses `worker.define` without an error codec
    (apps/secure_mcp/src/secure_mcp/tools.gleam:40-49). A business failure
    then reads back as `FailedOperationally("worker returned an application error")`
    and the worker's reason ("no data for period") is lost
    (test `failed_report_test`, secure_mcp_test.gleam:115-123).
  - Same root cause as apps/extractor EXT-1 (the snooze acknowledgement
    clears `error_version`): the column carries both the job's registered
    error contract and the version of a stored error value.
- **Proposal** (grind): keep the registered error-contract version in a
  column that acknowledgements never clear, and compare that in `bind_handle`
  and at claim. Add a test that re-binds a succeeded and a cancelled job of a
  `define_with_error_codec` worker.
- **Status (2 Oct 2026):** resolved by grind 7a04831. The report worker is
  `worker.define_with_error_codec` again with a `report-error-v1` codec
  (tools.gleam:40-51, reports.gleam:107-110); the 3-line workaround comment
  and the codec-less `worker.define` call are gone. `report_status` still
  re-binds by id with `bind_handle` (tools.gleam:148), and a failed report now
  reads `failed: no data for period` (`failed_report_test`,
  secure_mcp_test.gleam:115). The defect test became
  `grind_bind_handle_after_terminal_write_test` (secure_mcp_test.gleam:287):
  a succeeded and a business-failed job re-bind by id and read
  `SucceededWith("hello")` and the typed reason `"refused"`.
- **Status (wave 3):** resolved by grind 749c0dc; nothing left to prove
  separately. The worker is `worker.new(..) |> worker.with_error_codec(..)`
  (tools.gleam `report_worker`, 12 lines; 23 before), `report_status` re-binds
  with `grind.bind`, and a failed report reads back as the typed
  `grind.Failed(grind.Business("no data for period"), Some(job.RetryDeclined), _)`
  (`failed_report_test` asserts that value and the `failed: no data for
period` status). The 41-line probe test
  `grind_bind_handle_after_terminal_write_test` is deleted: the round-trip and
  failed-report tests already re-bind a succeeded and a failed job through
  `report_status`, so the defect is covered by ordinary behavior.

### SMCP-8 One report type needs two codec systems

- **Packages**: json_blueprint, relay, grind. **Kind**: composition. **Severity**: minor.
- **Evidence**:
  - Relay tools take Blueprint codecs; Grind workers take
    `worker.codec(version, fn(v) -> json.Json, decode.Decoder(v))`
    (grind/src/grind/worker.gleam:21-31). `Report` is both a tool output and a
    job output, so it has a Blueprint codec
    (apps/secure_mcp/src/secure_mcp/reports.gleam:144-173) and a gleam_json
    codec (reports.gleam:67-106, 38 lines) that must agree by hand.
  - The Blueprint record also crosses the `record3` limit and is built from
    nested `combine` pairs (reports.gleam:144-173).
  - Adds evidence to the json_blueprint card's concern 5 and apps/extractor
    EXT-5.
- **Proposal** (json_blueprint): `codec.to_json(Codec(a), a) -> Result(json.Json, EncodeError)`
  and `codec.decoder(Codec(a)) -> decode.Decoder(a)`. Grind then accepts
  `worker.codec(version, fn(v) { to_json(c, v) |> result.unwrap(json.null()) }, codec.decoder(c))`
  without a dependency between the two packages.
- **Status (wave 2):** resolved by json_blueprint 94438b9 (`codec.to_json`,
  `codec.decoder`, the `use`-based record builder). `Report` has one codec
  (reports.gleam:`report_codec`); Grind's codec is derived by a single
  11-line bridge `grind(version, codec)`. The 38-line gleam_json twin and the
  nested-`combine` four-field record (30 lines) are gone; the four-field record
  is now 12 lines with no arity limit. `ReportJob` and the error string, which
  had only gleam_json codecs, now use the same bridge, so the app has no
  `gleam/decode` field lists left.
- **Status (follow-up):** partially resolved by grind c44e4be and json_blueprint
  bb4da39; the bridge no longer stores `null` for an unencodable value (see the
  new-friction item below). Its getters need no annotation: 15 `fn(x: Type)`
  annotations are gone and `reports.gleam` is 10 lines shorter. The bridge is
  still needed (13 lines, +2); the two codec systems are joined only by it.
- **Status (wave 3):** partially resolved by grind 749c0dc. `worker.codec` is
  total (`encode, decoder`, version `"1"`), so the three `Result(_, CodecError)`
  returns, their `use ... result.try` lines in tools.gleam and the `version`
  parameter of the bridge are gone: reports.gleam's Grind section is 28 lines
  (31 before), the bridge is 10 lines, and `report_worker` has no `Result`.
  The bridge itself stays, because Grind cannot import json_blueprint (see
  the re-run section). The wave 2 versions (`"report-job-v1"`, ...) are not
  kept: this app stores nothing between runs, but a deployed wave 2 app would
  need `worker.with_version("v1")` and `worker.with_codec_version(..)` per
  codec to claim its stored jobs.

### SMCP-9 Telemetry: one request is followable only through app bridge events

- **Packages**: relay, warden, grind, sinal. **Kind**: composition. **Severity**: minor.
- **Evidence**:
  - Followed in test `telemetry_correlation_test`
    (apps/secure_mcp/test/secure_mcp_test.gleam:231-269): app
    `mcp.request(request, exchange)` → relay `request.admitted(exchange)` →
    app `report.submitted(request, job)` → grind `job.admitted(job)`.
  - The two app events (src/secure_mcp/telemetry.gleam:30-103, 68 lines) are
    needed because Relay's `HandlerCallContext` carries no exchange or
    invocation id (relay/src/relay/tool.gleam:447-453), so a handler cannot
    tag the job it creates. The app can tag it only because it chose the
    exchange id itself in the mount.
  - `[relay, invocation, started].tool_name` is `tools/call`
    (run output, `gleam run`), as the relay card says; no event names the
    tool.
  - `[warden, http, request]` carries method, host, path and outcome only
    (warden/src/warden/observation.gleam:28-30). It is emitted synchronously
    in the wisp request process, so only the emitting pid links an
    introspection to the MCP request it guarded. No event records the
    authorization decision itself.
- **Proposal**: relay: add `invocation_id: Int` and `exchange_id: Int` to
  `HandlerCallContext`, and put the tool name in `invocation.started`.
  relay: emit `[relay, authorization, decided]` from `admit` with the outcome
  (once SMCP-2 gives Relay the request).
- **Status (wave 2):** partially resolved by sinal 43279b3
  (`sinal/correlation`). The app's own key is now a `Correlation` instead of
  an `Int` from `unique_integer`: `McpContext.correlation`, the
  `[secure_mcp, mcp, request]` and `[secure_mcp, report, submitted]` events
  (via `correlation.field()`), and an inbound `x-request-id` validated with
  `correlation.from_string` where it enters the app (web.gleam,
  `request_correlation`, 8 lines; test `request_id_header_correlation_test`).
  The bridge events are still required: relay's `HandlerCallContext` and
  events, grind's job events and warden's HTTP event carry no `Correlation`
  (packages adopt it in their own waves), so the 60-line bridge (68 before)
  remains and the join is still `correlation -> exchange_id` and
  `correlation -> job_id` through the app events.
- **Status (follow-up):** partially resolved by sinal f9cca37 and 5e8bee3. The
  app events hold a plain `Correlation` (`correlation.required_field()`), so
  the `Some(..)` wrappers, the `Option` import and the collector's
  `correlation_text` unwrap are gone, and the builder no longer needs
  parameter/`and`/`build` or an annotation: the bridge definitions are 53
  lines (66 before). The bridge events themselves stay: relay and warden carry
  no `Correlation`, so the join is still `correlation -> exchange_id` and
  `correlation -> job_id`.
- **Status (wave 3):** partially resolved by grind 749c0dc. Every job
  stores a correlation and every Grind job event carries it
  (`telemetry.JobRef.correlation`), so the tool submits with
  `job.with_correlation(context.correlation)` and the app's
  `[secure_mcp, report, submitted]` event (type, codec, emitter and its
  collector line) is deleted. `job.admitted`, `job.claimed` and
  `job.acknowledged` now print the request's own correlation, and a caller's
  `x-request-id` reaches them (`telemetry_correlation_test`,
  `request_id_header_correlation_test`). Telemetry.gleam is 239 lines (266
  before). What remains is the relay side: `[secure_mcp, mcp, request]`
  still joins `correlation -> exchange_id` because relay (unchanged in wave 3)
  carries no `Correlation`, and warden's `http.request` still has none. Warden
  now labels its HTTP Gun client `"warden"` (3bc1732), but the label shows
  only in http_gun events, which this app cannot attach to without adding
  `http_gun` as a dependency.

### SMCP-10 Small gaps found on the way

- **Packages**: grind, relay. **Kind**: ergonomics. **Severity**: nit.
- **Evidence and proposals**:
  - grind: `job.state_to_stored` is `@internal`
    (grind/src/grind/job.gleam:183-198), so the app maps the 11 states to
    names itself (apps/secure_mcp/src/secure_mcp/tools.gleam:187-202, 15
    lines). Proposal: a public `job.state_name(State) -> String`.
  - relay: `admit` accepts an attestation only when it lists exactly one
    audience (relay/src/relay/authorization.gleam:210). RFC 8707 allows a
    token for several resources. If single-audience is the intended policy,
    document it; otherwise accept a list that contains the resource.
  - relay: `tool.declarations(registry, _context)` ignores the context
    (relay/src/relay/tool.gleam:778-784), so `tools/list` cannot vary per
    principal through the ordinary server. This app did not need it; the
    relay card's note on `ToolPolicy`/`dispatch_granted` already covers it.
- **Status (wave 3):** the grind item is resolved by grind 749c0dc:
  `job.state_name(state)` replaces the 15-line `state_name` in tools.gleam
  (the collector's `state_label` helper is gone too, using the same
  function). The two relay items are unchanged: relay did not change in wave 3.

## Glue measure

Lines of adapter code per seam, excluding blank lines and comments.

| Seam                                                          | Lines                | Location                                              |
| ------------------------------------------------------------- | -------------------- | ----------------------------------------------------- |
| Dependency resolution (warden × relay/grind)                  | 4 + vendored package | gleam.toml:22-25, vendor/gleam_crypto                 |
| Scripted OpenID provider (Warden test support)                | 459                  | dev_provider.gleam (404), secure_mcp_dev_ffi.erl (55) |
| MCP mounted in wisp (Relay transport)                         | 114                  | mcp_mount.gleam:28-157                                |
| Authenticated MCP client (Relay client)                       | 109                  | client.gleam:100-219                                  |
| Bearer verification: Relay verifier over Warden introspection | 89                   | auth.gleam:42-142                                     |
| Telemetry correlation bridge                                  | 68                   | telemetry.gleam:30-103                                |
| Challenges and RFC 9728 metadata                              | 41                   | auth.gleam:144-175, web.gleam:155-164                 |
| Second codec set for Grind                                    | 38                   | reports.gleam:67-106                                  |
| Grind state names                                             | 15                   | tools.gleam:187-202                                   |
| Principal into tool handlers                                  | 3                    | tools.gleam:21-23 (the mount supplies the context)    |

Not counted as glue: Warden's relying-party routes in wisp (web.gleam:52-153,
92 lines). Warden's string-in, string-out interface needs no adapter types;
the code is cookie handling and error rendering an application owns anyway.
The scripted browser (client.gleam:20-98) is test scaffolding.

## What worked well

- **Relay's `admit` makes the authorization decisions.** Audience and
  endpoint scope come back as `ResourceNotGranted` and
  `MissingEndpointScope(scope)`, so the 401-versus-403 split needed no app
  logic beyond mapping four variants.
- **Relay's custom-transport runtime is a real extension point.**
  `runtime.start(server, config, sink)` plus `send_frame(exchange, context, bytes)`
  was enough to host MCP inside another router with a per-request context,
  with invocation timeouts and crash isolation retained. `RuntimeConfig` is
  validated before anything starts.
- **`handle_advanced` carries application context into handlers.** The
  principal reached `generate_report` and `report_status` with no global
  state, and `handle_advanced_with_error_renderer` kept "No such report job"
  identical for a missing job and another user's job.
- **Warden's login is framework-neutral and composes with wisp in a few
  lines.** Raw query string in, URL and cookie value out. The RFC 8707
  `resource` parameter went through `LoginOptions.extra_parameters` without
  special support, and reserved names are refused.
- **Warden's transport configuration made a loopback test provider easy and
  explicit.** `TrustAnchorsPem(ca)` plus `AllowLoopbackForTesting` in one
  record update; http_gun stays internal and its loopback refusal never
  surfaced as friction. The first failed attempt reported
  `DiscoveryFailed(TransportFailure(False, TlsRejected))`, which named the
  problem (a wrong CA) at once.
- **Grind's typed reads gave ownership checks for free.** `bind_handle` plus
  `arguments` returns the typed `ReportJob`, so "users only see their own
  reports" needed no application table and no pog pool of its own.
- **Sinal descriptors from four packages attach the same way.** One
  collector, one `observe` helper, typed measurements and metadata from
  relay, warden, grind and sinal's own forwarder event.

## Re-run after fixes (2 Oct 2026)

Against warden 845b75e, grind 7a04831, relay 5caff50 and http_gun a2869b7
(through Warden). `../scripts/with-postgres.sh gleam test`: 10 passed, no
failures. `gleam run` narrates the session and its telemetry as before
(exit 0). `gleam format` is clean. The app resolves gleam_stdlib 1.0.5 and
gleam_crypto 1.6.0 from Hex, mist 6.0.3, gun 2.6.0 and wisp 2.2.2.

| Seam                                      | Before                                         | After                                        |
| ----------------------------------------- | ---------------------------------------------- | -------------------------------------------- |
| Dependency resolution (SMCP-1)            | 4 lines in gleam.toml + vendored package (759) | 0 (one ordinary `gleam_crypto` range line)   |
| Typed report failure (SMCP-7)             | 4 (workaround comment + codec-less `define`)   | 0; restored design adds a 3-line error codec |
| MCP mounted in wisp (SMCP-2)              | 114                                            | 114 (open)                                   |
| Challenges and RFC 9728 metadata (SMCP-3) | 41                                             | 41 (open)                                    |
| Authenticated MCP client (SMCP-6)         | 109                                            | 109 (open)                                   |

The loopback helper does not apply: the app builds no http_gun `Config`.
Warden keeps HTTP Gun internal and exposes its own
`config.AllowLoopbackForTesting` destination policy (app.gleam:101-106),
which is already a one-field record update; no host allowlist is involved.

New friction from the fixes:

- None from the package APIs; no app code had to change to absorb them.
- Removing the vendored path dependency left a stale entry in
  `build/packages/packages.toml`, so `gleam build` failed with "File IO
  failure … build/packages/gleam_crypto/gleam.toml" until the entry was
  deleted. This is Gleam build-cache behavior, not a package issue.
- Grind's default retry policy retries a business failure, so a probe
  worker needs `worker.DoNotRetry` before its failure is terminal. This
  is documented behavior, but a test of a typed failure has to know it.

## Re-run after wave 2

Against sinal 2b689c5, json_blueprint c96a8c3, relay 23e4063, grind c1920e6,
warden bf4f796 and http_gun 1dc20a1. `../scripts/with-postgres.sh gleam test`:
11 passed, no failures (10 existing plus `request_id_header_correlation_test`).
`gleam run` exits 0 and narrates the same session and telemetry; the app
events now print `correlation=<32 hex>` instead of `request=<int>`.
`gleam format` is clean and the build has no warnings.

| Seam                                                | Before                                            | After                                                                                   |
| --------------------------------------------------- | ------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Second codec set for Grind (SMCP-8)                 | 38 lines of gleam_json/decode twins               | 19 lines: one 11-line bridge and three 2-line wrappers; 0 duplicated field lists        |
| Blueprint records (reports.gleam)                   | 117 lines for both systems (4-field record: 30)   | 93 lines for all codecs, incl. the new Blueprint `ReportJob` codec (4-field record: 12) |
| Codec constructors returning `Result` (tools.gleam) | 13 lines of `use ... result.try` for 3 codecs     | 0                                                                                       |
| Sinal handler ids (telemetry.gleam)                 | 14 lines (`observe` helper, `handler_id`, FFI id) | 0; `sinal.observe(event, run)` called directly, `result.values` dropped                 |
| Sinal bridge event definitions (SMCP-9)             | 68 lines (`let assert`, `pair`, `imap`, `Result`) | 60 lines with the record builder; `emit` is a bare call (no `let _ =`)                  |
| App correlation key                                 | `Int` from an FFI `unique_integer` (web.gleam, 2) | `sinal/correlation`; FFI call removed from web.gleam; header validation added (+8)      |
| MCP mounted in wisp (SMCP-2)                        | 114                                               | 114 (open; compiles unchanged against relay 23e4063)                                    |
| Challenges, metadata, client, Warden provider       | 41, 109, 459                                      | unchanged (open)                                                                        |

Net, `git diff --stat` over `src` and `test`: 355 lines added and 369
removed. By file, `reports.gleam` -40 and `telemetry.gleam` -43 are glue
removed; `tools.gleam` is 0 (13 lines of `result.try` for codecs went, 13
lines of now-longer `tool.definition` calls came); `web.gleam` +10 (header
validation), `client.gleam` +18 and the new test +41 are new capability.

Relay's tool schemas now render `UnionSchema` where `TaggedSchema` was; this
app's tools use only records, so the `tools/list` test is unaffected.

### New friction

- **The `use` builder repeats the record type per field.** Every getter
  needs an annotation, and `gleam format` puts a one-line getter on three
  lines when the field name is long:

  ```gleam
  use job_id <- codec.field("job_id", codec.int(), fn(s: ReportStatus) {
    s.job_id
  })
  use state <- codec.field("state", codec.string(), fn(s: ReportStatus) {
    s.state
  })
  ```

  For records of one to three fields this reads about as long as `record2`
  did and is less obvious to a new reader than the old positional form; the
  gain is the missing arity limit and the missing `Result`. A getter-last
  variant, or a way to annotate once (`codec.record(fn(r: ReportStatus) { .. })`),
  would remove the repetition.

  **Status (follow-up):** resolved by json_blueprint bb4da39. Getters are
  passed as `get: fn(r) { r.x }` after the block, with no annotation; all 15
  getters in reports.gleam are one line except `report`, which `gleam format`
  wraps (5 were wrapped before).

- **The Grind bridge swallows an encode failure.** `codec.to_json` returns
  `Result`, Grind's encoder returns `json.Json`, so the guide's own recipe is
  `result.unwrap(json.null())`: an unencodable value is stored as `null` and
  fails later at decode. For a string-only codec it cannot happen, but the
  signature cannot say that. `worker.codec` also still returns
  `Result(_, CodecError)` for an empty version, so each of the three worker
  codecs keeps a `use ... result.try` in tools.gleam. A Grind-side
  `worker.blueprint_codec(version, codec)` would own both.

  **Status (follow-up):** resolved for the encode failure by grind c44e4be:
  the bridge is `codec.to_json(codec, value) |> result.map_error(codec.describe_encode_error)`
  and `submit` returns `submission.InvalidInput` instead of storing `null`.
  The `Result(_, CodecError)` return and the three `use ... result.try`
  lines in tools.gleam are unchanged, so a `worker.blueprint_codec` is still
  open.

- **`correlation.field()` forces `Option` onto an always-present key.** The
  app creates the id before any event, but the metadata field is
  `Option(Correlation)`, so both app events hold `Option(Correlation)`, both
  emitters wrap in `option.Some`, and the collector unwraps with
  `option.map(..) |> option.unwrap("-")`. This is right for libraries that
  may run uncorrelated; an application that always has one pays three small
  conversions (about 6 lines).

  **Status (follow-up):** resolved by sinal f9cca37 (`correlation.required_field()`):
  both events hold `Correlation`, the two `Some` wrappers, the `Option`
  import and `correlation_text` (3 lines) are deleted.

- **A one-field record is not a one-line `fields.field`.** `ReportSubmitted`
  and `McpRequest` use the record builder with a mandatory annotation on the
  first getter only; that works, but the nesting under `sinal.event(..)`
  after `gleam format` puts the builder chain inside the call and indents it
  two extra levels. Defining the metadata codec in its own function (as the
  packages do) reads better.

  **Status (follow-up):** resolved by sinal 5e8bee3: the `use` block replaces
  the chain, needs no annotation and sits in `{ }` as the last argument of
  `sinal.event`, with no extra nesting.

- Nothing from relay 23e4063: the buffered-handler gap in SMCP-2 is
  unchanged and unaddressed, and the changelog's "signatures are unchanged"
  held for everything this app calls.

### Migration guides

Sufficient for every edit in this app: the sinal guide's handler-id,
`pair`/`imap` and `optional` recipes and the json_blueprint guide's record
and bridge recipes applied one-to-one. Gaps: (1) neither guide says a
Blueprint codec's `Result` return was removed from the constructors, so a
caller learns that only from the compile error in code that pattern-matched
it (tools.gleam's `use ... result.try`); (2) the json_blueprint bridge snippet
does not mention that `worker.codec` still returns a `Result`; (3) the sinal
guide shows `sinal/correlation` only for library metadata, with no
application recipe for an inbound id, which this app wrote as
`correlation.from_string` plus `lazy_unwrap(correlation.unique)`.

## Re-run after the follow-up fixes

Against sinal 6de2b69, json_blueprint bb4da39 and grind 2d66835 (relay and
warden unchanged). `../scripts/with-postgres.sh gleam test`: 11 passed, no
failures. `gleam run` exits 0 with the same narration. `gleam format` is
clean and the build has no warnings. The edits were mechanical: add `get:`
to 15 `codec.field` sites, rewrite two record builders as `use` blocks,
swap `correlation.field()` for `required_field()`, change one bridge, and
wrap the test's `json.string` in `worker.infallible`.

| Seam                                                      | Before                                               | After                                                     |
| --------------------------------------------------------- | ---------------------------------------------------- | --------------------------------------------------------- |
| Blueprint getter annotations (reports.gleam)              | 15 `fn(x: Type)` annotations; 5 getters wrapped      | 0 annotations; 1 getter wrapped by `gleam format`         |
| Sinal bridge events (telemetry.gleam, definitions + emit) | 66 lines; 2 annotations; 2 `Some(..)`; 1 `Option`    | 53 lines; 0 annotations, 0 `Some`, 0 `Option`             |
| Collector unwrap of the correlation                       | 3-line `correlation_text`, 2 call sites              | 0; `correlation.to_string(m.correlation)` directly        |
| Grind bridge (reports.gleam `grind`)                      | 11 lines; failed encode stored as `null`             | 13 lines; failed encode is `InvalidInput`/`RuntimeFailed` |
| `worker.codec` in the app's probe test                    | `json.string`                                        | `worker.infallible(json.string)` (+1 call)                |
| http_gun correlation join tables                          | not applicable (the app builds no http_gun `Config`) | not applicable                                            |

Net `git diff --numstat` for the app: 47 lines added and 74 removed (reports
+22/-32, telemetry +23/-41, test +2/-1). SMCP-9's relay and warden bridge
(`correlation -> exchange_id`, `correlation -> job_id`) is unchanged: neither
package carries a `Correlation` yet.

### New friction

- **The new Grind path is untested by this app.** Every wire type here has
  string and int fields, so `codec.to_json` cannot fail and nothing exercises
  `InvalidInput` or `ExecutedUnencodable`. The bridge is now honest, but the
  app proves only that the happy path still works. A refinement
  (`integer_between` on a job field) would be needed to test it.
- **Grind's bridge is still hand-written.** The recipe is a 7-line closure
  that every Blueprint user copies; it needs `gleam/result` and a Blueprint
  import in the app and is two lines longer than the `null` version. A
  `worker.codec` that accepts a `Result`-returning encoder cannot own it
  without depending on json_blueprint; a bridge in json_blueprint
  (`codec.to_worker_codec`) would, but only if Grind's `Codec` type moved or
  the two packages shared an interface.
- **`required_field()` stays silent on an uncorrelated emitter.** A handler
  that uses `required_field()` skips an event whose `correlation` is missing
  as `MalformedMetadata`, per the guide. Here every emitter is the app, so it
  cannot happen, but a second emitter using `field()` with `None` would drop
  the app's collector line without a visible error beyond the skipped call.
- **The `use` block runs with placeholder values.** The sinal guide warns that
  the block runs once with zero values and again on decode, so a block must not
  branch on a bound field. The two blocks here do not, but nothing in the type
  system enforces it; a review comment is the only guard.
- **Migration guides.** Sufficient: the getter rule and the `required_field`
  snippet applied one-to-one. Gap: the sinal guide's `required_field`
  section names this app's two events but not that the collector's
  `option.map(..) |> option.unwrap("-")` helper becomes dead code, which only
  the unused-function and import warnings revealed.

## Re-run after wave 3

Against grind 749c0dc/83a02b0, sinal 44c5395, json_blueprint 74a9a7d, warden
b59ffc1 (57e1f54 and 3bc1732: `stop`, the `"warden"` client label) and relay
6ee2ae9 (pins only). `../scripts/with-postgres.sh gleam test`: 11 passed, no
failures. One test was removed (the SMCP-7 probe) and one added
(`invalid_report_is_refused_at_submit_test`). `gleam run` exits 0 with the
same narration; the three Grind telemetry lines now end in
`correlation=<the request's id>`. `gleam format` is clean and the build has no
warnings. Warden needed no change here (`warden.stop` and the label are
invisible to this app); relay compiled unchanged, so SMCP-2, SMCP-3 and
SMCP-6 stay open as written.

| Seam                                    | Before                                                                                                                                                | After                                                                                                       |
| --------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| Grind start-up (app.gleam `start_jobs`) | 32 lines: settings, validate, start, migrate, registry, policy, consumer                                                                              | 25 lines: one `pog.Config`, one `grind.Config`, `grind.start`, `grind.migrate`                              |
| Grind shutdown (`app.stop`)             | `queue.stop` then `postgres.close`, only from the starting process                                                                                    | `grind.stop(jobs)` from any process; the "must run in the calling process" comment is gone                  |
| Handles in `Running`                    | `Database`, `Consumer`, worker                                                                                                                        | `Grind` (a name), worker                                                                                    |
| Worker definition (`report_worker`)     | 23 lines, `Result`, 3 `result.try` codec unwraps                                                                                                      | 12 lines, no `Result`                                                                                       |
| Worker retry policy                     | `retry_policy(fn(_failure, _context) { DoNotRetry })`                                                                                                 | `with_retry_policy(fn(_error, _attempt) { worker.DoNotRetry })`                                             |
| Grind codec bridge (reports.gleam)      | 31 lines, three `Result` wrappers, version strings                                                                                                    | 28 lines, no `Result`, no version                                                                           |
| State names (SMCP-10)                   | 15 lines in tools.gleam, 3 in telemetry.gleam                                                                                                         | 0: `job.state_name`                                                                                         |
| Outcome mapping in `report_status`      | 7 arms over 9 `job.*` patterns (two or-patterns)                                                                                                      | 7 arms over 7 `grind.*` patterns; `Failed(Business(reason), ..)` replaces two `BusinessFailedWith*`         |
| Report bridge event (SMCP-9)            | `[secure_mcp, report, submitted]`: type, codec, emitter and collector entry (telemetry.gleam 266 → 239 lines with the three added correlation fields) | 0: `job.with_correlation(context.correlation)`                                                              |
| Test and `gleam run` polling            | 22 lines of `await_status`/`await_loop` over `report_status`; a 25-line retry loop in `secure_mcp.gleam`                                              | `grind.bind` + `grind.await(within:)` once (11-line test helper, 6 lines in main); one `report_status` call |
| SMCP-7 probe test                       | about 40 lines, a second queue consumer with manual polling                                                                                           | 0 (covered by `failed_report_test` and the round trip)                                                      |
| Lost submit reply                       | `CommitUnknownWithoutId`: not handled, could duplicate                                                                                                | `admit`, 8 lines: `CommitUnknown(pending)` goes to `grind.reconcile_submission` (new behavior, untested)    |
| Error from the job codec                | not reachable (no refined codec)                                                                                                                      | `InvalidReport(reason)`: `non_empty` refinement (11 lines) plus 3 lines of mapping; tested                  |
| gleam.toml                              | no `gleam_time`                                                                                                                                       | +1 line (`gleam_time`, for `duration`)                                                                      |

`git diff --numstat` over `src`, `test` and gleam.toml: 260 lines added and
279 removed. Roughly 60 of the added lines are new behavior (the refusal path
and its test, `admit`, the `field` test helper, `non_empty`).

Seams that still need glue, and who owns them:

- Relay: the buffered `/mcp` handler (114 lines), challenges and metadata (41),
  the authenticated client (109), and the exchange bridge event. Unchanged.
- Warden: the 459-line scripted provider (SMCP-5), introspection without
  audience (SMCP-4). Unchanged.
- json_blueprint and grind: the 10-line codec bridge. Grind documents it in
  its README (`worker.codec(fn(v) { codec.to_json(..) |> result.map_error(codec.describe_encode_error) }, codec.decoder(c))`)
  but the app still writes it.

### New friction

- **`Admission` makes a plain submit match three variants.** The job has no
  uniqueness policy, so only `Inserted` can happen, yet `grind.submit`
  returns `Admission` and the handler needs
  `Existing(conflict) | Rescheduled(conflict) -> conflict.job_id` to be total
  (4 lines in `generate_report`). The old `postgres.submit` returned a handle.
  A `let assert Ok(grind.Inserted(handle))` would be shorter but panics in a
  request handler. Proposal (grind): a `grind.submit_unique`-style split, or
  `submit` returning the handle when the job has no `unique` policy.

  **Status (wave 3 fixes):** resolved by grind 6bd06ec; `grind.handle(admission)`
  replaces the three-variant `case`, so `generate_report` reads
  `job.id(grind.handle(admission))`.

- **`CommitUnknown` needs the caller to hold the typed pending value.** The
  `admit` helper has to restate the full
  `Result(Admission(ReportJob, Report, String), SubmitError(ReportJob, Report, String))`
  type (3 lines of signature), because the error carries the worker's three
  type parameters. An alias such as `grind.Submitted(job)` would shorten every
  caller; Gleam has no way to infer it in a helper.

  **Status (wave 3 fixes):** resolved in the app, no package change; the `admit`
  helper and its 3-line signature are gone, the `CommitUnknown` case is inline
  in `generate_report`, and `submit_failed` takes
  `grind.SubmitError(input, output, failure)` with type variables.

- **`SubmitError` has no reason text for `InvalidInput` alone.** The tool maps
  `InvalidInput(reason)` to its own `InvalidReport(reason)` and everything else
  to `SubmitFailed`; `grind.describe_submit_error` exists but renders the
  whole error, including its prefix, so the client message would read as
  grind's wording. Using the `reason` directly was shorter, but it exposes the
  Blueprint path text (`$["title"]: must not be empty`) to MCP clients.
- **`migrate` needs a running runtime, so consumers poll before the schema
  exists.** The order is `grind.start` then `grind.migrate`. `start`
  succeeded on a fresh cluster with no tables and nothing visible failed while
  the consumer polled, so it works here; but a deploy that migrates before
  starting has no entry point except cigogne, and the old
  `postgres.migrate` before `queue.start` order is gone.

  **Status (wave 3 fixes):** resolved by grind 9ccbfb5; `start_jobs` passes
  `grind.with_startup_migration`, so the schema is current before any consumer
  polls and `grind.migrate` is no longer called.

- **A stand-alone app has no supervision tree to give `supervised`.** This app
  starts its parts (provider, Warden, Grind, mist) by hand and stops them in
  reverse, so it uses `grind.start`/`grind.stop`, which the README labels for
  scripts and tests. The ordinary path would be a `static_supervisor` holding
  Grind, Warden and mist; Warden's `warden.start` and mist's `mist.start` are
  not child specifications here, so the app would need two more adapters.
  The package defaults are right for this app; its composition is the part
  that stays hand-rolled.
- **`Options.poll_interval` is now a `Duration`, which adds a dependency.**
  `queue.with_poll_interval(duration)` made the app's own `Options` field a
  `gleam_time` type and required `gleam_time` in gleam.toml (Gleam warns on a
  transitive import). Correct typing, one more line for every Grind user.
- **`sinal.observe_labelled`, `correlation.from_key`, `fields.check`,
  `codec.value()`, `grind.submit_in` do not apply.** The collector's 12
  handlers have no ids to replace (wave 2 removed them); the only correlation
  built from outside input is the validated `x-request-id`, which must keep
  `from_string` (it must refuse an oversized value, not hash it, and the test
  pins that); no app event has an enum; no value is passed through unchanged;
  and the app has no transaction of its own.
- **Bounded defaults changed nothing observable.** The 15-minute handler
  timeout, 100 snoozes and 7-day pruner do not touch a 20 ms report job. The
  1 MiB payload limit applies to a report title that the tool does not bound;
  `PayloadTooLarge` would have fallen into `SubmitFailed` ("try again"), wrong
  advice for a request that never fits, so `submit_failed` maps it to a
  refusal too. Nothing tests it: Relay's mount limit may reject such a body
  first, and the app had to know to look. Branching on
  `grind.submit_error_kind(error) == grind.Invalid` would cover both and any
  future variant, but then the client sees no reason text of its own.
- **Migration guide.** Sufficient for every edit in this app; the secure_mcp
  index entry named `state_name`, the total codec and the refined-codec test
  correctly. Gaps: it does not say that `grind.start` needs a fresh
  `process.new_name` per runtime (the test suite starts 11), nor that
  `grind.Grind` is a name that can be stored in `tools.registry` before the
  runtime starts, which this app relied on.

### After the follow-up fixes

11 tests pass (`../scripts/with-postgres.sh gleam test`); `gleam run` exits 0
and `gleam format` and the build are clean. The fixes touched `tools.gleam` and
`app.gleam` only: about 31 lines removed, 17 added (the `admit` helper, the
`Admission` case, the `migrate` branch; `with_startup_migration`, the inline
`CommitUnknown` case and `grind.handle` added). No test pinned a fixed defect,
so none changed.
