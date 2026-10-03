# webhooks — feedback

## Verdict

grind, http_gun and sinal compose into a working webhook service through
public imports only. All 8 tests pass, and `gleam run` prints the full
narrative. (Re-runs after the package fixes, after wave 2, after the follow-up
fixes and after wave 3, all on 2 Oct 2026: see the last four sections. After
wave 3, 12 tests pass and no finding needs its original glue.) Most of the composition is direct. A grind worker is a closure, so
it can capture an http_gun client, and that includes a cassette playback
client. http_gun's typed `Failure` maps cleanly onto grind's
`WorkerResponse`. grind's retry policy receives the typed error, so a 429
can wait exactly as long as `Retry-After` says.

The first run hit two grind defects: a snooze in a worker that has an error
codec parked the job as a contract mismatch (WHK-1, blocker), and the same
worker could not re-bind its own finished job (WHK-2). grind 7a04831 fixed
both, so the app now runs the intended design: a 429 snoozes for
`Retry-After` without consuming an attempt, and finished jobs are read back
through the worker itself. No blocker remains. http_gun's destination policy works, including
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

- **Status (2 Oct 2026):** resolved by grind 7a04831. 429 maps to
  `WorkerSnoozed` again; the `RateLimitMode` switch, the `RateLimited` error
  variant, its codec branches and its retry-policy branch are gone
  (`src/webhooks/attempt.gleam`, 31 lines removed net).
  `cassette_test.snooze_with_error_codec_runs_again_test` now asserts that the
  snoozed job stays bindable as `Pending(Scheduled)`, runs again, and
  succeeds with both cassette exchanges consumed.

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

- **Status (2 Oct 2026):** resolved by grind 7a04831. `src/webhooks/jobs.gleam`
  (the read-only twin worker, 30 glue lines) is deleted; reads are a plain
  `postgres.bind_handle` with the registered worker, then `postgres.outcome`.
  `delivery_test.common_path_signed_delivery_test` now asserts the re-bind
  succeeds and returns the typed receipt.

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

- **Status (2 Oct 2026):** resolved by http_gun a2869b7 (94b11b9).
  `delivery.send` calls `send_with_options` with
  `Collect(max_body, Truncate)` and reads `Buffered.truncated`; the manual
  `try_with_response` + `body.collect` + `LimitExceeded` match is gone, and
  so is the client-wide `collect_bytes` setting in `egress.Settings`. The
  line count barely moves (19 → 20) because building `Options` takes a
  nested record update (see the re-run section). The cassette test now
  shows both policies on the same exchange: `Fail` loses the status,
  `Truncate` returns the 200 with 1024 bytes and `truncated: True`.

- **Status (wave 3):** resolved by http_gun e55fa1d. An oversized body now
  fails with the status of its response (`error.status(failure) == Some(200)`),
  so the worker uses `with_body_limit(max, Fail)` and one rule in
  `attempt.classify`: a failure that carries a status is classified by that
  status, with `BodyIncomplete(error.name(failure))` as the body note. The
  same rule now also delivers a 2xx whose body read failed mid-stream
  (connection reset, idle timeout), which before this wave was retried and
  delivered twice. `Buffered.truncated`, `BodyOverLimit` and the
  `request_options.Options` record update are gone; `delivery.send` is 20
  lines as before but has no branch. `Fail` drops the response headers, so a
  429 with an oversized body loses its `Retry-After` (see the re-run).

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

- **Status (2 Oct 2026):** partially resolved by http_gun a2869b7
  (ba497b9). `config.allow_loopback` replaces the nested policy update for
  the operator's API client (`src/webhooks.gleam`, 9 lines → 1) and the
  loopback flag of the internal tier. The tier still needs a nested
  `destination.Policy(..base.destination, allow_public:, allowed_hosts:)`
  update, because only loopback has a helper. Every proposal above
  (public `parse_address`/`check`, per-request narrowing, `host:port`
  entries) is still open, so the tiered clients and the FFI stay.

- **Status (wave 3):** resolved by http_gun e55fa1d. All three proposals
  landed. `egress.gleam` keeps one client whose policy is the union of the
  tiers (`destination.default() |> destination.allow_loopback`), and each
  delivery narrows it with `http_gun.with_destination(subscription.policy(tier,
hosts))`, a view that can only narrow. Registration applies the same
  `Policy` value with `destination.check(policy, host, port)`, so the copied
  policy check, `parse_address`, `class_name`-by-classify and the Erlang
  `parse_ip` FFI are gone. `only_hosts` takes `host:port`, so `gleam run`
  pins the internal tier to the receiver's port and refuses
  `127.0.0.1:5432` at registration (`core_test` asserts the same). Glue:
  `egress.gleam` 83 → 49 lines, registration 22 → 5, FFI 5 → 0; the
  operator's API client is one builder chain, loopback only and pinned to
  the API port. The resolver is still client-wide (see the re-run).

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

