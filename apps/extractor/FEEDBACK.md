# extractor — composition feedback

## Verdict

The combination works through public imports. A batch of documents becomes
Grind jobs; each job fetches with a bounded http_gun stream, extracts a typed
`Invoice` through llm_wire structured output on OpenAI Responses, Anthropic
Messages or Google, and stores it in Postgres. 11 tests pass and `gleam run`
prints the demo batch.

- No blocker remains. The Grind defect that blocked the intended design
  (EXT-1, a snoozed job with an error codec re-claimed as a contract
  mismatch) is fixed in grind 7a04831: the worker keeps its error codec,
  snoozes on a 429, and an exhausted retry reads back as the app's typed
  `JobError` with its detail.
- The rest is glue, about 225 lines across five seams (see the glue measure).
  The largest pieces are the llm_wire-to-Grind failure mapping and the
  telemetry correlation registry.
- Structured output is portable across the three providers for a closed,
  all-required schema. Per-provider code is 1 to 6 lines.

## Answers to the brief's questions

- **Is a 6+ field Blueprint codec with a nested list and an enum ergonomic?**
  It is correct and produces a good schema, but it costs 57 lines: five
  `combine` calls, nine `let assert`s on static definitions, and a five-level
  nested tuple written in both directions (EXT-6). `string_enum`,
  `integer_between`, `describe` and `try_imap` work well.
- **Is structured output portable across providers?** Yes for a closed object
  with required properties: one request, one codec and one result type serve
  all three adapters, and a 429 from each wire yields the same
  `HttpStatusError(429, _, Some(RetryDelaySeconds(2)))`. A `nullable` field
  prepares on OpenAI and Anthropic and fails preparation on Google, before
  any I/O (test `nullable_output_field_is_not_portable_to_google_test`).
- **Does llm_wire's retry vocabulary map onto Grind's outcomes without
  strings?** Only for an HTTP status with a numeric `Retry-After`:
  `RetryDelaySeconds(Int)` becomes `worker.retry_delay` directly. Transport
  failures, HTTP-date hints and invalid output need app classification or
  carry strings (EXT-2, EXT-3). Grind's snooze and discard reasons are
  strings by design.
- **One http_gun client or two?** Two. The fetcher follows URLs that arrive
  with the batch, so it admits only document hosts, a 5 s deadline and a
  small pool. The LLM client needs a 120 s deadline ceiling and admits only
  provider origins. One client would apply one destination policy to both, so
  a hostile document URL could reach the provider origin; the test
  `fetcher_cannot_reach_the_provider_origin_test` shows each client rejecting
  the other's destination with `DestinationRejected` and `NotSubmitted`.

## Findings

### EXT-1 A snoozed job with an error codec is re-claimed as a contract mismatch

- **Packages**: grind. **Kind**: defect. **Severity**: blocker.
- **Evidence**:
  - The snooze acknowledgement clears the stored error codec version:
    `error_version = NULL` in the `snoozed` UPDATE
    (grind/src/grind/internal/attempt/acknowledgement.gleam:229).
  - The next claim reads `error_version` (grind/src/grind/internal/attempt.gleam:500, :522)
    and compares it with the registered error codec version
    (attempt.gleam:605-612, :696-718). `None` differs from `Some("job-error-v1")`,
    so the job becomes `contract_mismatch` and the handler never runs again.
  - The column holds two meanings: the job's registered error contract,
    written at admission, and the version of a stored error value.
  - App test `snooze_with_error_codec_is_a_contract_mismatch_test`
    (apps/extractor/test/extractor_test.gleam:387) gets
    `FailedOperationally("stored error codec version none does not match registered version job-error-v1")`,
    and the provider sees one call instead of two.
  - Grind's snooze tests do not re-claim a snoozed job of a worker defined with
    `define_with_error_codec` (grind/test/grind/queue/retry_test.gleam:132-137).
  - Workaround: `jobs.DescriptionOnly` defines the worker with `worker.define`
    (apps/extractor/src/extractor/jobs.gleam:55-100). An exhausted retry then
    reads back as `FailedOperationallyWithCause("worker returned an application error", BudgetExhausted)`
    (grind/src/grind/worker.gleam:476-483; grind/src/grind/internal/postgres/job_reads.gleam:520-534).
    The app's `JobError` and its detail (`Connection failed: ...`) are both
    lost (extractor_test.gleam:311-329). This adds evidence to the grind card's
    concern 3.
- **Proposal** (grind): keep the job's registered error contract version in
  a column that acknowledgements never clear, separate from the stored error
  value's version; at minimum, leave `error_version` unchanged in the snooze
  UPDATE. Add a test that snoozes and re-claims a `define_with_error_codec`
  worker.
