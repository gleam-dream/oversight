# http_gun — release API review

Reviewed 2 October 2026 against `/code/gleam-dream/http_gun` at `a2869b7`, the
[http_gun design](../../http-gun-design.md), the
[API card](../composition/scan/http_gun.md), the
[cross-package review](../composition/FEEDBACK.md) (including "Fix round
results") and the http_gun findings of eight apps. Two scratch consumers back
the claims marked "probe": one compiled today's programs against `a2869b7`,
and one compiled stubs of the proposed facade with a consumer that covers the
common path, a supervised named client, an SSE read and a webhook delivery.

## 1. Verdict

http_gun's runtime contract is strong: bounded admission, owned bodies, pinned
DNS with SSRF checks, typed submission evidence and strict playback worked
unchanged in eight apps. It is not release-ready as an API, because every type
a caller builds is a public record that breaks callers when it gains a field
(`Config`, `Limits`, `destination.Policy`, `request_options.Options`,
`recording.Options`), and every operation has a `_with_options` twin. The
other large problems are one client-wide deadline that bounds every phase and
so blocks long-lived streams, a growing 22-variant `Reason` that consumers
match exhaustively, a supervised handle that dies on restart, and a
per-client destination policy whose one helper covers one of three common
test setups.

## 2. First ten minutes

Main job: GET a URL on a local server and read the status, then stream a
large body.

### Today (probe: compiles against `a2869b7`)

```gleam
import gleam/bit_array
import gleam/http/request
import http_gun
import http_gun/body
import http_gun/config

pub fn fetch(url: String) -> Result(Int, http_gun.Failure) {
  let assert Ok(client) =
    http_gun.start(config.default() |> config.allow_loopback)
  let assert Ok(base) = request.to(url)
  let result = http_gun.send(client, request.set_body(base, <<>>))
  let _ = http_gun.stop(client)
  case result {
    Ok(http_gun.Buffered(response:, ..)) -> Ok(response.status)
    Error(failure) -> Error(failure)
  }
}

pub fn count(client: http_gun.Client, req) -> Result(Int, http_gun.Failure) {
  // The error mapper is required even when it is the identity.
  http_gun.try_with_response(client, req, fn(f) { f }, fn(resp) {
    loop(resp.body, 0)
  })
}

fn loop(stream: body.Body, total: Int) -> Result(Int, http_gun.Failure) {
  // A local wait the newcomer must choose; it is not an idle bound.
  case body.next(stream, 5000) {
    Ok(body.Chunk(bytes)) -> loop(stream, total + bit_array.byte_size(bytes))
    Ok(body.End(..)) -> Ok(total)
    Error(failure) -> Error(failure)
  }
}
```

Buffered path: 2 package imports (`http_gun`, `http_gun/config`) plus
`gleam/http/request`, 7 calls and 6 types (`Config`, `Client`,
`Request(BitArray)`, `Buffered`, `Response`, `Failure`). Streaming adds
`http_gun/body`, a four-argument scope and a magic wait, chosen among 9 entry
points. A stream longer than 30 s fails with `DeadlineExceeded` unless the
whole client gets a longer ceiling.

### Proposed (probe: stubs compile)

`fetch` is unchanged, except that `stop` returns `Nil`. Streaming becomes:

```gleam
pub fn count(client: http_gun.Client, req) -> Result(Int, http_gun.Failure) {
  // No overall budget for this call; connect, pool and idle bounds still hold.
  let stream = client |> http_gun.with_timeout(config.Infinity)
  use resp <- http_gun.with_response(stream, req, fn(f) { f })
  loop(resp.body, 0)  // as today, but `body.next(stream)` takes no wait
}
```

The buffered path keeps 2 package imports, 7 calls and 6 types; it was
already short. The gains are one entry point per operation (4 instead of 9),
`next` without a magic number, one explicit `Infinity` instead of a dedicated
client for long streams, and no caller-built record, so a new option never
breaks this code.

## 3. Target surface

| Module                     | Status              | Key types                                                                                                                    | Key functions                                                                                                                                                                                                                        |
| -------------------------- | ------------------- | ---------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `http_gun`                 | keep                | opaque `Client`, opaque `Message`, `Buffered`, `Stats`, `Negotiated`, `Overflow`, `StartError`                               | `start`, `supervised(config, name)`, `named(name)`, `stop`, `send`, `open`, `with_response`, `batch`, `stats`; views `with_timeout`, `with_deadline`, `with_cancellation`, `with_body_limit`, `with_destination`, `with_correlation` |
| `http_gun/config`          | keep, opaque        | opaque `Config`, `Protocol`, `Trust`, `Timeout`, `ConfigError`                                                               | `default`, `validate`, `describe_error`, `allow_loopback`, `with_protocol`, `with_trust`, `with_destination`, `with_observations`, 4 timeout setters, `with_connection_idle_timeout`, `with_shutdown_timeout`, 10 limit setters      |
| `http_gun/destination`     | keep, opaque        | opaque `Policy`, `Address`, `Class`, `Rejection`, `Resolver`                                                                 | `default`, `loopback_only`, `allow_loopback`, `allow_private`, `only_hosts`, `with_resolver`, `check`, `parse_address`, `classify`                                                                                                   |
| `http_gun/body`            | keep                | opaque `Body`, `Event`, `Collected`                                                                                          | `next`, `next_within`, `close`, `collect`, `protocol`                                                                                                                                                                                |
| `http_gun/error`           | keep, reshape       | opaque `Failure`, `Reason` (may grow), `Kind` (closed), `Evidence` (closed), `LimitKind`, `TransportCause`, `RequestProblem` | `new`, `reason`, `evidence`, `status`, `kind`, `is_retryable`, `name`, `describe`, `to_json`, `decoder`                                                                                                                              |
| `http_gun/deadline`        | keep                | opaque `Deadline`                                                                                                            | `after` (total), `remaining_ms`                                                                                                                                                                                                      |
| `http_gun/cancellation`    | keep                | opaque `Token`                                                                                                               | `with_token` (cannot fail), `cancel`                                                                                                                                                                                                 |
| `http_gun/telemetry`       | keep                | opaque `Id`, `Metadata`, `Milestone`, `Outcome`, `Mode`, `Timing`                                                            | `event`, `new_id`, `id_from`, `id_to_string`                                                                                                                                                                                         |
| `http_gun/testing`         | absorbs `fixture`   | opaque `Exchange`, `Reply`, `Ending`, opaque `Script`                                                                        | `exchange`, `script`, `ignoring_headers`, `matching`, `playback`, `match_key`                                                                                                                                                        |
| `http_gun/cassette`        | absorbs `recording` | `Recorded`, opaque `Recording`, opaque `RecordOptions`, `CassetteError`, `RecordError`, `FinishError`, file causes           | `load`, `parse`, `encode`, `record`, `options`, `with_max_bytes`, `replace_existing`, `finish(recording, wait_ms)`, `abort`, `describe_error`                                                                                        |
| `http_gun/request_options` | delete              | —                                                                                                                            | replaced by client views                                                                                                                                                                                                             |
| `http_gun/fixture`         | merge → `testing`   | —                                                                                                                            | —                                                                                                                                                                                                                                    |
| `http_gun/recording`       | merge → `cassette`  | —                                                                                                                            | —                                                                                                                                                                                                                                    |

| Count                           |                         Today |                               Proposed |
| ------------------------------- | ----------------------------: | -------------------------------------: |
| Public modules                  |                            13 |                                     10 |
| Public functions                |                            48 | 87 (36 of them one-line setters/views) |
| Entry points for HTTP work      | 9 (4 operations × 2, `batch`) |                                      4 |
| Public records                  |   13 (8 of them caller-built) |                      6 (all read-only) |
| Opaque types (incl. `Client`)   |                             7 |                                     13 |
| Records a caller must construct |                             8 |                                      0 |

Setters replace record fields; without setters and views the count is 51
against 47, mostly new `Failure` accessors and codecs. Every remaining record
is read-only, so a new field breaks no caller that matches by label.

## 4. Proposals

### HTTPGUN-R1 Make every caller-built value opaque

- **Problem.** `Config` (config.gleam:39-49), `Limits` (23-37),
  `destination.Policy` (destination.gleam:25-33), `request_options.Options`
  (request_options.gleam:25-32) and `recording.Options` (recording.gleam:29-31)
  are public records. Adding `collect` to `Options` broke llm_wire's labelled
  constructor (FEEDBACK fix round; llm_wire `2dbb41f`), and warden builds
  `Policy` with every label (warden transport.gleam:280-296). Nested updates
  cost lines in every app (WHK-3 status, SSO-9, SD re-run). `default()` builds
  `Limits` from 11 bare positional integers (config.gleam:59-71). The design's
  retained scope (redirects, decompression, proxies, mTLS, redaction; design
  lines 72-79) guarantees these records grow.
- **After.** `config.default() |> config.with_protocol(PreferHttp2) |> config.with_body_limit(1_048_576)`;
  `validate(config) -> Result(Config, ConfigError)` with
  `ConfigError { NotPositive(setting: Setting) EmptyTrustAnchors InvalidAllowedHost(host: String) }`.
  Merge `chunk_bytes` into `with_max_buffered_bytes` (the queue must already
  fit one chunk, config.gleam:125), leaving 10 `with_max_*` limit setters with
  literal names (naming table below).
- **Breaks callers:** yes, mechanically. **Effort:** M.

### HTTPGUN-R2 One entry point per operation; per-call settings become client views

- **Problem.** `open`, `with_response`, `try_with_response` and `send` each
  have a `_with_options` twin (http_gun.gleam:81-201); `batch` takes no
  options (205-211). The guidelines forbid this overlap (card concern 2).
  `try_with_response` adds only an error mapper (128-150), as does
  `cancellation.try_with_token` (cancellation.gleam:50-57). `with_correlation`
  already shows the better shape, a pure client view that apps praised (SSO
  "what worked well", TH-7).
- **After.**

  ```gleam
  // Pure views over one pool; send, open, with_response and batch all honour them.
  pub fn with_timeout(client: Client, timeout: config.Timeout) -> Client
  pub fn with_deadline(client: Client, deadline: deadline.Deadline) -> Client
  pub fn with_cancellation(client: Client, token: cancellation.Token) -> Client
  pub fn with_body_limit(client: Client, bytes: Int, overflow: Overflow) -> Client
  pub fn with_destination(client: Client, policy: destination.Policy) -> Client // narrows only
  pub fn with_response(client: Client, req: Request(BitArray), on_failure: fn(Failure) -> e,
    run: fn(Response(Body)) -> Result(a, e)) -> Result(a, e)
  ```

  Delete `request_options` (`Overflow` moves to the facade) and
  `request_ceiling_ms`. Rename `snapshot` to `stats` and define `Stats` in
  the facade instead of aliasing `internal/pool.Stats` (http_gun.gleam:213-215).
  llm_wire's worker (http_client.gleam:71-80) becomes
  `client |> with_deadline(budget) |> with_cancellation(token) |> with_response(req, f, run)`.

- **Breaks callers:** yes (llm_wire, warden, webhooks, extractor). **Effort:** M.

### HTTPGUN-R3 Name each timeout, and make a long stream an explicit `Infinity`

- **Problem.** One client-wide `deadline_ms` (30 s) bounds every phase. DNS
  uses the remaining request budget rather than `connect_ms`
  (resolution.gleam:44-77). The pool queue and H1 readiness check expire only
  at the request deadline (pool.gleam:266-277, 436-445). Head and body reads
  have no other bound; `body.collect` waits 2^31 ms per read (body.gleam:162).
  A per-call deadline can only shorten the ceiling (pool.gleam:126-133), and
  there is no inter-byte bound. So an SSE read needs a dedicated client with a
  huge ceiling: relay cannot move its MCP GET stream to http_gun (card relay
  gap 1), and research_agent keeps a 120 s and a 5 s client. Raising the
  ceiling also raises the pool, DNS and head-wait bounds. `connect_ms` also
  silently sets the TCP/TLS `send_timeout` (http_gun_ffi.erl:40-42, 62).
- **After.**

  ```gleam
  pub type Timeout { Milliseconds(Int) Infinity }
  config.with_connect_timeout(config, 5000)                 // DNS + TCP + TLS per new connection
  config.with_pool_timeout(config, 5000)                    // waiting for a lease
  config.with_request_timeout(config, Milliseconds(30_000)) // admission to last byte
  config.with_idle_timeout(config, Milliseconds(30_000))    // no bytes while demand is outstanding
  http_gun.with_timeout(client, Infinity)                   // per call, shorter or longer
  body.next(body) -> Result(Event, Failure)
  body.next_within(body, wait_ms: Int) -> Result(Option(Event), Failure) // None: stream intact
  ```

  Each phase is capped by the remaining request time; `Infinity` lifts only
  the overall bound. The idle timer runs only while the body owner has demand
  outstanding (design line 175), so a paused reader is bounded by the request
  timeout alone. Add `IdleTimeout` and `PoolTimeout`; drop `ReadTimeout` from
  `Reason`, since a local wait is not a failure (warden maps it to `Timeout`,
  transport.gleam:427). Write stalls use the idle timeout.

- **Breaks callers:** yes (`next` arity, `ReadTimeout`); default behavior is
  unchanged. **Effort:** L (body owner and pool timers).

### HTTPGUN-R4 Failure: opaque value, closed `Kind`, codecs and typed detail

- **Problem.** `Reason` has 22 variants across four boundaries (request,
  config, cassette I/O, recording; error.gleam:63-86). Warden matches all of
  them (transport.gleam:400-450), so every new reason breaks it, and llm_wire
  re-exports `Reason` publicly (types.gleam:565). `InvalidConfig(String)`,
  `InvalidRequest(String)` and `CaptureFailed(String)` carry decisions in
  strings (error.gleam:64-65, 85). One start failure is reported three ways
  (http_gun.gleam:47-52, testing.gleam:33-38, cassette.gleam:132-135);
  `deadline.after(-1)` returns `InvalidConfig` (deadline.gleam:13-19). The
  status is lost when headers had arrived: WHK-3 was fixed only via
  `Truncate`, because a new field "would break warden's exhaustive match"
  (FEEDBACK fix round). The design's evidence of headers received, byte
  progress and Live or Playback origin (design lines 186-187) cannot be added
  without breaking `Failure(ReadTimeout, _)` matches (llm_wire
  http_client.gleam:189). Apps wrote a 52-line naming table (WHK-6) and a
  129-line codec (CHK-7), although internal/codec.gleam:112-137 has the names.
- **After.**

  ```gleam
  pub opaque type Failure
  pub fn new(reason: Reason, evidence: Evidence) -> Failure  // scripts and fakes
  // Accessors: reason, evidence (closed), kind, describe, to_json and decoder(), plus:
  pub fn status(f: Failure) -> Option(Int)    // Some when final headers were admitted
  pub fn is_retryable(f: Failure, idempotent idempotent: Bool) -> Bool
  pub fn name(f: Failure) -> String           // "connection_failed.connection_refused"
  /// Closed. Branch on this; match `Reason` only for detail, with a `_` arm.
  pub type Kind {
    InvalidInput Refused Unavailable Network TimedOut TooLarge Cancelled Misuse Playback
  }
  ```

  `Unavailable` covers `ClientClosed`, `AdmissionFull` and `PoolTimeout`;
  `Network` covers resolution, connection and request failures; `Misuse` covers
  `ReadConflict` and `WrongOwner`. `InvalidRequest` takes a closed
  `RequestProblem`. `InvalidConfig` moves to `ConfigError`/`StartError`; the
  fixture-load reasons and file causes move to `cassette.CassetteError`;
  `CaptureFailed(String)` becomes `RecordingClosed`; `deadline.after` clamps.
  Document `Reason`, `TransportCause` and `LimitKind` as "may gain variants".
  `is_retryable` encodes the rule three apps rewrote: `NotSubmitted` with
  `Unavailable`, `Network` or `TimedOut` is safe; `MayHaveBeenSent` only when
  idempotent.

- **Breaks callers:** yes (llm_wire, warden and the apps); warden shrinks to a
  `kind` match plus a few detail arms. **Effort:** M.

### HTTPGUN-R5 A supervised handle that survives restarts

- **Problem.** `child(settings) -> ChildSpecification(Client)`
  (http_gun.gleam:55-61) wraps the pool's unnamed subject, so after a restart
  the handle only answers `ClientClosed`. Warden rewrites `persistent_term`
  on every restart (a global GC each time) and reads it back with an unsafe
  `coerce` (warden transport.gleam:146-183, 534-550). The name differs from
  the convention (theme 7).
- **After.**
  `supervised(config: Config, name: process.Name(Message)) -> ChildSpecification(Client)`
  and `named(name) -> Client`, with `Message` opaque; the probe compiles this
  under `static_supervisor`. `Client` holds only the name and view settings;
  checks that read `client.config` today (pool.gleam:126-148) move into the
  pool actor. During a restart, calls fail with `ClientClosed`, `NotSubmitted`
  and kind `Unavailable`. `stop` is documented for `start`ed clients only.
- **Breaks callers:** yes (`child` renamed; warden deletes its shim).
  **Effort:** M.

### HTTPGUN-R6 Destination policy: three setups in one line, per-call narrowing, a public check

- **Problem.** `config.allow_loopback` (config.gleam:84-89) covers "public
  plus loopback" only. "Loopback only" (SSO billing, support_desk) and
  "loopback pinned to `allowed_hosts`" (checkout 13 → 13 lines,
  research_agent 16 → 15, extractor) still need the nested update (fix-round
  re-runs). The policy is per client, so a multi-tenant service keeps a client
  per tier and re-implements the `@internal` checks (destination.gleam:39-73)
  through an Erlang FFI (WHK-4). `allowed_hosts` ignores ports, so pinning
  `127.0.0.1` opens every local port (WHK-4, EXT-7).
- **After.**

  ```gleam
  pub fn loopback_only() -> Policy  // also: default() (public only), allow_loopback, allow_private, with_resolver
  pub fn only_hosts(policy: Policy, hosts: List(String)) -> Policy  // "host" or "host:port"
  pub fn check(policy: Policy, host: String, port: Int) -> Result(Nil, Rejection)  // no DNS
  pub fn parse_address(text: String) -> Result(Address, Nil)
  ```

  The setups become `config.allow_loopback`,
  `config.with_destination(c, destination.loopback_only())`, and
  `destination.loopback_only() |> destination.only_hosts(["127.0.0.1:8080"])`.
  `http_gun.with_destination(client, policy)` intersects per call and never
  widens. Reserved and metadata ranges stay refused.

- **Breaks callers:** yes (`Policy` construction). **Effort:** M.

### HTTPGUN-R7 Test support: matchers, readable cassettes, two modules instead of four

- **Problem.** Playback compares every non-credential header and the exact
  body (fixture.gleam:26-69), so a signed webhook needs an injected clock
  (WHK-7), and fabric and support_desk wrote fake providers instead (SD-7,
  theme 8). Cassette bodies are base64 and unreadable (theme 8).
  `testing.start` duplicates `cassette.new`, which `cassette.playback` only
  forwards to (testing.gleam:10-40, cassette.gleam:98-103); `cassette.finish`
  re-exports `recording.finish` (143-147). Recording has three error types
  plus `error.CaptureFailed(String)`. `fixture.Cancelled`, `Complete` and
  `Failed` collide with `error` and `telemetry` constructors (card concern 5).
- **After.** `http_gun/testing`: `exchange(request, reply)`,
  `script(exchanges) -> Script`, `ignoring_headers(script, names)`,
  `matching(script, fn(expected, actual) -> Bool)`,
  `playback(script, config) -> Result(Client, StartError)`, `match_key`
  (was `sanitise`), and `Ending { Finished(trailers) Aborted(Failure) Abandoned }`.
  `http_gun/cassette`: `load(path, max_bytes) -> Result(testing.Script, CassetteError)`,
  `record(config, path, options) -> Result(Recorded, RecordError)`, and
  `finish(recording, wait_ms)` with 0 meaning immediate. Schema 2 writes a
  chunk as `{"text": ..}` when it is valid UTF-8, else `{"base64": ..}`.
  Strict order, no consumption on mismatch and no network fallback stay;
  the default matcher stays exact. Mismatch reasons become `PlaybackMismatch`
  and `PlaybackExhausted`. Document that playback skips the destination
  policy (WHK-7).
- **Breaks callers:** yes; llm_wire testing uses `fixture.Exchange` and
  `fixture.sanitise` (session.gleam:341-350), and fixtures are re-recorded.
  **Effort:** M.

### HTTPGUN-R8 Correlation from application values; observations without a dedicated forwarder

- **Problem.** `telemetry.Id` comes only from `new_id()` (telemetry.gleam:19-28),
  so apps keep join tables (CHK-5, EXT-4, WHK-5, SD-3, TH-7, RA-7; theme 1).
  Observations need an app-supervised forwarder (TH-11, SD-9, WHK-10).
- **After.** `telemetry.id_from(String) -> Id` and `id_to_string`, or Sinal's
  correlation type once defined. Emit through Sinal's routed path by default;
  `config.with_observations(config, forwarder)` overrides.
- **Breaks callers:** no for `id_from`; routed emission changes a default.
  **Effort:** S, plus Sinal.

### HTTPGUN-R9 Bound the remaining open-ended resources; drain on stop

- **Problem.** `batch` retains up to 10,000 results of up to 8 MiB each until
  it returns, 80 GB in the worst case (BOUNDS.md "Batch"). Idle pooled sockets
  have no time bound (pool.gleam:758-780). `stop` cancels at once, while the
  design specifies bounded draining (design line 127). `cancellation.cancel`
  blocks with `selector_receive_forever` (cancellation.gleam:61-69).
- **After.** `config.with_max_batch_bytes` (64 MiB; later positions fail with
  `LimitExceeded(BatchBytes, ..)` and `NotSubmitted`),
  `with_connection_idle_timeout` (60 s) and `with_shutdown_timeout` (5 s:
  refuse new work, drain, cancel). A plain monitored token process makes
  `with_token` infallible and `cancel` an asynchronous latch.
- **Breaks callers:** no, apart from a new `LimitKind`. **Effort:** M.

### HTTPGUN-R10 Docs and dependencies for a Hex release

- **Problem.** `sinal` is a path dependency (gleam.toml:13), which blocks
  publishing. Exact `gun`/`cowlib` pins (gleam.toml:17-24) block security
  patches for all consumers. Seven of 13 public modules lack a module doc
  (`body`, `cassette`, `config`, `destination`, `fixture`, `testing` open with
  `///`; `error` has none), and `recording`'s describes internals. There is no
  CHANGELOG. Defaults are split between README prose and BOUNDS.md, which
  omits the timeout phases. `docs/` mixes 14 process records with user docs,
  and AGENTS.md says a restart prompt supersedes the oversight design.
- **After.** Publish Sinal first; pin gun and cowlib to
  `>= 2.6.0 and < 2.7.0` and gate the newest patch; add `////` docs, a
  CHANGELOG that lists new `Reason` variants, and section 5 as the README
  defaults table; move process records to `docs/history/`.
- **Breaks callers:** no. **Effort:** S.

### Naming changes folded into the proposals

| Today                                                    | Proposed                                                       | Why                                   |
| -------------------------------------------------------- | -------------------------------------------------------------- | ------------------------------------- |
| `child`, `snapshot`                                      | `supervised`, `stats`                                          | convention; returns `Stats`           |
| `deadline_ms` (a duration), `connect_ms`                 | `request_timeout`, `connect_timeout`                           | `deadline` only for absolute instants |
| `Limits.active`, `waiting`, `queue_bytes`                | `max_open_bodies`, `max_queued_requests`, `max_buffered_bytes` | literal                               |
| `config.Negotiated`                                      | `http_gun.Negotiated`                                          | a response fact, not configuration    |
| `fixture.Complete`, `Failed`, `Cancelled`                | `testing.Finished`, `Aborted`, `Abandoned`                     | collide with `telemetry` and `error`  |
| `error.CaptureFailed(String)`, `recording.CaptureFailed` | `RecordingClosed`; `cassette.RecordError`                      | one name, two meanings                |
| `FixtureMismatch`, `FixtureExhausted`, `sanitise`        | `PlaybackMismatch`, `PlaybackExhausted`, `match_key`           | literal                               |

## 5. Defaults table

| Operation                                   | Current default                                                                                                                                          | Proposed default                                                                  |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| DNS resolution (pinned A/AAAA)              | remaining request budget (up to 30 s)                                                                                                                    | inside the connect timeout, 5 s                                                   |
| Connect (TCP + TLS handshake)               | `connect_ms` 5 s, capped by remaining request time                                                                                                       | `connect_timeout` 5 s including DNS, capped by remaining request time             |
| Socket write stall                          | `send_timeout` = `connect_ms`, 5 s (undocumented)                                                                                                        | idle timeout, documented                                                          |
| Pool checkout (queue wait, H1 readiness)    | no own bound: request deadline (30 s); 128 queued                                                                                                        | `pool_timeout` 5 s; 128 queued                                                    |
| Request overall (admission to last byte)    | 30 s ceiling; a per-call value can only shorten it                                                                                                       | `request_timeout` 30 s; per call shorter or longer; `Infinity` only when explicit |
| Response head wait                          | inside the request deadline                                                                                                                              | inside the request and idle timeouts                                              |
| Idle stream read (no bytes, demand pending) | **none**                                                                                                                                                 | `idle_timeout` 30 s; `Infinity` only when explicit                                |
| `body.next` / `body.collect` per read       | caller-chosen wait (required) / 2^31 ms; both bounded only by the request deadline                                                                       | wait for data or a timeout; `next_within(ms)` polls                               |
| Buffered collection (`send`)                | 8 MiB, fail on overflow                                                                                                                                  | 8 MiB, fail on overflow; status kept in `error.status`                            |
| Batch                                       | 10,000 inputs, 1–1,024 workers; results retained with **no byte bound** (≤ 80 GB)                                                                        | same, plus `max_batch_bytes` 64 MiB                                               |
| Sizes and capacities                        | request body 1 MiB; headers 16 KiB / 100; chunk 64 KiB, queue 128 KiB; connections 16, 4 per origin; H2 streams 100; open bodies 128                     | same, with chunk and queue merged into `max_buffered_bytes` 128 KiB               |
| Idle pooled connection lifetime             | **none** (count-bounded, evicted on demand)                                                                                                              | 60 s                                                                              |
| `stop`                                      | immediate cancel, no drain                                                                                                                               | drain up to 5 s, then cancel                                                      |
| Calls into pool and body actors             | wait forever on a monitored actor; answered within the request deadline                                                                                  | same, documented                                                                  |
| Cancellation token                          | 1 s actor init that can fail; `cancel` **waits forever** for the process to exit                                                                         | spawn that cannot fail; `cancel` is an asynchronous latch                         |
| Scripts, cassettes, recording               | 16 MiB scripts; `load`/`parse` caller `max_bytes`; recording 16 MiB, 10,000 exchanges, refuses an existing file; `finish` immediate or `finish_wait(ms)` | same; `finish(recording, wait_ms)`                                                |
| Destination and TLS                         | public only; loopback and private refused; reserved and metadata always refused; `verify_peer` + hostname, system trust                                  | same (fails closed)                                                               |
| Retries, redirects, decompression, cookies  | none                                                                                                                                                     | none                                                                              |
| Playback matching                           | exact: method, URL, non-credential headers, body                                                                                                         | exact; `ignoring_headers` and `matching` opt in                                   |
| Recording redaction                         | 7 credential headers; bodies and queries exact                                                                                                           | same; open question 6                                                             |
| Observations                                | off unless a forwarder is configured                                                                                                                     | Sinal routed emission; forwarder optional                                         |

No default is infinite today, but only because the 30 s ceiling caps every
phase. Raising it for streams, as research_agent (120 s) and relay (hours)
must, also lifts the pool, DNS, head-wait and inter-byte bounds. R3 separates
them.

## 6. Convention feedback

1. **Opaque config fits; the guidelines must change.** PUBLIC-API-GUIDELINES
   says "Record updates need no duplicate builder for every field." http_gun
   followed it and still broke llm_wire, because nothing stops a caller from
   constructing a record with every label (warden's `Policy`). Cover nested
   values (`Limits`, `Policy`) too. With no required value, say
   `new(required...)` when something is required and `default()` otherwise.
2. **"Returned data may be records" is too broad.** `Failure` is returned, yet
   the design commits it to new facts. A returned type the library will
   extend should be opaque with accessors; public records (`Buffered`,
   `Stats`) need the README to say "match with `..`".
3. **Growing unions.** Gleam has no `non_exhaustive` marker, so a documented
   promise plus a closed `Kind` is the only tool. Translators like warden still
   need detail: say "match the detailed union with a `_` arm" and list new
   variants in the CHANGELOG. For HTTP, `is_retryable` needs the caller's
   idempotency; a one-argument form cannot be right for a POST.
4. **"Bounded by default" needs per-phase bounds.** One deadline meets the
   letter but fails for streams. Add: lifting an outer budget never lifts an
   inner one (connect, queue wait, idle).
5. **Lifecycle.** A restart-stable handle needs a name:
   `supervised(config, name)` plus `named(name)`, the gleam_otp idiom.
   Specify `stop` for `start`ed handles only.
6. **Error naming.** `error.Failure` and `error.describe` read better than
   `error.Error` and `error.describe_error`, which yields `Error(error.Error)`.
   Allow `Failure` and `describe` in a module named `error`. "One error per
   boundary" fits: start, request and cassette I/O, of which two leak into the
   request type today.
7. **Per-call options as handle views** should join the conventions.
   `with_correlation` proved the shape, it satisfies convention 9, and relay's
   client and warden could use it for deadlines and cancellation.
8. **Glossary.** `http_gun/telemetry` with `correlation` already matches. A
   package with live recording needs a second test-support module
   (`cassette`) beside `testing`; allow it.

## 7. Open questions

1. May a per-call `with_timeout` exceed the client's request timeout (one
   shared client for LLM, SSE and REST), or should the client's creator own a
   hard `with_max_request_timeout`? Recommendation: allow it; connect, pool and
   idle bounds still hold.
2. Default idle timeout: 30 s matches today's effective bound, but reasoning
   models can exceed it before the first byte; llm_wire would set its own.
3. Correlation as `String`, an opaque `Id` with `id_from`, or a Sinal
   `Correlation` (theme 1)?
4. The design says observability "must not require another Gleam Dream
   package" (line 10); the conventions make Sinal standard. Which wins decides
   whether `sinal` stays a hard dependency.
5. Can `gun` and `cowlib` move to a patch range, given the FFI relies on
   reviewed Gun 2.6.0 internals?
6. Redaction policy is required scope (design lines 72, 234-236) and absent.
   Is it in the first release?
7. If warden accepts a caller's `http_gun.Client` (SSO-6), per-call narrowing
   (R6) becomes a security boundary with its own conformance tests. Is that
   wanted?
8. Relay's SSE reader must be the opening process (card relay gap 2). Is an
   explicit `body.transfer(body, to: Pid)` in scope (design line 154)?
