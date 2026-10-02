# webhooks — feedback

## Verdict

grind, http_gun and sinal compose into a working webhook service through
public imports only. All 8 tests pass, and `gleam run` prints the full
narrative. Most of the composition is direct. A grind worker is a closure, so
it can capture an http_gun client, and that includes a cassette playback
client. http_gun's typed `Failure` maps cleanly onto grind's
`WorkerResponse`. grind's retry policy receives the typed error, so a 429
can wait exactly as long as `Retry-After` says.

Two grind defects block the intended design. A snooze in a worker that has an
error codec parks the job as a contract mismatch (WHK-1, blocker). The same
worker cannot re-bind its own finished job (WHK-2). Both have workarounds in
the app: 429s become attempt-consuming retries, and finished jobs are read
back through a twin worker. http_gun's destination policy works, including
against DNS rebinding, but it belongs to a client. A multi-tenant app
therefore runs one client per policy tier and duplicates the policy check to
validate endpoints at registration (WHK-4). Following one request across
packages takes app-maintained join tables (WHK-5).

Glue, in non-blank, non-comment lines of app code that exists only to adapt
the packages:

| Seam                                                                |   Glue lines | Where                                                                                                     |
| ------------------------------------------------------------------- | -----------: | --------------------------------------------------------------------------------------------------------- |
| http_gun failure/status → grind outcome                             |          210 | `src/webhooks/attempt.gleam:175-426` (85 of them name and map every `Reason`, 251-343)                    |
| Response body over collect limit, keep status                       |           20 | `src/webhooks/delivery.gleam:193-212`                                                                     |
| Per-tenant destination policy (tiered clients + registration check) | 87 + 22 + 12 | `src/webhooks/egress.gleam`, `src/webhooks/subscription.gleam:100-129`, `src/webhooks_ffi.erl`            |
| Cassettes inside worker tests                                       |       3 + 55 | `Deps.clock` (`src/webhooks/delivery.gleam:39`); `test/webhooks/cassette_test.gleam:38-107`               |
| Re-binding a finished job (grind defect)                            |           30 | `src/webhooks/jobs.gleam`                                                                                 |
| Telemetry: app event descriptor                                     |           30 | `src/webhooks/telemetry.gleam:44-72`                                                                      |
| Telemetry: cross-package correlation (join tables, wiring)          |          ~45 | `src/webhooks/telemetry.gleam:83-175`, `delivery.gleam:114-121`, `service.gleam:133-148`, `web.gleam:166` |
| Two pools, one database (pog async connect, shutdown)               |           15 | `src/webhooks/service.gleam:165-176, 209-212`                                                             |

## Findings

### WHK-1 Snoozing a worker that has an error codec parks the job as a contract mismatch

- **Packages:** grind. **Kind:** defect. **Severity:** blocker.
- **Evidence:** The snooze acknowledgement sets `error_version = NULL`
  (grind `src/grind/internal/attempt/acknowledgement.gleam:229`). When the
  snoozed job is claimed again, the stored error version is compared with
  the registered worker's version (`src/grind/internal/attempt.gleam:605`,
  `696-720`). `NULL` does not match `delivery-error-v1`, so the job is
  recorded as `contract_mismatch` and never runs again. The outcome reads
  `FailedOperationally("stored error codec version none does not match
registered version delivery-error-v1")`. Test:
  `test/webhooks/cassette_test.gleam:173-209`, where the second cassette
  exchange is never consumed. The first `gleam run` showed the same thing
  live for the `/busy` endpoint.
- **Workaround:** `attempt.RetryOnRateLimit` (`src/webhooks/attempt.gleam:202-219,
238-239, 385-389`) maps 429 to `WorkerFailed(RateLimited(ms))`, and the
  retry policy returns `RetryAfter(ms)`. The wait matches `Retry-After`, but
  every 429 consumes an attempt. That is the cost snoozing exists to avoid.
- **Proposal (grind):** keep the job's `error_version` contract column out of
  the per-result fields. Have the snooze, success, discard, cancel and
  runtime-failure ACKs stop writing `error_version = NULL`, or compare the
  contract against a separate column. Add a consumer test that snoozes a
  `define_with_error_codec` worker and then claims it again.

### WHK-2 `bind_handle` fails for a finished job whose worker has an error codec