- **Status (2 Oct 2026):** resolved by grind 7a04831; the worker is always
  defined with `define_with_error_codec` and snoozes on a 429. The
  `ErrorRetention` type, its `DescriptionOnly` branch and the `retention`
  parameter of `jobs.start` are gone (12 glue lines in jobs.gleam, the
  9-line `with_retention` test wrapper, 5 lines in extractor.gleam). An
  exhausted retry now reads back as
  `BusinessFailedWithCause(Transient(Extract, "Connection failed: ..."), BudgetExhausted)`.
  The defect test became `snoozed_job_with_error_codec_runs_again_test`: the
  snoozed job runs again (two provider calls, `SucceededWith`), and
  `postgres.bind_handle` re-binds the finished job with the same outcome.

### EXT-2 llm_wire retry advice needs app classification before it becomes a Grind outcome

- **Packages**: llm_wire, grind, http_gun. **Kind**: composition. **Severity**: major.
- **Evidence**:
  - `retry.assess` returns `Unknown` for every `HttpFailure`
    (llm_wire/src/llm_wire/retry.gleam:39), although http_gun's `Reason` is
    typed. The app classifies http_gun reasons itself
    (apps/extractor/src/extractor/outcome.gleam:93-94, :104-118).
  - `MayHelp` does not say whether to wait for a hint or retry with backoff.
    The app branches on the `WireError` variant to choose snooze or retry
    (outcome.gleam:81-92).
  - `RetryHeaderValue(String)` keeps an HTTP-date for the caller to parse
    (llm_wire/src/llm_wire/types.gleam:579-583). The app falls back to a
    default delay (outcome.gleam:120-125).
  - `RunFailure` omits the provider (llm_wire/src/llm_wire/session.gleam:52),
    and `prepared_provider` exists only for `PreparedCall`, not for
    `PreparedStructuredCall` (session.gleam:167). The app recovers it with
    `provider.identity(config.adapter(model.settings))`
    (apps/extractor/src/extractor/llm.gleam:146). This adds structured-call
    evidence to the llm_wire card's concern 2.
  - The mapping is 78 lines (outcome.gleam:52-138).
- **Proposal** (llm_wire): one `retry.advise(failure: RunFailure) -> RetryAdvice`
  with `RetryAdvice(prospect: RetryProspect, after_ms: Option(Int))`, where
  `RunFailure` carries the provider. It classifies http_gun reasons
  (connection, request and deadline failures as `MayHelp`; `DestinationRejected`,
  `InvalidRequest` and limit failures as `WillNotHelpUnchanged`) and parses
  HTTP-date `Retry-After` into milliseconds. The app mapping would then be
  about 10 lines.

### EXT-3 Invalid structured output loses the raw output and the typed reason

- **Packages**: llm_wire, json_blueprint. **Kind**: ergonomics. **Severity**: major.
- **Evidence**:
  - Schema and codec failures become `OutputValidationError(String)` built with
    `string.inspect` (llm_wire/src/llm_wire/internal/schema.gleam:317-330).
    The demo persists Gleam debug text as Grind's discard reason:
    `Structured output failed schema validation: ValidationError([Property("currency")],...`.
  - The app tells a schema rejection from a codec rejection only by string
    prefix (apps/extractor/test/extractor_test.gleam:262-268).
  - The rejected model output is unavailable on failure; only
    `StructuredValue.raw_json` carries it, on success.
  - The failure travels through `read_failure` with
    `RetryEvidence(EffectUnknown, True, True)` (session.gleam:106-109) although
    the response completed.
  - This adds evidence to the llm_wire card's concern 3 and the
    json_blueprint card's concern 4.
- **Proposal** (llm_wire): `OutputValidationError(raw_output: String, failure: OutputFailure)`
  with `OutputFailure = InvalidJson(parser.ParseError) | SchemaRejected(runtime.ValidationError) | CodecRejected(codec.DecodeError)`,
  and retry evidence that records a completed response. json_blueprint adds a
  renderer for `runtime.ValidationError`.

### EXT-4 One job cannot be followed across packages without an app registry; llm_wire events cannot be attributed