- **Status (wave 2):** partially resolved by sinal 43279b3 (`sinal/correlation`),
  on the app's side only. The app's own `[webhooks, delivery, attempted]`
  event now carries the delivery id as the shared `correlation` key
  (`correlation.field()`), and the collector's `Delivery(String)` key became
  `Correlated(Correlation)` (`src/webhooks/telemetry.gleam`). Neither join
  table goes away: grind and http_gun do not carry a `Correlation` yet, the
  queue handler still cannot see its job id, and http_gun's correlation is
  still the opaque `telemetry.Id` from `new_id()`. The correlation glue is
  unchanged at ~45 lines, plus a 3-line `delivery_correlation`, because
  `correlation.from_string` can refuse an id (see the wave 2 re-run). Worse
  for native consumers, http_gun already writes its opaque `Id` under the
  same `correlation` key, so an Erlang handler reading `metadata.correlation`
  sees the delivery id in the app's event and a `#Reference<..>` string in
  http_gun's events for the same delivery. The http_gun and grind proposals
  above stay open (HTTPGUN-R8 is the http_gun half).

- **Status (follow-up):** partially resolved by http_gun 056536b (c45adfe);
  the http_gun join table and the key clash are gone. `with_correlation`
  takes the delivery's `Correlation`, so the worker no longer calls
  `new_id`, no `NoteHttp` message, `https` dictionary, `note_http` function
  or `Deps.correlate` callback exists, and `service.gleam` no longer wires
  one. The collector keys http_gun lines as `Correlated(Correlation)`, like
  the app's own event; `Key.Http` is deleted, and `trace` matches both by
  the same text comparison. Native consumers now read the delivery id from
  `metadata.correlation` in both events (http_gun's opaque id moved to
  `request_id`). About 48 correlation glue lines became about 30 (see the
  follow-up re-run). Still open: the job id → delivery id table
  (`web.gleam:166`, `service.gleam:146-148`, `telemetry.note_job`), because
  grind's events carry `job_id` and the queue handler cannot see it; and the
  forwarder ordering and the missing grind timestamps above.

- **Status (wave 3):** resolved by grind 749c0dc. Each job is submitted with
  `job.with_correlation(correlation.from_key(delivery_id))`; grind puts it in
  every `JobRef` (and so in every job event and in renewal diagnostics) and in
  the handler's `Context`, where the worker reads it with
  `worker.correlation(context)` for http_gun and for the app's event. The job
  id → delivery id table (`NoteJob`, `note_job`, the `jobs` dict, `Key.Job`,
  `web.Context.on_submitted` and its wiring) is deleted. Every grind job event
  carries `monotonic_ms`, and http_gun's handlers now run synchronously, so
  the collector orders a trace by the emitters' clock: the `/flaky` trace in
  `gleam run` reads claim → request → attempt → ack for each of the three
  attempts, and `delivery_test` asserts that order. Still unattributed: 213 of
  363 events in one run, all grind diagnostics (`checkout`, `ack`,
  `capacity`) that name no job. A transactional `submit_in` emits no
  `admitted` event, so the trace now starts at the claim.

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

- **Status (wave 3):** resolved by http_gun e55fa1d. The 85 lines that named
  and mapped every `Reason`, `TransportCause` and `LimitKind` are gone.
  `classify` branches on `error.status`, then `error.kind` for `Refused`, and
  sends everything else through `error.is_retryable(failure, idempotent:
True)` (receivers deduplicate on `webhook-id`). `DeliveryError.Transport(String)`
  became `Http(error.Failure)`, stored whole through `error.to_json` and
  `error.decoder()`, so the job outcome keeps the evidence and status, and
  logs use `error.name`. `core_test.error_codec_round_trips_http_failures_test`
  round-trips a failure with a status through the worker's codecs.

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

- **Status (wave 3):** partially resolved by http_gun e55fa1d.
  `testing.ignoring_headers(script, ["webhook-timestamp", "webhook-signature"])`
  replaces the injected clock: `Deps.clock` and `Options.clock` are gone, and
  the test no longer recomputes the HMAC to match (57 → 45 setup lines,
  including a new `with_tape` that starts the whole service on a playback
  client through `egress.Settings.start_client`). The testing module docs now
  say that playback ignores the destination policy, so SSRF tests still use
  the resolver seam. Still open: a `PlaybackMismatch` inside a worker is an
  ordinary failure of kind `Playback`, which the worker rejects as a job
  outcome instead of failing the test loudly.

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

- **Status (2 Oct 2026):** not resolved, and now live. With 429 restored to
  a snooze, the snooze ACK still rolls `attempt_count` back and the handler
  still cannot see `snooze_count`, so a receiver that always answers 429 is
  snoozed forever (at most `SnoozePolicy.maximum_ms`, 1 h, apart). The app
  has no cap; the only bound left is the subscription being disabled by hand.