- **Packages:** grind. **Kind:** defect. **Severity:** major.
- **Evidence:** The success, discard, snooze, cancel and runtime-failure
  ACKs all null `error_version` (`acknowledgement.gleam:181, 229, 243, 256, 282`).
  `bind_handle` compares that column with the worker's error codec
  (`src/grind/internal/postgres/job_reads.gleam:106-114`). Re-binding a
  succeeded delivery returns
  `CodecContractMismatch(ErrorCodec, "delivery-error-v1", "none")`
  (`test/webhooks/delivery_test.gleam:50-56`). The API hands out job ids,
  so this is the ordinary read path after any restart.
- **Workaround:** `src/webhooks/jobs.gleam:17-44` retries the bind through a
  read-only twin definition that has no error codec. It is unregistered and
  needs a dummy `perform`.
- **Proposal (grind):** the WHK-1 fix removes this too. A cheaper interim
  fix is for `bind_handle` to accept a `NULL` stored error version for rows
  in non-failure terminal or scheduled states.

### WHK-3 `send` turns a delivered 200 with a large body into a failure without a status

- **Packages:** http_gun. **Kind:** composition, footgun. **Severity:** major.
  This adds evidence to http_gun card concern 2 (no per-request collect limit).
- **Evidence:** `http_gun.send` collects up to the client-wide
  `collect_bytes` (`http_gun/src/http_gun.gleam:163-167`). An overflow
  returns `Failure(LimitExceeded(CollectedBodyBytes, ..), MayHaveBeenSent)`
  (`src/http_gun/body.gleam:165-176`) and drops the response head. In a
  retrying worker, a receiver that accepted the webhook and echoed a large
  body gets the webhook again on every retry. The cassette test shows both
  sides: the worker records `Receipt(200, BodyOverLimit(1024))`, and `send`
  on the same exchange returns the limit failure
  (`test/webhooks/cassette_test.gleam:145-167`). `gleam run` shows the same
  for the live `/big` endpoint.
- **Workaround:** `delivery.send` (`src/webhooks/delivery.gleam:193-212`)
  uses `try_with_response`, reads the status first, and bounds the body with
  `body.collect`. It treats overflow as a note, not a failure.
- **Proposal (http_gun):** add a per-request collect policy to
  `request_options.Options`, for example
  `collect: Option(Collect(limit: Int, overflow: Truncate | Fail))`, so
  `send_with_options` can return `Buffered` with a truncated body. At
  minimum, document that callers who need the status must stream.

### WHK-4 Destination policy belongs to the client only; the check cannot be reused

- **Packages:** http_gun. **Kind:** flexibility, ergonomics. **Severity:** major.
- **Evidence:**
  - The policy is a field of `config.Config` (`http_gun/src/http_gun/config.gleam:39-48`).
    `request_options.Options` carries only deadline and cancellation
    (`request_options.gleam:7-12`), and `with_correlation` is the only
    per-call view. A multi-tenant app keeps one client, and so one pool,
    per policy tier, and routes each delivery to its tier's client
    (`src/webhooks/egress.gleam:57-104`). The operator's own API client is a
    third policy (`src/webhooks.gleam:76-87`). If tenants had individual
    policies, the app would need a client per tenant. Each restart produces
    a new `Client` value (card concern 1), so the app would also need a
    registry that republishes clients.
  - `allowed_hosts` matches host names but not ports (`destination.gleam:1-2`).
    The internal tier allowlists `127.0.0.1`, which opens every loopback
    port to that tenant.
  - The policy evaluation (`destination.permits`, `permits_host`) is
    `@internal` (`destination.gleam:54-73`), and http_gun parses IP
    literals internally (`internal/bridge.gleam:10`). Registration-time
    validation therefore re-parses IP literals through an Erlang FFI and
    calls `destination.classify` (`src/webhooks/subscription.gleam:100-129`,
    `src/webhooks_ffi.erl:7-11`).
  - Delivery-time enforcement is solid. A rebinding answer that contains
    `10.0.0.7` is refused before connecting, and a loopback URL that slips
    past registration is refused by the public tier
    (`test/webhooks/delivery_test.gleam:93-175`).
- **Proposal (http_gun):**
  1. Make `destination.parse_address(String) -> Result(Address, Nil)` and
     `destination.check(Policy, host: String) -> Result(Nil, Rejection)`
     public. The check answers for IP literals and the allowlist, with no DNS.
  2. Let `request_options.Options` take an optional
     `destination: Option(destination.Policy)` that may only narrow the
     client's policy. Then one public client can serve every tenant, with
     tenant allowlists applied per request.
  3. Optionally, allow `host:port` allowlist entries.

### WHK-5 One delivery can be followed across packages only through app-maintained join tables

- **Packages:** grind, http_gun, sinal. **Kind:** composition. **Severity:** major.
  This adds evidence to the grind card seam "no job id, attempt or
  cancellation signal".
