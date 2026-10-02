# http_gun — API card

Repo: `/code/gleam-dream/http_gun`. Design: [http-gun-design.md](../../../http-gun-design.md).
Rules: [PUBLIC-API-GUIDELINES.md](../../../PUBLIC-API-GUIDELINES.md). Scanned 2026-10-01.

## Health

- Git head: `369da4f fix: address Warden trust and connection reuse gaps`. Working tree clean.
- Gate: the repo's own fast gate, `./dev/env sh dev/gate fast` (also the lefthook pre-commit). It copies
  the package and a verified Sinal snapshot into a temp workspace and then runs `gleam format --check src test dev examples`,
  `gleam check`, `gleam build --warnings-as-errors`, `gleam test`, `erlc -Werror` on all FFI, and `dev/boundaries.py`.
  **Result: pass (exit 0). 128 tests passed, no failures.** Output ends with "Production dependency, Dynamic and public-consumer
  boundaries passed." The log has crash reports and TLS alerts, which come from the fault-injection tests and do not fail anything.
- Not run: `dev/gate full` (streaming consumers, nghttpd H2 interop, batch/recording/load benchmarks), `dev/matrix` and `dev/linux-gate`.
  docs/PROGRESS.md says full gates passed on OTP 29/28/27 with 128 tests.
- Common-path snippet below was compiled from a separate scratch consumer package (`gleam build` passed).
- TODO/FIXME: none in src/test/dev/examples. Open items in the repo's own docs (README, PROGRESS.md, BOUNDS.md):
  - Warden adoption is not claimed. Warden's transport suite is 17/19. The two failing tables need finer failure classes and strict
    reason-phrase rejection, which Gun's public API cannot provide. Four malformed or truncated cases still get a coarse failure class.
  - Body/query redaction and power-loss-durable publication are "optional features, not implemented".
  - Hosted x86_64 CI is configured but has not run.
  - AGENTS.md says a 2026-09-29 restart prompt "supersedes ... conflicting oversight requirements". The repo's own docs/DESIGN.md
    now governs, so oversight's design doc may lag behind it.

## Purpose and scope delivered vs design

http_gun is a standalone, Gleam-first HTTP client on Gun 2.6.0 / Cowlib 2.20.0. You start a client from a pure `config.Config`,
send standard `gleam/http` requests, and either collect a bounded `Buffered` response (with trailers and the negotiated protocol)
or stream an owned opaque `Body`. It delivers H1 plus H2 (prefer or require, ALPN), and pool admission across global, per-origin,
per-connection-stream and waiter caps. It enforces a monotonic per-request deadline, scoped cancellation tokens and an ordered
bounded `batch`. Destination policy is pinned: the full A/AAAA answer is checked, Gun connects to the checked IP, and TLS verifies
against the original hostname. Recording and playback use cassettes with credential-header stripping, an incremental bounded
writer and atomic publication. Lifecycle events go out through Sinal. Almost all of the design's "required independent release"
inventory is present. Still missing or different from the design:

- **Redaction policy** (the design lists it as required under Live recording, lines 72 and 234-236). Only a fixed credential-header
  list is excluded. Bodies and queries are recorded exactly, and there is no caller policy for other headers.
- **Delivery evidence**: the design asks for headers-received and byte-progress facts tagged Live or Playback (lines 186-187).
  `Evidence` has only `NotSubmitted | MayHaveBeenSent`. Origin can be inferred only from `Negotiated.Offline`.
- **Draining shutdown**: the design specifies bounded draining (line 127). `stop` cancels active work immediately.
- **Observability coupling**: the design says observability must not require another Gleam Dream package (line 10). `sinal` is a
  mandatory path dependency (gleam.toml:13).
- **Follow-on scope**, all absent: streamed uploads, redirects, decompression, proxies/mTLS, cookies/cache, generic SSE framer,
  named playback lanes.

## Public modules