- **Status (wave 3):** resolved by grind 749c0dc. The worker is
  `worker.responding(id, input:, output:, handle: fn(context, delivery) {..})`,
  with no dummy `perform` and no adapter (12 lines → 0). The handler passes
  `worker.snooze_count(context)` to `attempt.classify`, which snoozes a 429
  at most `SnoozePolicy.max_snoozes` times and then fails the attempt with
  `RateLimited`, so the attempt budget ends the delivery with a typed error.
  `delivery_test.always_throttled_receiver_stops_test` points a delivery at a
  receiver that always answers 429 with `Retry-After: 0`: two snoozes, three
  attempts, five requests, then
  `Failed(Business(RateLimited), Some(BudgetExhausted), _)`. grind's own
  `with_max_snoozes` (100) stays as a backstop; the app caps on the context
  instead because grind's cap ends the job as `BusinessUnrecorded` without
  the app's error or a final delivery-log row.

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

- **Status (2 Oct 2026):** resolved by grind b2545a9 (stdlib `< 2.0.0`).
  The app's own `gleam_stdlib` bound is widened to `< 2.0.0`; `gleam update`
  resolves gleam_stdlib 1.0.5, mist 6.0.3, glisten 9.0.1, gramps 6.0.1,
  gleam_crypto 1.6.0, with wisp 2.2.2 and pog 4.1.0 unchanged.

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

- **Status (wave 2):** partially resolved by sinal 1ff1c18. The 19 attachments
  no longer take handler ids: `watch` lost its `sinal.handler_id` call and
  `let assert`s (19 → 17 lines), and the collector lost the `suffix` field
  and `unique_int` call that existed only to keep handler ids unique per
  collector. The app's descriptor has no `let assert` (4 → 0), and
  `forwarder.new(name)` is total with the 1,024 default, so its
  `let assert` and explicit capacity are gone. Still open: the app needs 19
  `sinal.observe` calls, one per event, because the events have different
  types; and http_gun (1dc20a1) still emits only through the forwarder in
  `config.observations`, so the app still creates, supervises and passes
  its own forwarder (`src/webhooks/service.gleam:78-84`) instead of one
  `forwarder.route(["http_gun"], ..)`. `sinal.emit` now follows routes; the
  remaining step is http_gun emitting with it.

- **Status (wave 3):** partially resolved by http_gun e55fa1d and sinal
  42dd684. http_gun emits through `sinal.emit` by default, so the app's
  forwarder, its supervisor and the `observations` setting are gone
  (6 lines → 0); the collector's one-`process.send` handlers run in
  http_gun's pool and body processes, which keeps them in emit order. The
  collector's attachments use `sinal.observe_labelled(.., "webhooks.collector", ..)`.
  Still 18 `observe` calls, one per event type; a `watch_job` helper over
  `telemetry.JobMeasurements` folds the eight grind job events into one
  shape.

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

## Re-run after fixes (2 Oct 2026)

Heads: grind b2545a9 (includes 7a04831), http_gun a2869b7, sinal unchanged.
Resolved: gleam_stdlib 1.0.5, mist 6.0.3, glisten 9.0.1, wisp 2.2.2, pog 4.1.0.
`../scripts/with-postgres.sh gleam test`: 8 passed, no failures.
`gleam run` prints the full narrative; `/busy` (429) now snoozes and is
delivered on the next claim, and `/big` is delivered as a 200 with its body
truncated at 4096 bytes.

Glue, same measure as the verdict table (non-blank, non-comment lines):

| Seam                                              | Before → after | Change                                                                                    |
| ------------------------------------------------- | -------------: | ----------------------------------------------------------------------------------------- |
| http_gun failure/status → grind outcome           |      210 → 192 | `RateLimitMode`, `RateLimited` and its codec and retry-policy branches removed (WHK-1)    |
| Re-binding a finished job                         |         30 → 0 | `src/webhooks/jobs.gleam` deleted; reads are `bind_handle` + `outcome` (WHK-2)            |
| Response body over collect limit, keep status     |        19 → 20 | manual stream read replaced by `Collect(limit, Truncate)`; `egress.collect_bytes` removed |
| Per-tenant destination policy (`egress.gleam`)    |        87 → 83 | `config.allow_loopback` for the internal tier; nested update still needed for the rest    |
| Operator API client policy (`src/webhooks.gleam`) |          9 → 1 | `config.default() \|> config.allow_loopback`                                              |

Net over the app: 154 lines added, 225 removed (tests included).

New friction from the fixes:

- **`request_options.Options` grew a field, so one setting takes a nested
  record update** (http_gun, ergonomics, nit). Setting only the collect
  policy is
  `Options(..request_options.default(), collect: Some(Collect(limit, Truncate)))`,
  five formatted lines in `delivery.send`, which is why the WHK-3 seam did
  not shrink. A builder such as
  `request_options.default() |> request_options.with_collect(limit, Truncate)`
  would make it one line and survive later fields. The note about building
  `Options` with a record update, never positionally, is now a rule callers
  must know.

  **Status (wave 3):** resolved by http_gun e55fa1d: per-call settings are
  client views (`client |> http_gun.with_body_limit(max, http_gun.Fail)`).