- **Evidence:**
  - grind events key on `job_id` (`observation.gleam:95-97`), but the queue
    handler is `fn(input)` (`worker.gleam:155`) and never learns its job id.
  - http_gun events key on an opaque `request_id` and an optional
    correlation `Id` that only `new_id()` can create (`telemetry.gleam:19-28`).
    The worker cannot derive it from the job or the delivery, and the app
    cannot put it in its own Sinal event because it has no encoder.
  - The app therefore records job id → delivery id at submit time
    (`web.gleam:166`, `service.gleam:146-148`) and correlation `Id` →
    delivery id inside the worker (`delivery.gleam:114-121`), then joins
    them in the collector (`telemetry.gleam:83-175`).
  - Events also arrive through two forwarders, grind's own and the app's
    forwarder for http_gun, so arrival order is not causal. In the
    `gleam run` trace, `grind.job.claimed attempt=2` lands after attempt 2's
    `admission_granted`. grind measurements carry only `count`
    (`observation.gleam:112-114`), so the events cannot be re-ordered by time.
  - In one run, 135 of 231 collected events (mostly `grind.diag.checkout`)
    could not be attributed to any delivery.
- **Proposal:**
  - **grind:** pass a job context (job id, attempt, `RetryContext`) to the
    queue handler; see also WHK-8.
  - **http_gun:** add `telemetry.id(String) -> Id` (or accept a caller
    string as the correlation) and `telemetry.id_to_string`.
  - **grind:** add a monotonic timestamp measurement to `[grind, job, *]`
    events, matching http_gun's `Timing(monotonic_ms)`.

### WHK-6 http_gun failure reasons have no stable public name

- **Packages:** http_gun (into grind). **Kind:** ergonomics. **Severity:** minor.
- **Evidence:** grind persists the typed error through a JSON codec, so the
  delivery error needs a stable string for the transport cause. http_gun has
  one internally (`src/http_gun/internal/codec.gleam:116, 261`) but exposes
  only `error.describe`, a log sentence (`error.gleam:94`). The app writes
  52 lines of naming (`src/webhooks/attempt.gleam:284-343`) next to the
  exhaustive decision mapping (`251-279`). The mapping itself was easy:
  reasons are typed, `Evidence` is explicit, and status is data.
- **Proposal (http_gun):** `error.reason_name(Reason) -> String`, the same
  names the cassette codec uses. A `error.class(Failure) -> Transient |
Permanent | Local` helper would cover most retry mappings.

### WHK-7 Cassette matching is exact and playback skips the destination policy

- **Packages:** http_gun. **Kind:** ergonomics, docs. **Severity:** minor.
- **Evidence:**
  - Cassettes do work inside grind worker tests. The worker's deps hold a
    `cassette.playback` client, and a manual-mode consumer runs real
    attempts offline (`test/webhooks/cassette_test.gleam:112-167`).
  - Matching includes every non-credential header (`fixture.gleam:26-46`).
    The signature and timestamp headers change every second, so the worker
    needs an injected clock (`src/webhooks/delivery.gleam:39`), and the test
    rebuilds the exact signed request (`cassette_test.gleam:38-59`).
    `webhook-signature` is not one of the stripped credential headers.
  - Playback goes straight to `admit_playback` and never reaches
    `admit_live`'s destination check (`src/http_gun/internal/pool.gleam:410-418, 648`).
    SSRF behavior therefore cannot be tested offline, and the app uses the
    `resolver` seam instead.
  - A `FixtureMismatch` is an ordinary `Failure`. Inside a worker it
    becomes a job outcome, here `Reject(Internal("fixture_mismatch.N"))`,
    rather than failing the test loudly.
- **Proposal (http_gun):**
  - Let `cassette.playback` take a matcher option, for example
    `ignore_headers: List(String)`, or a caller `fn(expected, actual) -> Bool`.
  - Document that playback does not apply the destination policy, or apply
    it to the recorded host.

### WHK-8 The queue handler sees neither attempt nor snooze count

- **Packages:** grind. **Kind:** extensibility. **Severity:** minor.
- **Evidence:** `with_queue_handler` takes `fn(input) -> WorkerResponse`
  (`worker.gleam:155, 222-227`), but the registry already runs each
  selection with a `RetryContext` (`registry.gleam:17`). That context has
  `snooze_count` (`worker.gleam:91-93`), and only the retry policy sees it.
  A handler that snoozes on 429 cannot cap the number of snoozes, and a
  snooze rolls `attempt_count` back (`acknowledgement.gleam:229`), so a
  receiver that always answers 429 is retried forever. A worker that only
  uses a queue handler must still pass a `perform` callback to
  `define_with_error_codec`, which the app fills with an adapter
  (`src/webhooks/delivery.gleam:64-75`).