| Module                     | Responsibility                                                                                                                                                                                                            |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `http_gun`                 | Facade: `start`/`child`/`stop`, `send`, `open`, `with_response`, `try_with_response` (each also `_with_options`), `batch`, `snapshot`, `with_correlation`, `request_ceiling_ms`; `Client`, `Buffered`, `Failure`, `Stats` |
| `http_gun/config`          | Pure `Config` record (protocol, trust, deadline_ms, connect_ms, `Limits`, observations, destination); `default`, `validate`; `Negotiated`                                                                                 |
| `http_gun/destination`     | `Policy` (allow_public/loopback/private, allowed_hosts, injectable `Resolver`), `Address`, `Class`, `classify`, `permits`                                                                                                 |
| `http_gun/body`            | Opaque `Body`; `next(body, wait_ms)` -> `Chunk`/`End(trailers)`; `close`, `collect(body, limit)`, `protocol`                                                                                                              |
| `http_gun/request_options` | Per-call `Options(deadline: Option(Deadline), cancellation: Option(Token))`; `default`                                                                                                                                    |
| `http_gun/deadline`        | Opaque VM-local monotonic `Deadline`; `after`, `remaining_ms`                                                                                                                                                             |
| `http_gun/cancellation`    | Opaque latched `Token`; `with_token`, `try_with_token`, `cancel`                                                                                                                                                          |
| `http_gun/error`           | `Failure(reason, evidence)`, `Reason`, `Evidence`, `LimitKind`, `TransportCause`, file causes; `describe`                                                                                                                 |
| `http_gun/fixture`         | Exchange model for scripts and cassettes: `Exchange`, `Reply`, `Ending`; `matches`, `sanitise`, `safe_headers`                                                                                                            |
| `http_gun/testing`         | `start(settings, exchanges)`: an offline scripted `Client`                                                                                                                                                                |
| `http_gun/cassette`        | Opaque `Cassette`; `new`/`parse`/`load`/`encode`, `playback`, `record` -> `Recorded(client, recording)`, `finish`                                                                                                         |
| `http_gun/recording`       | Recording session: `Options`, `Replacement`, `finish`, `finish_wait`, `abort`, `CaptureError`, `FinishError`                                                                                                              |
| `http_gun/telemetry`       | Sinal event `[http_gun, lifecycle]`: `event()`, `Metadata`, `Milestone`, `Outcome`, `Mode`, opaque `Id`/`new_id`                                                                                                          |

Internal machinery (`pool`, `bridge`, `batch`, `codec`, `file`, `resolution`, ...) lives under `http_gun/internal/*`, which
gleam.toml declares internal. Construction helpers inside public modules are marked `@internal`.

## Common path

```gleam
import gleam/bit_array
import gleam/http/request
import http_gun
import http_gun/body
import http_gun/config
import http_gun/error

pub fn fetch(url: String) -> Result(Int, error.Failure) {
  let assert Ok(client) = http_gun.start(config.default())
  let assert Ok(base) = request.to(url)
  let req = request.set_body(base, <<>>)
  // Buffered: non-2xx is data; collection is bounded by limits.collect_bytes.
  let assert Ok(http_gun.Buffered(response:, trailers: _, protocol: _)) =
    http_gun.send(client, req)
  let _status = response.status
  // Streaming: the callback's process owns the body; scope exit closes it.
  let counted =
    http_gun.try_with_response(client, req, fn(failure) { failure }, fn(resp) {
      count(resp.body, 0)
    })
  let _ = http_gun.stop(client)
  counted
}

fn count(stream: body.Body, total: Int) -> Result(Int, error.Failure) {
  case body.next(stream, 5000) {
    Ok(body.Chunk(bytes)) -> count(stream, total + bit_array.byte_size(bytes))
    Ok(body.End(trailers: _)) -> Ok(total)
    Error(failure) -> Error(failure)
  }
}
```

Default policy is public destinations only. Local servers need
`config.Config(..d, destination: destination.Policy(..d.destination, allow_loopback: True))`.

## Configuration and advanced paths

- **Settings** are one pure public record. `config.default()` gives H1, `SystemTrust`, 30 s `deadline_ms` ceiling, 5 s `connect_ms`,
  16 connections / 4 per origin / 100 H2 streams / 128 active / 128 waiting, and byte limits for request, head, header count, chunk,
  queue and collect. Callers edit it with record update (`Config(..d, limits: Limits(..d.limits, collect_bytes: n))`).
  There is no builder family. `config.validate` runs again inside `start`/`child`.