- **Only loopback has a helper** (http_gun, ergonomics, nit). The internal
  tier needs `allow_public: False` and `allowed_hosts`, so it still writes
  `destination.Policy(..base.destination, ...)` and then pipes into
  `config.allow_loopback`, mixing the two styles. `config.allowed_hosts` and
  `config.deny_public` (or one `config.with_destination`) would finish it.

  **Status (wave 3):** resolved by http_gun e55fa1d: `destination.loopback_only()
|> destination.only_hosts(hosts)` and `config.with_destination`.

- **Restoring the snooze makes WHK-8 live** (grind, extensibility, now
  major). See the WHK-8 status: an always-429 receiver is snoozed without
  bound, because the snooze rolls the attempt back and the handler cannot
  see `snooze_count`.
- **Breaking changes absorbed:** none at compile time. Removing the
  `rate_limited` kind changed the error codec's shape, so its version is now
  `delivery-error-v2`; jobs stored under v1 would be reported as contract
  mismatches rather than mis-decoded.

## Re-run after wave 2 (2 Oct 2026)

Heads: sinal a0c05ef (API 1ff1c18, telemetry start 355b100, correlation
43279b3), grind c1920e6, http_gun 1dc20a1. json_blueprint is not a
dependency.
`../scripts/with-postgres.sh gleam test`: 9 passed, no failures (8 before,
plus `core_test.delivery_attempted_event_round_trip_test`, which emits the
app's event through native telemetry and checks the decoded record, the
correlation text, and that an over-long delivery id is emitted without a
correlation). `gleam run` prints the full narrative and the `/flaky` trace
as before. The migration only touched the app's own Sinal code: grind's and
http_gun's descriptors and every field the collector reads compiled
unchanged.

Glue, same measure as the verdict table (non-blank, non-comment lines):

| Seam                                                  | Before → after | Change                                                                                                                         |
| ----------------------------------------------------- | -------------: | ------------------------------------------------------------------------------------------------------------------------------ |
| App event descriptor (`delivery_attempted`)           |        34 → 32 | `pair`/`imap`/`atom.create`/4 `let assert` → record builder; one more key (`outcome` enum) and the shared `correlation` key    |
| App event outcome as a closed enum                    |        10 → 28 | string `attempt.disposition_name` deleted; `Outcome` type (8), `outcome_name` (10), `Disposition → Outcome` mapping (10) added |
| Attachment helper (`watch`) and handler-id uniqueness |        21 → 17 | `handler_id`, two `let assert`s, the collector `suffix` and its `unique_int` call removed                                      |
| http_gun forwarder wiring (`service.gleam`)           |          6 → 6 | `forwarder.new(name)` without `let assert` or capacity; the app still owns the forwarder                                       |
| Cross-package correlation (join tables, wiring)       |      ~45 → ~48 | key type swapped to `Correlation`; `delivery_correlation` (3) added; both join tables stay                                     |
| `sinal.emit` call site                                |        11 → 10 | `let _ =` gone; labelled metadata fields                                                                                       |

Net over `src/`: 83 lines added, 71 removed; tests: 30 added. Without the
enum the migration would have removed lines (−6 net); the enum's +18 is
what grows the app.

New friction from the redesigned APIs:

- **`fields.enum` takes an unchecked value list, and a missing value
  silently detaches the observer** (sinal, defect-prone ergonomics, major).
  The name function is exhaustive, but the list is not:

  ```gleam
  fields.enum(
    "outcome",
    [Delivered, Retried, Snoozed, Gone, Refused, Rejected],
    outcome_name,
  )
  ```

  Add a seventh `Outcome`, extend `outcome_name`, forget the list, and
  everything compiles. Encoding writes the new name; decoding fails with
  "one of …"; `sinal.observe`'s handler has a no-op `on_failure`, so
  telemetry removes it and every later event of that kind is lost for that
  observer. A probe confirmed it: with `fields.enum("t", [A], name)`,
  emitting `B` and then `A` delivers nothing, and `detach` returns
  `Error(Nil)`. Proposal (sinal): the list cannot be checked against the
  type at definition time, so make encoding refuse a value whose name is
  not in the list (a panic at the emit site, where the bug is, instead of
  a silent detach in every observer), and document the hazard on `enum`
  and `observe`.

  **Status (wave 3):** partially resolved by sinal 0d019ea and 5aef827.
  `fields.check` lets a test prove every constructor is listed
  (`core_test.every_outcome_is_listed_test`), and a handler that cannot
  decode now skips the call and stays attached. The list is still unchecked
  at compile time; the test must name every constructor.

- **`fields.enum` costs lines when the domain type carries payloads**
  (ergonomics, minor). The worker's `Disposition` holds receipts and
  reasons, so the event needs its own payload-free `Outcome`, a name
  function and a mapping: 28 lines where `fields.string` with the old
  `disposition_name` took 10. The gain is a typed, closed `outcome` for
  handlers; for a log-only app event the string was enough.