- **Packages**: llm_wire, http_gun, grind, sinal. **Kind**: composition. **Severity**: major.
- **Evidence** (test `one_job_is_followed_across_packages_test`, extractor_test.gleam:362):
  - Grind events carry `job_id`, but the handler never learns its job id. The
    app records job id to document id at submission
    (apps/extractor/src/extractor/jobs.gleam:290-302).
  - http_gun events carry an opaque correlation `Id` that only `new_id()`
    creates (http_gun/src/http_gun/telemetry.gleam:19-28). The app cannot use
    its document id as the correlation, so it keeps an `Id` to document table
    (apps/extractor/src/extractor/telemetry.gleam:156-175). The metadata does
    not name the client, so fetcher and LLM requests differ only by order.
  - llm_wire metadata is `Metadata(stage, provider, outcome)` with no request
    or correlation id (llm_wire/src/llm_wire/telemetry.gleam:17-19). Only
    `prepared` runs in the worker process; `request_sent`, `first_progress`,
    `terminal` and `cleanup` run in the stream owner
    (llm_wire/src/llm_wire/internal/owner.gleam:416, :532, :684, :823, :916).
    The test attributes 1 of 5 llm_wire events; the demo batch leaves 23
    llm_wire events unattributed.
  - The correlation glue is about 60 lines (telemetry.gleam:39-60, :156-210).
- **Proposal**:
  - llm_wire: take the correlation of the `http_gun.Client` view passed to
    `run`/`stream` and add `request_id` and `correlation` to `Metadata`.
  - http_gun: `telemetry.id_from(String)` so a caller key can serve as the
    correlation, and a client label in `Metadata`.
  - grind: a handler job context with job id and attempt (grind card,
    "Calling other packages from a worker").

### EXT-5 One Blueprint codec cannot serve as a Grind codec or a pog row decoder

- **Packages**: json_blueprint, grind. **Kind**: ecosystem-interop. **Severity**: major.
- **Evidence**:
  - `worker.codec` takes `fn(v) -> json.Json` and `decode.Decoder(v)`
    (grind/src/grind/worker.gleam:21). Blueprint offers `encode_json -> String`
    and `decode_json(String)` (json_blueprint/src/json/blueprint/codec.gleam:174, :182).
  - The app stores the invoice as Blueprint JSON text inside a JSON string,
    so the Grind output column holds a string instead of an object
    (apps/extractor/src/extractor/jobs.gleam:181-207).
  - The pog row decoder reads `payload::text`, calls `decode_json`, and needs
    a placeholder `Invoice` for `decode.failure`
    (apps/extractor/src/extractor/store.gleam:92-105, :128-130).
  - A lossless `Value -> json.Json` bridge cannot be written with gleam_json,
    because non-integer numbers must pass through `Float`.
  - This adds evidence to the json_blueprint card's concern 5 and the grind
    card's codec seam.
- **Proposal** (json_blueprint): `codec.to_json(codec, value) -> Result(json.Json, EncodeError)`
  and `codec.decoder(codec) -> decode.Decoder(a)`. The Grind codec becomes one
  `worker.codec(version, to_json, decoder)` call and the placeholder disappears.

### EXT-6 A six-field record codec needs combine chains and nested tuples

- **Packages**: json_blueprint. **Kind**: ergonomics. **Severity**: minor.
- **Evidence**: `invoice.codec()` is 57 lines
  (apps/extractor/src/extractor/invoice.gleam:45-101): five `combine` calls,
  nine `let assert`s on constant definitions, and the tuple
  `#(#(#(#(#(vendor, number), issued_on), currency), line_items), total)`
  written in both directions (:77, :89-100). `record3` covers `LineItem`;
  `Invoice` falls off the arity cliff (json_blueprint card concern 2). The
  cross-field total check in `try_imap` produces a located
  `DecodeAtField("total_cents", ...)` error, which works well.
- **Proposal** (json_blueprint): a `use`-based record builder, for example
  `use vendor <- codec.property("vendor", codec.string(), fn(i) { i.vendor })`
  ending in `codec.build(Invoice(..))`, returning one `Result` for duplicate
  names.

### EXT-7 llm_wire and http_gun define loopback differently

- **Packages**: llm_wire, http_gun. **Kind**: flexibility. **Severity**: minor.
- **Evidence**:
  - llm_wire admits plaintext only when the endpoint host string is
    `localhost` or `127.0.0.1` (llm_wire/src/llm_wire/internal/api.gleam:1472).
  - http_gun classifies resolved addresses and accepts a test `Resolver`
    (http_gun/src/http_gun/destination.gleam:22). The fetcher maps
    `docs.example.test` to 127.0.0.1 (apps/extractor/src/extractor/clients.gleam:43-50);
    the LLM endpoint cannot use such a name.
  - `allowed_hosts` ignores ports (destination.gleam:55), so the document
    server and the provider server, both on 127.0.0.1, are separated only by
    host name. The LLM client therefore allows host `127.0.0.1`, which also
    covers the document server's port.
  - Loopback setup itself was easy: one nested record update per client.