- **Trust**: `SystemTrust | CustomCa(path) | Anchors(List(BitArray))`. There is no client certificate or mTLS option.
- **Protocol**: `Http1 | PreferHttp2 | RequireHttp2`. The negotiated result shows up as `Buffered.protocol` and `body.protocol`.
- **Pool**: each `Client` owns exactly one pool, and nothing is shared between clients. `snapshot` returns `Stats(connections, bodies, waiting)`.
  `with_correlation(client, id)` gives a pure view of the same pool that tags observations with a correlation id.
- **Per-request**: `request_options.Options(deadline:, cancellation:)` with the `*_with_options` variants. The effective deadline
  is the earlier of the client ceiling and the supplied deadline, so a request can never get more time than the ceiling.
  `cancellation.with_token` shares one token across several calls.
- **Destination policy**: `destination.Policy` has allow flags and an exact-host allowlist (no port matching). Reserved and metadata
  ranges are always refused. `resolver: Some(fn(host, remaining_ms) -> Result(List(Address), Nil))` is a test seam. It runs in an
  isolated worker and fails closed. DNS is trusted for one connection's lifetime.
- **Cassettes as a downstream test tool**:
  - Scripts: `testing.start(settings, [fixture.Exchange(req, fixture.Respond(resp_with_chunk_list, fixture.Complete(trailers)))])`.
    `Reject(Failure)`, `Failed(Failure)` and `Cancelled` endings model transport faults.
  - Disk playback: `cassette.load(path, max_bytes)` then `cassette.playback(tape, settings)`. It is strict, ordered and offline
    (no DNS, no network fallback). A mismatch returns `FixtureMismatch(position)` and does not consume the exchange.
  - Recording: `cassette.record(settings, path, recording.default())` returns `Recorded(client, recording)`. Close with
    `recording.finish_wait(rec, ms)` and stop the client separately. The default `RefuseExisting` mode publishes through an atomic link.
  - All three modes hand back the same `http_gun.Client`, so a downstream package that takes a `Client` gets playback for free.
    llm_wire's `testing` module builds its scripts from `fixture.Exchange` this way.
  - Matching covers method, URL, sorted non-credential headers and exact body bytes. The schema is versioned (`"http_gun": 1`).
- **Observations**: `config.observations: Option(sinal/forwarder.Forwarder)`, described under Composition seams.

## Lifecycle and supervision

- `start` launches a linked gleam_otp actor, the pool owner. Body owners, readiness jobs and DNS workers are further Gleam actors
  that it supervises internally. Gun connections are its processes. Erlang code is limited to Gun bindings and scope cleanup.
- `http_gun.child(settings) -> supervision.ChildSpecification(Client)` (http_gun.gleam:51) is a standard worker spec.
  **When it restarts, callers get a new `Client` value.** The library offers no stable name or registry, so anything holding the old
  `Client` sees `ClientClosed`. Callers have to republish the new value themselves; see Warden below.
- `stop` cancels outstanding local work and closes this client's connections. It does not stop the shared `gun` or `ssl` applications.
- **Body ownership**: the process that opened the body owns it. Copies share one cursor, and only the opener may call `next`;
  anyone else gets `WrongOwner`. Any holder may `close`, and `close` is idempotent. A body is released on close, scope exit,
  owner death or client stop. `with_response`, `try_with_response` and `send` close for you, even on exceptions.
  `open` hands the caller responsibility for closing.
- Recording sessions are their own actor. `finish_wait` seals the session and never drains HTTP.
  Cancellation tokens are actors whose lifetime is bounded by the scope that created them.

## Failure model

- Every operation returns `Failure(reason: Reason, evidence: Evidence)` (error.gleam:63-90). `Evidence` is `NotSubmitted` or
  `MayHaveBeenSent`. It is conservative and proves nothing about remote execution.
- `Reason` covers:
  - Input: `InvalidConfig(String)`, `InvalidRequest(String)`.
  - Lifecycle: `ClientClosed`, `Closed`, `Cancelled`.
  - Admission: `AdmissionFull`, `DestinationRejected`, `ResolutionFailed`.
  - Transport: `ConnectionFailed(TransportCause)`, `RequestFailed(TransportCause)`, with 12 closed causes.
  - Time: `DeadlineExceeded` (overall budget) versus `ReadTimeout` (local wait, stream preserved).
  - Body ownership: `ReadConflict`, `WrongOwner`.
  - Limits: `LimitExceeded(kind: LimitKind, limit, observed)`.
  - Fixtures: `FixtureMissing`, `FixtureIo(op, cause)`, `FixtureCorrupt`, `FixtureVersion(Int)`, `FixtureExhausted`,
    `FixtureMismatch(position)`, `CaptureFailed(String)`.