- **The record builder repeats each field three times and does not shrink
  small records** (ergonomics, nit). Each key appears as a `parameter`, a
  constructor label and a getter, and `gleam format` breaks most `and`
  lines, so the one-field measurements record is 8 lines:

  ```gleam
  fields.record({
    use duration_ms <- fields.parameter
    AttemptMeasurements(duration_ms:)
  })
  |> fields.and(fields.int("duration_ms"), fn(m: AttemptMeasurements) {
    m.duration_ms
  })
  |> fields.build
  ```

  It reads far better than `pair`/`imap` over nested tuples and has no
  `let assert`, but the four-key descriptor went only 34 → 32 lines. The
  guide's `fields.field(key, encode, decode.map(..))` form is shorter for
  one-field wrappers; the README could say when to prefer it.

  **Status (follow-up):** partially resolved by sinal 5e8bee3. The
  `parameter` line, the `fn(m: Type)` getter annotation and `build` are
  gone, and each value is bound next to its field and getter, so a swapped
  pair no longer compiles silently. The one-field measurements record went
  8 → 5 lines and the whole descriptor 32 → 30. Each key still appears
  twice (field, getter) plus the constructor label, and `gleam format`
  still breaks most `include` lines, so the four-key metadata block is 22
  lines.

- **A correlation built from an app id is fallible**
  (sinal, ergonomics, minor). The delivery id is `event_id <> ":" <> sub.id`,
  and the event id is publisher input, so `correlation.from_string` can
  return `CorrelationTooLong`. The app emits `None` then
  (`delivery_correlation`), which breaks the trace for exactly the
  deliveries with long ids. The alternatives are a `let assert` (a crash in
  the worker) or a new `correlation.unique()` stored with the job, which
  changes the job codec. The app's own `submission.submission_id` has the
  same shape of bound. Proposal (sinal): document the 128-byte bound next
  to "any application id" in the module doc, and consider a total
  `correlation.derive(String) -> Correlation` that hashes values over the
  bound.

  **Status (wave 3):** resolved by sinal c6e2d36 (`correlation.from_key`).
  `delivery_correlation` is deleted; the event reads `required_field()`, and
  an over-long delivery id gets a stable 64-character digest instead of no
  correlation.

  **Status (follow-up):** not resolved, and wider. `required_field()` does
  not apply: this event cannot promise a correlation, so it keeps
  `correlation.field()` and `Option(Correlation)`, and `delivery_correlation`
  stays. The same `Option` now reaches http_gun: `delivery.deliver` must
  branch (`Some(c) -> with_correlation(client, c)`, `None -> client`), so a
  delivery with an over-long id loses its correlation in the http_gun
  events as well as in the app's event.

- **Same key, different meaning on the wire** (http_gun, sinal,
  composition, minor): see the WHK-5 status. Until http_gun carries a
  `Correlation`, its `correlation` key holds an opaque VM reference string.

  **Status (follow-up):** resolved by http_gun 056536b. The key holds the
  caller's `Correlation`, and the opaque value lives under `request_id`.

Migration guides: the sinal guide was sufficient for every compile error;
each removed item the app used (`handler_id`, three-argument `observe`,
`pair`, `imap`, fallible `event`/`optional`/`forwarder.new`, `emit`'s
`Result`) has a before/after snippet. Gaps: it does not show an
application adopting `sinal/correlation` for its own key (only a package
metadata record), so the 128-byte refusal for derived ids is easy to miss;
it does not warn that a value missing from `fields.enum`'s list detaches
`observe` handlers; and it does not say that http_gun's `correlation` key
is not yet a `Correlation`. The json_blueprint guide does not apply.

## Re-run after the follow-up fixes (2 Oct 2026)

Heads: sinal 6de2b69 (record builder 5e8bee3, `required_field` f9cca37),
grind 2d66835 (fallible encoders c44e4be), http_gun 056536b (caller
correlation c45adfe). json_blueprint is not a dependency, so its follow-up
does not apply.
`../scripts/with-postgres.sh gleam test`: 9 passed, no failures (unchanged).
No test changed: `delivery_test` already asserts that the `/flaky` trace
contains `http_gun.lifecycle` lines, which now reach the delivery through
the `Correlation` key and no longer through the join table. `gleam run`
prints the full narrative and the `/flaky` trace as before; the trace shows
http_gun lines for all three attempts.

Glue, same measure as before (non-blank, non-comment lines):