- **Proposal** (llm_wire): admit `http://` when http_gun's destination check
  classifies the resolved address as loopback, instead of matching the host
  string. http_gun could add optional ports to `allowed_hosts` entries.
- **Status (2 Oct 2026):** partially resolved by http_gun a2869b7;
  both clients start from `config.default() |> config.allow_loopback`, which
  removes the two `allow_loopback: True` field lines (clients.gleam:30, :54).
  Both clients still need the nested `destination.Policy` update for
  `allowed_hosts` (and the fetcher for its `resolver`). llm_wire still matches
  the host string (llm_wire/src/llm_wire/internal/api.gleam:1472), and
  `allowed_hosts` still ignores ports.

### EXT-8 A queue handler still requires an unused `perform` function

- **Packages**: grind. **Kind**: ergonomics. **Severity**: minor.
- **Evidence**: `define` and `define_with_error_codec` require
  `perform: fn(input) -> Result(output, error)` (grind/src/grind/worker.gleam:162, :173),
  and `with_queue_handler` replaces it for every queued attempt (:222). The
  app writes a second mapping that folds snooze and discard into an error
  only to satisfy the signature (apps/extractor/src/extractor/jobs.gleam:66-77).
- **Proposal** (grind): one `define` whose handler returns
  `WorkerResponse(output, error)`, with `worker.from_result` as the adapter for
  plain `Result` handlers.

### EXT-9 The result write cannot share Grind's acknowledgement transaction

- **Packages**: grind, pog. **Kind**: composition. **Severity**: minor.
- **Evidence**: `postgres.connection` is `@internal`
  (grind/src/grind/postgres.gleam:1536), so the app opens a second pool
  against the same database (apps/extractor/src/extractor/store.gleam:20-30).
  The invoice row and the job's success commit separately, so a replayed
  attempt must converge through an upsert on `document_id` (store.gleam:61).
  This adds evidence to the grind card's "Bring your own pool".
- **Proposal** (grind): accept an application `pog.Connection` in `Settings`,
  or offer a handler hook that runs a caller statement inside the success
  acknowledgement transaction.

### EXT-10 grind and llm_wire cap gleam_stdlib below 1.0

- **Packages**: grind, llm_wire. **Kind**: ecosystem-interop. **Severity**: minor.
- **Evidence**: `gleam_stdlib = ">= 0.70.0 and < 1.0.0"` (grind/gleam.toml:10,
  llm_wire/gleam.toml:11), while Hex has 1.0.5 and sinal, http_gun and
  json_blueprint allow `< 2.0.0`. Requiring `gleam_stdlib >= 1.0.0` in the app
  fails:

  ```text
  There's no compatible version of `gleam_stdlib`:
    - You require grind 0.1.0
      - grind requires gleam_stdlib >= 0.70.0 and < 1.0.0
    - You require gleam_stdlib >= 1.0.0 and < 2.0.0
  ```

  The app resolved with stdlib 0.71.0, pog 4.1.0 (Grind's `< 4.2` pin is the
  latest release today) and mist 6.0.2 without conflict.

- **Proposal** (grind, llm_wire): widen to `< 2.0.0`.
- **Status (2 Oct 2026):** resolved by grind b2545a9 and llm_wire 56d793d;
  `gleam update` resolves gleam_stdlib 1.0.5 (was 0.71.0) with no app change.
  gleam_crypto, gleeunit, glisten, gramps and mist moved to newer patch or
  minor releases (mist 6.0.3); pog stays at 4.1.0.

### EXT-11 Small gaps in public read helpers

- **Packages**: grind. **Kind**: ergonomics. **Severity**: nit.
- **Evidence**: `job.state_to_stored` is `@internal` (grind/src/grind/job.gleam:184),
  so telemetry renders `job.State` with `string.inspect`
  (apps/extractor/src/extractor/telemetry.gleam:250). There is no await for a
  handle; the app polls `postgres.outcome` every 50 ms (jobs.gleam:309-322),
  as the grind card's common path already notes.
- **Proposal** (grind): a public `job.state_name(State) -> String`.

## Glue measure

Lines of adapter code per seam, excluding blank lines and comments.