- HTTP status is always data. There are no retries, redirects or decompression.
- Recording has separate error types. `cassette.record` returns `StartRecordingError = ClientFailure(Failure) | CaptureFailure(CaptureError)`.
  `finish` returns `FinishError = Busy | WaitTimeout | CaptureFailed(CaptureError)`. A capture failure never turns completed HTTP into a failure.
- `error.describe` gives a bounded log string with no URLs, headers or bodies.

## Composition seams

- **gleam_http types**: requests are `gleam/http/request.Request(BitArray)` throughout. Responses are standard `Response(BitArray)`
  inside `Buffered`, or `Response(body.Body)` for streams. Anything that builds `gleam/http` requests plugs in without an adapter.
  `Request(String)` callers need `set_body(bit_array.from_string(...))`. Trailers sit outside `Response`, in `Buffered.trailers`
  or `body.End(trailers)`.
- **sinal**: `config.observations: Option(forwarder.Forwarder)`. The application supervises the forwarder.
  - Emits the typed `sinal.Event(Timing, Metadata)` `[http_gun, lifecycle]` (telemetry.gleam:79).
  - Milestones: `AdmissionEntered/Waiting/Granted`, `GunCallReturned`, `ResponseHeaders(status)`, `HttpTerminated(Complete | LocallyCancelled | DeadlineExpired | Failed)`.
  - Metadata: `request_id`, optional `correlation`, `Mode(Live | Recorded | Offline)`.
  - Delivery is best effort and drops under overload. Events carry no URLs, headers or bodies.
  - `sinal` is mandatory in gleam.toml even when observations are off.
- **llm_wire (consumer)**: takes a caller-supplied client, `session.run(client: http_gun.Client, prepared)` and `stream`/`run_structured`
  (llm_wire session.gleam:69-90, 229-250). It streams through `http_gun.with_response_with_options` plus `body.next` with its own
  deadline and cancellation (internal/http_client.gleam:72). llm_wire's public `types.HttpFailure(reason: http_error.Reason)`
  (types.gleam:565) re-exports http_gun's error type. Its `testing` builds `fixture.Exchange` scripts, so cassettes and playback flow through.
- **warden (consumer)**: http_gun is wrapped privately in `warden/internal/transport.gleam`.
  - Warden re-declares `Trust`, `Address` and a policy, then maps them into `config.Config` (transport.gleam:263-292).
    `observations` stays `None`, so Warden emits its own `observation.http_request` instead.
  - It supervises its own client with `http_gun.child |> supervision.map_data`, storing the `Client` in `persistent_term` under a
    ref key and reading it back with an unsafe `coerce` (transport.gleam:147-183, 534-550). That is a workaround for restarts
    producing a new `Client`.
  - It uses `with_response_with_options` plus `body.collect(body, policy.max_body)` because `send` only collects up to the client-wide limit.
  - Warden gives callers no way to inject an existing `http_gun.Client`.
- **Sharing one client across llm_wire and warden**: not possible today. llm_wire accepts any `Client`, but Warden always builds its
  own from its own policy (strict HTTPS, its own limits, `allowed_hosts`). Because each `Client` is one pool with one policy, sharing
  would also force one destination policy, trust set and limit set onto both workloads. LLM providers and IdPs are different origins,
  so connection reuse would gain little. The realistic sharing is the VM-wide Gun/SSL applications, which already happens.
  If the ecosystem wants one supervised HTTP root, http_gun should provide a stable named handle and Warden should accept a client.