- **Proposal (grind):** `with_queue_handler(fn(input, JobContext) -> WorkerResponse)`,
  where `JobContext` holds the job id, the attempt and the `RetryContext`.
  Also add a `define_queue_worker` that does not ask for `perform`.

### WHK-9 Dependency resolution: grind's stdlib cap rules out the current mist

- **Packages:** grind, http_gun (with mist, glisten). **Kind:** ecosystem-interop. **Severity:** minor.
- **Evidence:**
  - With `mist >= 5.0.0 and < 6.0.0`, the solver picks gleam_stdlib 0.71.0,
    because http_gun requires `>= 0.71.0` (`http_gun/gleam.toml:11`).
    glisten 8.0.3 then fails to compile with
    `The module 'gleam/list' does not have a 'range' value.`
    (`glisten/src/glisten/internal/acceptor.gleam:121`).
  - Switching to `mist >= 6.0.2 and < 7.0.0` resolves to mist 6.0.2,
    glisten 9.0.0, wisp 2.2.2 and stdlib 0.71.0. grind's
    `gleam_stdlib < 1.0.0` (`grind/gleam.toml:10`) keeps the app on that
    line, while a sibling app without grind (`sso_portal`) resolves mist
    6.0.3 and glisten 9.0.1 on stdlib 1.0.5.
  - grind's `pog >= 4.1.0 and < 4.2.0` pin (grind card, Risk 1) held at
    pog 4.1.0 without conflict.
- **Proposal (grind):** widen `gleam_stdlib` to `< 2.0.0`, as http_gun and
  sinal already do.

### WHK-10 Observation wiring differs per package

- **Packages:** http_gun, grind, sinal. **Kind:** ergonomics. **Severity:** nit.
  This is known (sinal card concerns 2 and 6) and adds app evidence.
- **Evidence:**
  - grind owns a forwarder per `Database`, sized by
    `with_observation_capacity`. http_gun emits nothing until the app
    creates and supervises its own forwarder and passes it into `Config`
    (`src/webhooks/service.gleam:79-85`).
  - Attaching to every event takes 19 separate `sinal.observe` calls with
    19 handler ids (`src/webhooks/telemetry.gleam:184-284`).
  - The app's own descriptor needs four `let assert`s on constant inputs
    (`telemetry.gleam:44-72`).
- **Proposal:** http_gun should default to `forwarder.emit_routed`, so the
  app routes `[http_gun]` once. sinal should make `event` and `pair` total,
  as in card concern 2.

## What worked well

- **The grind worker closure is the right seam.** The handler captures an
  http_gun client, the app's pog pool and a clock. Swapping in a cassette
  playback client needed no grind support at all
  (`test/webhooks/cassette_test.gleam:92-107`).
- **The retry policy sees the typed error.** `RateLimited(ms)` →
  `RetryAfter(ms)`, `ClientError` → `DoNotRetry`, and the rest back off
  exponentially (`attempt.gleam:380-401`). Exhaustion comes back typed:
  `BusinessFailedWithCause(Transport("connection_failed.connection_refused"), BudgetExhausted)`
  (`delivery_test.gleam:83-88`).
- **`submit_with_id` gives retry-safe fan-out without transactional
  enqueue.** Re-publishing the same event id converged on the same job
  (`delivery_test.gleam:47-48`).
- **http_gun's destination enforcement is strong.** It checks every A/AAAA
  answer, pins the connection to the checked IP, and always refuses
  metadata and reserved ranges. The `resolver` seam made DNS rebinding
  testable offline. `destination.classify` was directly reusable for
  IPv4-mapped IPv6 (`core_test.gleam:101-102`).
- **http_gun's failure model is easy to branch on.** `Failure(reason,
evidence)` with typed transport causes covered every branch, and status
  as data meant 4xx/5xx/410/429 needed no error plumbing.
- **gleam_http types end to end.** `request.from_uri` → http_gun →
  `response.get_header` needed no adapters, and wisp/mist interop was a
  non-issue.
- **grind's typed outcomes and observations are informative.**
  `acknowledged` carries `proposed` and `committed_state`, which made the
  retry and snooze behavior, and WHK-1 itself, easy to see in the trace.
- **grind installs cleanly in its own schema** (`with_schema("grind")`)
  next to the app's tables in `public`.