| Seam                                                      | Lines | Location                                                      |
| --------------------------------------------------------- | ----- | ------------------------------------------------------------- |
| llm_wire and http_gun failures to Grind responses         | 78    | outcome.gleam:52-138                                          |
| Telemetry correlation across grind, http_gun and llm_wire | ~60   | telemetry.gleam:39-60, :156-210                               |
| EXT-1 workaround and unused `perform` (error retention)   | 49    | jobs.gleam:55-111                                             |
| Blueprint codec reuse in Grind and pog                    | 44    | jobs.gleam:181-207, store.gleam:92-105, :128-130              |
| Two HTTP clients and their destination policies           | 40    | clients.gleam:26-66 (configuration, not adapter code)         |
| Provider-specific code for three providers                | 15    | llm.gleam:55-69 (OpenAI 1, Anthropic 6, Google 5, endpoint 3) |
| Provider recovery for `retry.assess`                      | 1     | llm.gleam:146                                                 |

The bounded fetch (document.gleam, 39 lines for head checks and error mapping)
and the six-field codec (57 lines) are domain code rather than adapter code.

## What worked well

- **Bounded streaming in http_gun.** `try_with_response` plus
  `body.collect(body, limit)` caps a chunked body with a typed
  `LimitExceeded(CollectedBodyBytes, limit, observed)`, and the scope closes
  the body on every exit. Status, content type and declared length are
  checked on the head before any body read. The oversized stream never
  reaches the provider (provider call count 0).
- **Destination policy as SSRF protection.** A host allowlist plus the
  resolver seam gave the fetcher real isolation in about 20 lines.
  `DestinationRejected` carries `NotSubmitted`, so the app discards safely.
- **llm_wire takes any `http_gun.Client`.** A `with_correlation` view flows
  through `run_structured` unchanged, so the LLM request's http_gun events
  join the job without llm_wire's involvement.
- **One extraction path for three providers.** Settings differ by 1 to 6
  lines; the request, the codec, the result type and the 429 mapping are
  shared. Google's nullable rejection fails at preparation, before I/O.
- **Typed retry hint to Grind snooze.** `RetryDelaySeconds(1)` became a
  1 s snooze; the snooze did not spend an attempt (two `claimed attempt 1`
  events), and the second call succeeded.
- **Grind's typed retry policy and `WorkerResponse`.** The app's pure
  `Decision` maps onto `WorkerFailed`, `WorkerSnoozed` and `WorkerDiscarded`
  in 10 lines (outcome.gleam:127-138), and the policy sees the typed error.
- **Blueprint refinements.** `string_enum`, `integer_between`, `describe` and
  `try_imap` produce a strict schema that all three adapters accept, and
  decode errors are located (`DecodeAtField("currency", DecodeUnknownEnumLabel("YEN"))`).
- **Typed Sinal descriptors.** Six `sinal.observe` calls received typed
  metadata from three packages with no `Dynamic` handling.

## Re-run after fixes (2 Oct 2026)

Package heads: grind b2545a9 (fix 7a04831), http_gun a2869b7, llm_wire
56d793d, gleam_stdlib 1.0.5. 11 tests pass
(`../scripts/with-postgres.sh gleam test`), and `gleam run` prints the demo
batch: three stored invoices, four discards, and two provider calls for the
rate-limited `globex` with `acknowledged scheduled` between its two claims.

| Seam                                                    | Before | After | Change                                                     |
| ------------------------------------------------------- | ------ | ----- | ---------------------------------------------------------- |
| EXT-1 workaround and unused `perform` (error retention) | 49     | 37    | `ErrorRetention` and the `define` branch removed (EXT-1)   |
| Two HTTP clients and their destination policies         | 40     | 38    | `config.allow_loopback` replaces the flag field (EXT-7)    |
| Test harness (`with_retention` wrapper)                 | 9      | 0     | One `with_pipeline` serves every test                      |
| Other seams                                             | 198    | 198   | Unchanged (EXT-2 to EXT-6, EXT-8, EXT-9, EXT-11 untouched) |

The remaining 37 lines of the worker definition hold the 10-line `perform`
that EXT-8 still requires.

The per-request collect policy (http_gun 94b11b9) does not apply here. The
fetcher streams with `try_with_response`, checks the head first, and caps
the body with `body.collect`, which already fails with a typed
`LimitExceeded`; `Truncate` would hand a partial document to the model. The
app never builds `request_options.Options`, so the new field needed no change.

New friction:

- `config.allow_loopback` sets only the loopback flag. Both clients also
  restrict `allowed_hosts`, and the fetcher sets a `resolver`, so each client
  keeps the nested `destination.Policy` update and now mixes a pipe with it.
  The helper saves one line per client here (EXT-7).
- No fix broke the app's build: `gleam update` and the changes above were
  the whole migration.