- **relay (could adopt)**: relay drives Gun directly through a 419-line `src/relay_gun_ffi.erl`: open/await_up, request, SSE using
  `gun:update_flow`, `cancel`, and errors returned as `printable(Reason)` strings. It has no destination policy, pinned DNS,
  header/body limits, typed submission evidence or cassette support. Relay should move to http_gun: `open`/`with_response` for
  JSON-RPC POSTs and `body.next` for the SSE GET stream, plus its own SSE framer. Gaps to close first:
  1. The client-wide `deadline_ms` ceiling also bounds stream consumption, and a per-request deadline can only shorten it.
     A long-lived MCP SSE stream would need a dedicated client with a huge ceiling.
  2. The body is tied to the process that opened it, so the SSE reader process must also be the one that opens the request.
  3. There is no shared generic SSE framer (follow-on scope). llm_wire has its own.

## Ergonomics concerns

1. **No supervised handle that survives a restart** (http_gun.gleam:49-55). `child` returns `ChildSpecification(Client)`, but a
   restart creates a new `Client` and the old one only ever returns `ClientClosed`. There is no `process.Name` or registry variant,
   so every supervised consumer has to republish the client. Warden already does this with `persistent_term` and an unsafe
   `coerce` (warden/src/warden/internal/transport.gleam:147-183, 547-550). This breaks the guideline that startup and supervision
   compose with a normal OTP application (design line 137, guidelines "Specify resource ownership"). Fix: `child(settings, name)`
   plus `named(name) -> Client`, or a `Client` that resolves through a `Name`.
2. **Every operation is doubled with `_with_options`, and the options are incomplete** (http_gun.gleam:75-175).
   `open`, `with_response`, `try_with_response` and `send` each have a `_with_options` twin, giving 8 entry points for 4 operations.
   `batch` (179) has no options. The per-request collect limit cannot be set: `send` hard-wires `pool.config(client).limits.collect_bytes`
   (166). Warden therefore re-implements `send` with `with_response_with_options` plus `body.collect` (warden transport.gleam:249-258).
   The guidelines say to avoid overlapping families for the same operation. One option-taking function per operation, or putting
   deadline, cancel and collect limit into a single `Options` with `default()`, would remove 4 functions and cover Warden's case.
3. **Overlapping offline constructors** (testing.gleam:10-40 vs cassette.gleam:22-39 and 98-103). `testing.start(settings, exchanges)`
   repeats `cassette.new`'s validation and 16 MiB budget, and `cassette.playback` simply calls `testing.start`. Separately,
   `cassette.finish` (143-147) just re-exports `recording.finish` (recording.gleam:225), giving two ways to finish a recording.
   Since `cassette.new(exchanges) |> playback(settings)` already covers scripts, the `testing` module adds no capability.
4. **Startup failures carry strings and are mapped inconsistently** (error.gleam:64-65, 85; config.gleam:79).
   - `InvalidConfig(String)`, `InvalidRequest(String)` and `CaptureFailed(String)` make callers parse text to tell, for example,
     a bad trust anchor from a bad limit. `config.validate` returns `Result(Config, String)`.
   - The same pool start failure is reported three different ways: `ConnectionFailed(UnknownTransport)` (http_gun.gleam:41-46),
     `InvalidConfig("invalid script configuration")` (testing.gleam:33-38) and `ClientClosed` (cassette.gleam:132-135).
     None of these is a transport failure.
5. **Constructor-name collisions across modules**. `error.CaptureFailed(String)` vs `recording.CaptureFailed(CaptureError)`
   (error.gleam:85, recording.gleam:50). `error.Cancelled` vs `fixture.Cancelled` (fixture.gleam:12). `fixture.Complete`/`Failed`
   vs `telemetry.Complete`/`Failed` (telemetry.gleam:40-44). Unqualified imports clash, and the same word means different things
   in different places.
6. **Internal types surface through public aliases** (http_gun.gleam:16-17, 188-189). `pub type Stats = pool.Stats` and
   `Client = pool.Client` point into the internal `http_gun/internal/pool`, so the generated docs never show the fields
   `Stats(connections, bodies, waiting)`. Define `Stats` in the facade, or in `config` alongside `Negotiated`.
7. **Supervision naming differs from siblings**. http_gun and fabric use `child(...)`. warden (`warden.supervised`, warden.gleam:173),
   sinal (`forwarder.supervised`) and grind (`pruner.supervised`) use `supervised(...)`. The ecosystem should pick one.

Not a concern: settings follow the guideline (one pure public record, record-update composition, validation at startup).
`Dynamic` appears in no public signature, and `dev/boundaries.py` enforces that.