| Seam                                                | Before → after | Change                                                                                                                                                    |
| --------------------------------------------------- | -------------: | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| App event descriptor (`delivery_attempted`)         |        32 → 30 | `parameter`, `and`, `build` and the getter annotation gone; each value bound by name next to its getter                                                   |
| Codec encoders (`attempt.gleam`, 3 `worker.codec`)  |          0 → 0 | 3 `worker.infallible(..)` wrappers, a 2-line change each (opening and closing) with no new lines; plain gleam_json, no Blueprint bridge here              |
| http_gun correlation (join table, `Deps.correlate`) |       ~16 → ~8 | `new_id`, `correlate`, `NoteHttp`, `note_http`, `https`, `Key.Http` and its collector arm deleted; a 4-line `case` on `Option` and a 3-line `keyed` added |
| Cross-package correlation (job join table, wiring)  |      ~48 → ~38 | the job id → delivery id table, `note_job` and `on_submitted` stay                                                                                        |

Net over `src/`: 48 lines added, 77 removed (comments and blank lines
included; the module doc lost 5 lines of "grind and http_gun do not carry a
correlation yet"). No test lines changed.

New friction:

- **The correlation is `Option` end to end, so every consumer branches**
  (app design plus sinal, minor). `required_field()` would have removed the
  `Some(..)` wrapper and the `None` arm, but only if the id fit in 128
  bytes; see the status on the fallible-correlation note. The cost moved
  rather than vanished: `delivery.deliver` has a `case` and the collector a
  `keyed` helper. A total `correlation.derive` would let both go.

  **Status (wave 3):** resolved by sinal c6e2d36 and grind 749c0dc: the
  correlation comes from the job's context, always present; the `case` and
  `keyed` are gone.

- **`worker.codec` still returns `Result` for a constant version string**
  (grind, ergonomics, nit). The three `let assert Ok(codec) = worker.codec(..)`
  in `attempt.gleam` survive unchanged, so wrapping the encoder in
  `worker.infallible` is purely ceremony here: the app's encoders are
  total, and the `Result` the follow-up added shows up as a visible adapter
  at each of the three call sites. A `worker.codec_total` (or a default of
  total) would spare the common case.

  **Status (wave 3):** resolved by grind 749c0dc: `worker.codec` returns a
  `Codec`; the three `let assert`s are gone.

- **The collector still cannot attribute 148 of 251 events** (grind, composition, minor).
  The `/flaky` run reports them as unattributed; they are grind
  diagnostics (`checkout`, `ack`) with no job id and no correlation. The
  follow-up fixes make http_gun joinable and leave grind as the remaining
  seam (WHK-5, WHK-8).

Migration guides: the sinal record-builder rule, the grind wrap and the
http_gun before/after snippets were sufficient and accurate for this app,
and the dependents table named every webhooks call site. One miss: the
http_gun guide lists `delivery.gleam:44,117,121` and
`telemetry.gleam:113,129,138,178,284,304` but not `service.gleam:133`
(the `Deps.correlate` closure that disappears with the join table), which
is visible only once `Deps` loses the field.

## Re-run after wave 3 (2 Oct 2026)

Heads: grind 008b657 (facade 749c0dc), http_gun 1a5f5ef (redesign e55fa1d,
labels 1a5f5ef), sinal 44c5395 (`from_key` c6e2d36, `fields.check`
0d019ea, labels 42dd684). Resolved: gleam_stdlib 1.0.5, mist 6.0.3,
glisten 9.0.1, wisp 2.2.2, pog 4.1.0. json_blueprint and saga are not
dependencies.
`../scripts/with-postgres.sh gleam test`: 12 passed, no failures (9 before).
New: `core_test.error_codec_round_trips_http_failures_test`,
`core_test.every_outcome_is_listed_test`,
`delivery_test.always_throttled_receiver_stops_test` (WHK-8, the defect
turned into a test of the bound). Every test that drove a manual consumer
with `process_one`/`process_available` now asserts a count from
`testing.drain`. `gleam run` prints the full narrative: `/throttled` snoozes
three times and fails after three attempts, `/big` is delivered as a 200
whose body was not read, `127.0.0.1:5432` is refused at registration by the
internal tier's `host:port` allowlist, and the `/flaky` trace is in causal
order.

Glue, same measure as before (non-blank, non-comment lines):

| Seam                                                      |       Before → after | Change                                                                                                                                                            |
| --------------------------------------------------------- | -------------------: | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| http_gun failure/status → grind outcome (`attempt.gleam`) |            192 → 120 | the 85-line `Reason`/`TransportCause`/`LimitKind` naming and mapping → a status, `Refused` and `is_retryable` branch; snooze cap +3; `retryable` shared by policy |
| Delivery error codec (transport cause)                    |              37 → 32 | `Transport(String)` → `Http(error.Failure)` via `error.to_json`/`decoder`; `let assert` on `worker.codec` gone (×3)                                               |
| Response body over the read limit, keep status            |              20 → 20 | `Truncate` + `Buffered.truncated` → `Fail` + `error.status`; no branch left, the status rule lives in `classify`                                                  |
| Per-tenant destination policy (`egress.gleam`)            |              83 → 49 | two tier clients → one client and a `with_destination` view per delivery                                                                                          |
| Registration policy check (`subscription.gleam`, FFI)     |           22 + 5 → 5 | `parse_address` + `classify` + `parse_ip` FFI → `destination.check(subscription.policy(tier, hosts), host, port)`                                                 |
| Operator API client policy (`src/webhooks.gleam`)         |                1 → 6 | `config.allow_loopback` (which also admitted public hosts) → loopback only, pinned to the API port, without observations                                          |
| Cassettes inside worker tests                             |          3 + 57 → 45 | `Deps.clock`/`Options.clock` gone (`ignoring_headers`); `worker_with` and a second consumer → `with_tape` starts the service on a playback client                 |
| Queue handler without `perform` (WHK-8)                   |               12 → 0 | `worker.responding`                                                                                                                                               |
| Snooze bound (WHK-8)                                      |           (none) → 3 | `max_snoozes` and a `429 if snoozes >= ..` arm, fed by `worker.snooze_count(context)`                                                                             |
| Cross-package correlation (job join table, wiring)        |             ~38 → ~6 | `NoteJob`, `note_job`, `jobs` dict, `Key.Job`, `on_submitted` deleted; `from_key` at submit, `worker.correlation` in the worker                                   |
| Trace ordering (new)                                      |               0 → 18 | `Line.at`, `watch_job` over `JobMeasurements.monotonic_ms`, a sort in `trace`                                                                                     |
| Two pools, one database                                   |               15 → 0 | `migrate_with_retry` (grind waits for its first connection) and the pog `shutdown` exit gone; one `pog.Config` given to `grind.new`                               |
| http_gun forwarder wiring (`service.gleam`)               |                6 → 0 | events follow `sinal.emit`                                                                                                                                        |
| Manual consumers and polling                              | 26 (+28 in main) → 0 | `start_consumer*`, `manual_policy`, `with_consumer`, `await_outcomes` → `without_consumers` + `testing.drain` in tests, consumers + `grind.await` in `main`       |

Net over `src/`: 507 lines added, 735 removed (non-blank, non-comment:
2,132 → 1,921). Tests: 298 added, 216 removed, for 3 more tests.

Seams that still need glue, and who owns them:

- **The `Disposition` → `worker.Response` mapping and the retry policy**
  (app). This is domain logic, not glue: which statuses retry, snooze or
  disable is the webhook service's decision.
- **Diagnostics without a job** (grind). 213 of 363 events in one `gleam run`
  name no job (`checkout`, `acknowledgement`, `capacity`), so a per-delivery
  trace cannot include the storage calls a delivery made. An optional
  `JobRef` on `checkout` for job-scoped operations would close it.
- **`PlaybackMismatch` inside a worker** (http_gun, WHK-7). A test that
  scripts the wrong request sees a rejected job, not a test failure.
- **18 `sinal.observe` calls** (sinal, WHK-10). One per event type; inherent
  to typed events.

New friction:

- **A view can only narrow, so the client carries the union policy, and a
  call that skips the view gets it** (http_gun, footgun, major). Narrowing is
  the right rule, but it inverts the old safety property. Before, the public
  tier's client could not reach loopback at all. Now the one client admits
  public and loopback, and the public tier is safe only because every send
  goes through `egress.client_for`:

  ```gleam
  // Safe: narrowed to the tenant's tier.
  egress.client_for(deps.egress, tier) |> http_gun.send(req)
  // Compiles, and lets a public tenant's URL reach 127.0.0.1.
  deps.egress.client |> http_gun.send(req)
  ```

  The app keeps the field public because the cassette test reads it. A
  client whose own policy is the narrowest tier, with views that may only
  _swap within_ an allowlist fixed at start (for example
  `config.with_destinations([public, internal])` and
  `http_gun.with_destination_named("internal")`), would keep the per-request
  routing without a permissive base. Short of that, the module docs could
  say that the base policy is reachable by any caller holding the client.

  **Status (wave 3 fixes):** resolved by http_gun 0bf369f; the base client sets `config.require_view_destination`, so a call that skips `egress.client_for` fails with `ViewDestinationRequired` (`NotSent`, `Refused`). `cassette_test.request_without_tenant_view_is_refused_test` pins it, and the direct sends in the cassette tests now go through the view.

- **The resolver is client-wide and cannot defer to DNS** (http_gun,
  flexibility, minor). With one client, the test resolver now answers for
  every tier, so the internal tier's `localhost` entry no longer resolves in
  tests (the tests and `gleam run` use `127.0.0.1`). A `config.Resolver`
  cannot fall back to the system resolver for names it does not script.
  Proposal: a public `destination.system_resolve(host, remaining_ms)`, or a
  resolver result that means "use DNS".
- **`Fail` keeps the status but not the headers** (http_gun, minor). With
  `with_body_limit(max, Fail)`, a 429 whose body exceeds the limit loses its
  `Retry-After`, so the delivery snoozes for the default 60 s. `Truncate`
  keeps the head but needs a second branch on `Buffered.truncated`. The app
  chose `Fail` for one rule; `error.headers(failure)` (or the head on a
  `LimitExceeded` failure) would make it lossless.

  **Status (wave 3 fixes):** resolved by http_gun 0bf369f; `attempt.classify` reads `Retry-After` from `error.headers(failure)`, so an oversized 429 snoozes for the receiver's value. `cassette_test.oversized_429_keeps_retry_after_test` asserts 120 s.

- **One pool means grind's `search_path`** (grind, ergonomics, minor). The
  pool's `search_path` is grind's schema only, so every app statement on it
  qualifies its tables (`public.webhook_subscriptions`, nine statements).
  Keeping grind in `public` avoids it but gives up the separate schema. A
  `search_path` of `grind, public` (or `grind.with_search_path`) would let an
  app keep both.

  **Status (wave 3 fixes):** resolved by grind 9ccbfb5; the pool keeps the app's `search_path`, and the nine `public.`-qualified statements (store and test truncate) are unqualified again. `with_schema("grind")` stays.

- **`submit_in` has no `admitted` event** (grind, observability, minor). The
  commit belongs to the app, so grind cannot prove it, and the trace of a
  transactionally published delivery starts at the claim. The docs say so.
  A `grind.announce(jobs, admission)` that the app calls after its commit
  would restore the event without a false claim.

  **Status (wave 3 fixes):** partially resolved by grind eb7b173; documented recipe (record the admission after the commit), not adopted here. The `Existing`/`Rescheduled` branch now uses `grind.handle(admission)`.

- **The job's correlation is opt-in per submit** (grind, ergonomics, nit).
  Without `job.with_correlation`, grind generates a random correlation and
  the delivery's trace splits from the app's own key. A job with an id could
  default to `correlation.from_key(id)`; this app would then drop the line,
  and every app that submits with ids would join by default.
- **The worker needs the pool before grind starts it** (grind, nit). The
  worker is registered in `grind.Config`, but `grind.connection` panics until
  `start` has run, so the worker's deps reach the pool through
  `pog.named_connection(pool_name)`, which works because grind keeps the
  config's pool name. A sentence on `grind.connection` saying that the pool
  is `pog.named_connection` of the config's name would make this a
  documented path.

  **Status (wave 3 fixes):** resolved by grind 9ccbfb5; the handler uses `worker.connection(context)`, `Deps.db` and the pool-name lookup are gone, and `grind.with_startup_migration` replaces the separate `grind.migrate` call.

- **`grind.stop` logs a pgo supervisor report** (grind, nit). The first
  `grind.stop` in a test run logs `SUPERVISOR REPORT ... pgo_pool_sup
shutdown_error {reload, ..}` while a connection starter is mid-reload.
  Tests pass; the report is noise.
- **`supervised`/`named` were not adopted here** (app, not a package
  defect). The service is started and stopped once per test, and stopping a
  `static_supervisor` tree still takes an unlink and an exit signal, which
  is the glue the one pool just removed. `grind.start`/`stop` and
  `http_gun.start`/`stop` are the documented script-and-test path.

What composed cleanly in this wave:

- `testing.drain(jobs, queue:, limit:, within:)` with `without_consumers`
  replaced every manual consumer and returns the count the tests assert.
- `grind.submit_in` put the job and the delivery row in one
  `pog.transaction`, so a failed `record_delivery` rolls the job back, and a
  resubmit under the same id converges on the first admission.
- The retry policy is `fn(error, attempt) -> RetryDecision` returning a
  `Duration`: no `RetryFailure` unwrap, no fallible `retry_delay`.
- `error.is_retryable(failure, idempotent: True)` matched the webhook rule
  exactly, and `error.to_json`/`decoder` let the job error keep the whole
  failure.

Migration guides: the grind and http_gun guides were sufficient. Every
compile error had a row, and both index sections named this app's symbols
and pointed at the right replacement (`destination.parse_address` for the
FFI, `error.kind`/`name` for `attempt.gleam`, `with_destination` views for
`egress.gleam`, `testing.drain` for manual polling). Gaps: the http_gun guide
shows a view narrowing the policy, but not that the base client must
therefore admit the union of every view, nor the footgun above; and the grind
guide does not mention that a pool shared with the app pins `search_path`
to grind's schema. The grind README says "qualify tables in other schemas",
so the app qualified them up front; an unqualified app query on that pool
would fail only at run time. The sinal additions applied as documented
(`from_key`, `fields.check`, `observe_labelled`).

### After the follow-up fixes

`../scripts/with-postgres.sh gleam test`: 14 passed (12 before); `gleam run`
prints the same narrative. Removed from `src/`: about 14 lines (the
`grind.migrate` block, `Deps.db` and its `pog` import, the `Conflict` branch,
the nine `public.` qualifiers changed in place). Added: about 16 (the
`require_view_destination` line and its docs, `with_startup_migration`, the
`Retry-After` read, the `grind.handle` arm). Tests: about 55 added for two
new tests, 3 changed (direct sends go through `client_for`; `public.` dropped
from the truncate).
