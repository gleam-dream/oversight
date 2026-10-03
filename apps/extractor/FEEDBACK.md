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

- **Status (wave 3):** partially resolved by http_gun e55fa1d. The mapping
  of http_gun failures no longer lists reasons: `decide_http` is one
  `error.is_retryable(failure, idempotent: True)` call, and a refused
  destination, a limit and a malformed request all fall out as `Discard`
  (outcome.gleam, 16 lines to 14, three exhaustive patterns gone). It stays
  open for llm_wire: `WireError.HttpFailure` carries `Reason`, not `Failure`,
  so `Kind` and `is_retryable` are unreachable until the app rebuilds a
  failure with `http_error.new(reason, submission(evidence))` from llm_wire's
  `RetryEvidence` (+10 lines). `retry.assess` still answers `Unknown` for every
  `HttpFailure`, the HTTP-date hint is unchanged, and the whole mapping went
  from 78 to 71 lines (comments included). The new test
  `http_failures_are_decided_by_kind_test` covers the classes through both
  entry points.

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
- **Status (wave 2):** partially resolved by llm_wire 6b5ae2d and json_blueprint
  94438b9; the app changed only its test. The discard reason is now readable
  text from `describe_decode_error` and `contract.describe_validation_error`
  instead of `string.inspect` output:
  `Structured output failed schema validation: $["currency"]: unknown enum label`
  and `... failed codec decode: $["total_cents"]: custom validation failed`
  (the two test assertions went from `starts_with` on a prefix to the full
  text). Still open: `OutputValidationError` carries a `String`, the raw
  output is unavailable on failure, and the schema-versus-codec distinction
  is still a prefix match in `outcome.decide_extract`. The new wording also
  drops the app's own message: `describe_decode_error` omits `Custom`
  messages, so `total 9999 differs from line sum 4490` no longer reaches the
  discard reason (see the re-run section).

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
- **Status (wave 2):** partially resolved by sinal 1ff1c18; correlation itself
  is not resolved. The handler-id helper (`observe`, 8 lines), the
  `Result` around `forwarder.new` (4 lines) and `result.values` are gone, and
  `telemetry.start` lost its `label` parameter (13 glue lines removed). The
  registry (job id, `http_telemetry.Id` and emitting pid to document id,
  telemetry.gleam:39-60, :156-210) is unchanged: `sinal/correlation` exists
  (sinal 43279b3), but http_gun still emits and accepts its own opaque `Id`,
  llm_wire's `Metadata` has no correlation, and grind has no job context, so
  the app has no event to feed a `Correlation` into and no key of its own to
  replace. `one_job_is_followed_across_packages_test` still sees 1 of 5
  llm_wire events attributed and `gleam run` still reports 23 unattributed.

- **Status (follow-up):** partially resolved by http_gun c45adfe; the
  http_gun half is resolved, the llm_wire half and the job-id half are not.
  `with_correlation` takes a `sinal/correlation.Correlation` and the
  `correlation` metadata key carries the caller's value, so the worker passes
  the document id as the correlation (`correlation.from_string(document_id)`,
  telemetry.gleam:150-154). The `Correlated` message, the
  `correlations: List(#(Id, String))` state field, its `handle` arm and the
  `list.key_find` lookup are deleted, and `owner` reads the document id from
  the event (`correlation.to_string`). The registry went from about 60 to
  about 50 lines (11 removed, 2 added); what remains is job id to document id
  (grind) and emitting pid to document id (llm_wire). The test still sees 1
  of 5 llm_wire events attributed and `gleam run` still reports 23 llm_wire
  events unattributed (http_gun 0): llm_wire carries no correlation of its
  own, so passing the correlation to the client view does not reach its
  events.

- **Status (wave 3):** partially resolved by sinal c6e2d36 and grind 749c0dc;
  the job-id table is gone. The app submits with
  `job.with_correlation(correlation.from_key(document_id))`; every Grind event
  carries it as `ref.correlation` (required, not an `Option`), and the worker
  reads it from `worker.correlation(context)` for its http_gun views.
  `from_key` also removes the 128-byte friction: the `from_string` plus
  `unique()` fallback and its unattributed attempts are gone, and `trace`
  applies the same function to the id it is asked about. Removed:
  `job_submitted`, the `JobSubmitted` message, `State.jobs`, the `JobId` key and
  its lookup arms (24 lines). Added: `document_correlation` and a longer
  `begin_attempt` (13 lines, 5 of them comments). Still open: llm_wire events
  carry no correlation, so the emitting-pid table stays, and all 23
  unattributed events are llm_wire's.

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
- **Status (wave 2):** partially resolved by json_blueprint 94438b9. The Grind
  half is resolved: `codec.to_json` and `codec.decoder` feed `worker.codec`,
  so the invoice is stored as a JSON object under the output codec (version
  bumped to `extracted-v2`) instead of text inside a string, and the
  placeholder `Invoice` in the Grind decoder is gone. The three Grind codecs
  went from 77 lines (jobs.gleam:128-212) to 57 (jobs.gleam:126-190) because
  the input and error codecs became Blueprint record codecs too; the output
  codec alone went from 27 to 11 plus a shared 13-line `grind_codec` helper.
  The pog half is unchanged (14 lines in store.gleam:92-105 plus the 3-line
  placeholder): the row arrives as `payload::text`, so the decoder still goes
  through `decode_json` and `decode.failure` needs a placeholder `Invoice`.
  `codec.decoder` reads a parsed `Dynamic` and cannot read a column of text.

- **Status (follow-up):** partially resolved by grind c44e4be; the Grind bridge half is resolved.
  `worker.codec` takes a fallible encoder, so `grind_codec` no longer holds
  the `let assert Ok(encoded) = codec.to_json(..) as "..."`: the encoder is
  `codec.to_json(blueprint, value) |> result.map_error(codec.describe_encode_error)`
  and a rejected value fails `submit` with `submission.InvalidInput`. The
  helper is 11 lines instead of 13 and the three Grind codecs went from 57
  to 46 together with the getter change (EXT-6). The pog half is unchanged
  (jsonb still arrives as text).

- **Status (wave 3):** partially resolved by grind 749c0dc and json_blueprint
  60c0dfb. `grind_codec` is `worker.codec(encode, decoder)` with no version
  string and no `let assert Ok(wire)` (16 to 13 lines). The three codec versions
  (`document-job-v1`, `extracted-v2`, `job-error-v1`) became the default `"1"`,
  so a job stored by the previous app would no longer be claimed; the demo
  database is disposable. `store.find` builds its `decode.failure` value with
  `codec.placeholder(invoice.codec())`, which deletes the hand-written
  `placeholder()` (4 lines). The pog row decoder is otherwise unchanged
  (jsonb arrives as text).

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
- **Status (wave 2):** resolved in shape, not in size, by json_blueprint
  94438b9. The five `combine` calls, the nine `let assert`s, the
  five-level tuple in both directions and `invalid_date` are gone, and the
  record builder keeps `Invoice` and `LineItem` flat. `invoice.codec()` went
  from 57 to 62 lines (invoice.gleam:47-108) and the file from 142 to 147
  lines: every getter needs its own `fn(i: Invoice)` annotation and the
  formatter wraps most `use` lines. The cross-field total check moved into the
  codec: the `total_cents` codec is built inside the `use` chain after
  `line_items`, so `codec.try_map` sees the lines and the error stays located
  at `Field("total_cents")` (see the re-run section).

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

- **Status (wave 3):** resolved by http_gun e55fa1d for the policy half.
  `destination.loopback_only() |> destination.only_hosts([...])` replaces the
  `allow_loopback` plus nested `Policy` update, and entries take a port: the LLM
  client now admits only `127.0.0.1:<provider port>`, so it cannot reach the
  document server on the same address (new assertion in
  `fetcher_cannot_reach_the_provider_origin_test`). llm_wire still matches the
  endpoint host string. The port pin has a cost in tests: a dead provider port
  (`:9`, for the transport-failure test) must also be given to the client's
  policy, so `with_pipeline` takes a provider port, not a base URL.

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

- **Status (wave 3):** resolved by grind 749c0dc. `worker.responding` takes
  `handle: fn(context, input) -> Response`; there is no `perform` and no second
  mapping (`define` 41 to 24 lines). `outcome.to_response` returns
  `worker.Response` with `Snoozed(after: Duration, ..)`, so the `retry_delay`
  `Result` and its "unrepresentable snooze" arm are gone (14 to 9 lines).

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

- **Status (wave 3):** partially resolved by grind 749c0dc. The second pool is
  gone: the app builds one `pog.Config`, Grind keeps its pool name, and
  `grind.connection(jobs)` hands the same pool to `store.save` (`store.start`,
  11 lines, and the `Env.store` field are deleted). Not resolved: Grind has no
  hook that runs a caller statement inside the acknowledgement transaction.
  `submit_in` enqueues a job in the app's transaction, which this app does not
  need (extraction writes a result, it enqueues nothing). The row and the job's
  success still commit separately, and the upsert on `document_id` stays.

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

- **Status (follow-up):** partially resolved by json_blueprint bb4da39 (`get:`
  after the callback). The annotation friction recorded in the wave 2 re-run
  is gone: all 17 `fn(x: Type)` getter annotations in `invoice.gleam`,
  `jobs.gleam` and the test are now `get: fn(x) { x.field }`.
  `invoice.codec()` went from 62 to 52 lines (invoice.gleam:47-98), which is
  below the 57 of the pre-wave `combine` version, and `LineItem` and the
  Grind input and error codecs fit on one or two lines per field. The cross-field
  total check is unchanged.

- **Status (wave 3):** resolved by grind 749c0dc. `job.state_name` is public
  (telemetry's `string.lowercase(string.inspect(state))` helper is deleted) and
  `grind.await(jobs, handle, within:)` replaces the 50 ms polling loop
  (`await` 17 to 9 lines). The remaining wait in the app is `await_all`, which
  awaits the handles one after another.

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

## Re-run after wave 2 (2 Oct 2026)

Package heads: sinal a0c05ef, json_blueprint c96a8c3, llm_wire 6b5ae2d, grind
c1920e6, http_gun 1dc20a1. 11 tests pass
(`../scripts/with-postgres.sh gleam test`) and `gleam run` prints the same demo
batch: three stored invoices, four discards, two provider calls for `globex`.
The migration changed 7 files: 173 lines added and 209 removed (net -36),
including tests and formatting.

| Seam                                                     | Before | After | Change                                                                       |
| -------------------------------------------------------- | ------ | ----- | ---------------------------------------------------------------------------- |
| Six-field Invoice codec (EXT-6)                          | 57     | 62    | Builder replaces `combine` and tuples; getters need annotations (+5)         |
| Total check (domain code)                                | 13     | 16    | `check_total` becomes `total_matching`, located at `total_cents`             |
| Grind codecs: input, output, error (EXT-5)               | 77     | 57    | `grind_codec` (13) over `to_json` and `decoder`; the output codec is 27 → 11 |
| pog row decoder (EXT-5)                                  | 17     | 17    | Unchanged: jsonb arrives as text                                             |
| Name tables for the enums (`provider_from_name`, stages) | 23     | 13    | `string_enum` for provider and stage; `stage_name`/`stage_from_name` deleted |
| Telemetry handler ids and forwarder `Result` (EXT-4)     | 13     | 0     | `sinal.observe(event, run)`; `forwarder.new(name)`; no label parameter       |
| Telemetry correlation registry (EXT-4)                   | ~60    | ~60   | Unchanged; no package carries `Correlation` yet                              |
| Other seams (EXT-2, EXT-8, EXT-9, EXT-11)                | 198    | 198   | Untouched                                                                    |

Net glue by seam: Grind codecs -20, name tables -10, handler ids -13, invoice
codec +5 (and +3 for the total check). The app does not use `sinal/correlation`
or the sinal `fields` builder: it defines no events of its own, and http_gun's
`Id` is the only correlation key its collector can use.

New friction:

- **Blueprint's record builder needs a type annotation on every getter; Sinal's
  needs one.** `fields.and(f, fn(r) { r.x })` after `fields.record(..)` knows `r`
  from the piped `Record`. `codec.field(name, c, get, then)` checks `get` before
  the continuation fixes `r`, so `fn(i) { i.number }` fails with "Unknown type
  for record access". Six annotations in `Invoice`, three in `LineItem`, and
  `gleam format` wraps most `use` lines to three. The result is no shorter
  than the old `combine` chain (62 lines against 57), though it has no tuples,
  no `let assert` and no arity limit.
  **Status (follow-up):** resolved by json_blueprint bb4da39; see EXT-6.
- **`codec.try_map` has no field location for a cross-field check, and
  `describe_decode_error` drops `Custom` messages.** A `try_map` over the whole
  record fails at path `[]`. With the first draft, `gleam run` printed
  `failed codec decode: $: custom validation failed`, where it used to print
  the total and the line sum. The working form builds the `total_cents` codec
  inside the `use` chain, after `line_items`:

  ```gleam
  use total_cents <- codec.field(
    "total_cents",
    total_matching(line_items, cents),
    fn(i: Invoice) { i.total_cents },
  )
  ```

  It gives `$["total_cents"]: custom validation failed`, but the message `total
9999 differs from line sum 4490` is still omitted from the text llm_wire
  stores as the discard reason. That is deliberate in `describe_decode_error`
  (no input values), but it makes `Custom` useless for a model-facing or
  operator-facing explanation. The app can read the message only from the typed
  `DecodeError`, which llm_wire flattens to a string (EXT-3).

- **`codec.to_json` returns a `Result`, and `worker.codec` wants a total
  function.** The guide suggests `result.unwrap(json.null())`, which stores a
  `null` that fails on read. The app uses `let assert Ok(..) as "..."` inside
  `grind_codec`, which is one more assert on a definition that cannot fail for
  these codecs. A total `codec.to_json_or_panic`, or `to_json` documented as
  infallible for codecs without `custom`, would remove it.
  **Status (follow-up):** resolved by grind c44e4be; see EXT-5.
- **Wire format change.** The invoice stored by Grind is now an object, not a
  JSON string, so the output codec version moved to `extracted-v2`. Jobs
  already stored under `extracted-v1` would no longer read back, and a
  deployment would need a plan for them.
- **`string_enum` repeats the names the app already keeps.** `llm.provider_name`
  (used for the store column and the printout) and `llm.provider_codec` list
  the same three labels; deriving one from the other needs a third list.
- **Correlation remains the app's own.** Nothing in wave 2 reduced the
  registry: reaching "following one job" needs http_gun and llm_wire to carry
  `Correlation` and grind to give a handler its job id.
  **Status (follow-up):** the http_gun part is resolved by http_gun c45adfe;
  llm_wire and grind are not; see EXT-4.

Migration guides: sufficient for compiling. Every symbol this app imports is
in the json_blueprint index, and the sinal guide covered `observe`,
`forwarder.new` and the removed ids exactly. Gaps:

- llm_wire's CHANGELOG `Unreleased` does not say that `OutputValidationError`
  text changed from `string.inspect` output to `describe_*` wording (only the
  commit message of 6b5ae2d does). Anyone who prefix-matches it, as this
  app's tests do, needs that line.
- The json_blueprint guide shows `try_map` for a single value but not how to
  keep a cross-field check located (build the dependent codec inside the `use`
  chain) and does not say that a record-level `try_map` reports path `[]`.
- The guide shows `result.unwrap(json.null())` for `to_json` without noting
  that the failure then surfaces on read.
- Neither guide covers pog: a Blueprint codec still cannot be a pog row
  decoder because jsonb arrives as text.

**Follow-up (json_blueprint f55ec09):** `describe_decode_error` now renders the
caller's `try_map` message, so the discard reason reads
`$["total_cents"]: total 9999 differs from line sum 4490`. The lost-message
friction above is resolved; the test asserts the full message.

## Re-run after the follow-up fixes (2 Oct 2026)

Package heads: json_blueprint bb4da39, grind c44e4be (with 2d66835), http_gun
c45adfe (with 056536b), sinal f9cca37 and 5e8bee3. 11 tests pass
(`../scripts/with-postgres.sh gleam test`) and `gleam run` prints the same
demo batch: two stored invoices and one rate-limited retry for `globex`
(two provider calls), four discards, and 23 unattributed events (llm_wire
23, http_gun 0). The migration touched four files: 44 lines added and 70
removed (net -26), including the test.

| Seam                                             | Before | After | Change                                                                                  |
| ------------------------------------------------ | ------ | ----- | --------------------------------------------------------------------------------------- |
| Six-field Invoice codec (EXT-6)                  | 62     | 52    | `get:` removes 9 getter annotations; the formatter wraps fewer `use` lines              |
| Grind codecs: input, output, error (EXT-5)       | 57     | 46    | 7 getter annotations gone; `grind_codec` 13 → 11 lines, no `let assert` on `to_json`    |
| Telemetry correlation registry (EXT-4)           | ~60    | ~50   | `Correlated`, the `Id` table, its `handle` arm and lookup gone; `owner` reads the event |
| `with_correlation` call sites (jobs.gleam:97-99) | 3      | 3     | Same calls; the argument is now the document id's `Correlation`                         |

Glue and codec lines removed: about 30 (10 Invoice codec, 11 Grind codecs, 9
registry). Lines added: 2, the `result.lazy_unwrap(correlation.unique)`
fallback in `begin_attempt`. What remains of the registry is job id to
document id (grind has no job context) and emitting pid to document id
(llm_wire carries no correlation).

The sinal record builder and `correlation.required_field()` do not apply:
the app defines no Sinal events, it only observes them, and http_gun's
`Metadata.correlation` stays an `Option` because the library may run without
one. The handler matches `Some(correlation)` once (telemetry.gleam:183).

New friction:

- **A correlation has to be 1 to 128 bytes, and the app's document id has no
  such bound.** `correlation.from_string` returns a `Result`, so
  `begin_attempt` falls back to `correlation.unique()`, and the http_gun
  events of that attempt then belong to no document. `owner` returns
  `Some(text)` for them, so `trace` counts them as neither attributed nor
  unattributed. The sinal doc suggests a SHA-256 digest of the id, which
  would need `gleam_crypto` here and a reverse table to get the document
  back, which is the registry again. The app relies on document ids that fit;
  a validated id type at submission would be the honest fix, and the packages
  cannot remove it.
- **One correlation per document hides the attempts.** The correlation used to
  be one `Id` per attempt, so a retry's http_gun events were separable from the
  first attempt's. Now the two attempts of `globex` share a correlation, and
  only order and the Grind `claimed` events tell them apart; http_gun's
  per-request `RequestId` is opaque and groups only one invocation's
  milestones. For this app the document is the right unit, but an app that
  wants per-attempt traces must put the attempt number into the correlation
  text itself and then needs a table to get back to the document.
- **The correlation-to-key mapping is the identity only because the app chose
  the key.** `owner` is `correlation.to_string` since the correlation text is
  the document id. An app that derives correlations from something else still
  needs the lookup.
- **llm_wire is now the only package that forces the registry.** Passing the
  correlation to the client llm_wire runs on changes none of its events; all 23
  unattributed events are llm_wire's, and the emitting-pid table is the only
  way to attribute 1 of 5 per job. A `correlation` taken from the
  `http_gun.Client` view would remove it.
- **`InvalidInput` is unreachable here and has no test.** All three codecs
  are total in practice: the input and error codecs hold only strings and
  enums, and the output's `Invoice` already passed the same codec when the
  model's answer was decoded. `submit` maps every error with `string.inspect`,
  so a rejected value would read as the text of `InvalidInput(..)` rather than
  a typed case. The change removes a panic that could not fire, not a failure
  the app can show. `worker.codec` still returns a `Result` for an empty
  version, so `grind_codec` keeps one `let assert Ok(wire)` on a constant.

Migration guides: sufficient. The grind guide's dependents table named this
app's `jobs.gleam` bridge, the http_gun table named the exact lines in
`jobs.gleam` and `telemetry.gleam`, and the json_blueprint rule (put `get:`
before the third argument) was mechanical. Gaps: the http_gun guide says an
app can drop its join table but does not mention the 128-byte bound, which an
app with free-form ids meets first, and the sinal `required_field` section
does not say that an observer-only app has nothing to switch.

## Re-run after wave 3 (2 Oct 2026)

Package heads: grind 749c0dc (008b657), http_gun e55fa1d (1a5f5ef), sinal
c6e2d36, json_blueprint 60c0dfb, llm_wire 576482e (testing types only). 13
tests pass (`../scripts/with-postgres.sh gleam test`; the app had 11, and the
two new ones cover failure classes by `Kind` and the handler run through
`grind/testing`). `gleam run` prints the same demo batch: three stored
invoices, four discards, two provider calls for `globex` with `acknowledged
scheduled` between its two claims, and 23 unattributed events (llm_wire 23,
http_gun 0). The migration changed the seven source files and the test: src
216 added and 272 removed (net -56), test 141 added and 68 removed (net +73,
of which about 70 lines are the two new tests and the port-pin assertion).

Glue before to after, in lines counted per function with its comments:

| Seam                                                        | Before | After | Change                                                                                                                    |
| ----------------------------------------------------------- | ------ | ----- | ------------------------------------------------------------------------------------------------------------------------- |
| Worker definition with unused `perform` (EXT-8)             | 41     | 24    | `worker.responding`; `perform`, `registry`, the `define` `Result` and its `let assert`s gone                              |
| Pipeline: start, queue policy, submit, await, stop (EXT-11) | 82     | 59    | one `grind.new(pool) \|> with_worker \|> with_queue`; `queue.Consumer`, `registry.new` and the polling `await` gone       |
| Second pool and `Env.store` (EXT-9)                         | ~15    | 4     | `grind.connection(jobs)`; `store.start` deleted, `jobs.connection` added                                                  |
| Job id registry (EXT-4)                                     | 24     | 13    | `job_submitted`, `JobSubmitted`, `State.jobs`, `JobId` replaced by `from_key` and `worker.correlation(context)`           |
| http_gun failure mapping (EXT-2)                            | 60     | 71    | `Kind` and `is_retryable` remove the reason patterns, but llm_wire's `Reason` must be rebuilt into a `Failure` (+10)      |
| Two HTTP clients and their destination policies (EXT-7)     | 40     | 40    | builders replace the record updates (-10), a 10-line `observed` helper for the `Option(Forwarder)` replaces field punning |
| Blueprint placeholder (EXT-5)                               | 4      | 0     | `codec.placeholder(invoice.codec())`                                                                                      |
| Grind codec helper (EXT-5)                                  | 16     | 13    | `worker.codec` is total and unversioned                                                                                   |

Glue removed: about 95 lines. Added: about 40, in the `Kind` mapping, the
`observed` helper, `document_correlation` and `jobs.connection`.

Blockers and seams the wave 3 brief names:

- **One pool (CHK-1 counterpart):** resolved here. Grind and the app share one
  pool of 8 built from one `pog.Config`.
- **Transactional completion (EXT-9, CHK-2 counterpart):** not resolved for a
  result write. `submit_in` solves "enqueue with my write"; nothing solves "my
  write with the job's success". Proposal (grind): a `worker.responding_in`
  whose handler receives the open transaction that the acknowledgement commits
  (`fn(context, tx, input) -> Response`), or `grind.complete_in`. Until then
  the idempotent upsert remains.
- **Abandonment replay (RA-2 counterpart):** the app keeps the default
  `HoldUncertain`. Extraction is idempotent (the upsert), so
  `with_abandonment(ReplayAfterLeaseExpiry(..))` would be sound here, but no
  test crashes a node, so it is not claimed.
- **Context (WHK-8 counterpart):** `worker.correlation` replaced the registry.
  `worker.attempt` is read by no code: the retry policy receives the attempt
  directly, and the 15-minute handler timeout, 100-snooze cap and 7-day pruner
  defaults do not change this app's tests. The snooze test still passes with
  the cap because the `globex` job snoozes once.

Where a redesigned API reads worse for this app:

- **`grind.submit` returns `Admission`, so a plain submit has a dead branch.**
  Before, `postgres.submit` returned `Result(Handle, _)`. Now:

  ```gleam
  |> result.try(fn(admission) {
    case admission {
      grind.Inserted(handle) -> Ok(handle)
      // No uniqueness policy is set, so no other admission can happen.
      grind.Existing(_) | grind.Rescheduled(_) -> Error("job was not inserted")
    }
  })
  ```

  `Existing(Conflict)` carries no handle either, so even a correct branch would
  need `grind.bind`. Proposal (grind): `grind.submit` returns the handle for a
  job without `job.unique`, or a `grind.inserted(admission)` helper.

  **Status (wave 3 fixes):** resolved by grind 6bd06ec..eb7b173;
  `grind.handle(admission)` returns the new or the occupying job, so
  `jobs.submit` is `|> result.map(grind.handle)` and the 7-line `case` is gone.

- **The worker needs the runtime before the runtime exists.** The handler writes
  on Grind's pool, but `define` runs before `grind.new(pool)`, so it captures
  `grind.named(name)` and calls `grind.connection(jobs)` per attempt (and
  `connection` panics if the runtime is not configured). It works, and it
  beats the second pool, but `Env` lost a field and `define` gained two
  parameters (`jobs`, `queue_name`). A `Context` accessor for the runtime's
  connection (`worker.connection(context)`) would remove both.

  **Status (wave 3 fixes):** resolved by grind 9ccbfb5; the handler calls
  `worker.connection(context)` and `testing.with_connection` sets it in the
  handler test. `define` lost its `jobs` parameter and the `grind.named` capture.

- **http_gun's `with_observations` takes a `Forwarder`, not an `Option`.** The
  wave 2 `Config` had an `observations: Option(Forwarder)` field the app passed
  through; now a 10-line helper chooses between `with_observations` and the
  default. Routing once (`forwarder.route(["http_gun"], f)`) would remove the
  per-client parameter, but it is node-wide state and the tests start several
  clients.
- **`observe_labelled` was not adopted.** Its label buys readable
  `list_handlers` ids, but the formatter wraps each call to three lines (about
  +28 in `telemetry.start`), and nothing in this app reads handler ids.
  `fields.check` does not apply (the app defines no Sinal events).
- **The default worker version makes stored jobs unclaimable.** Dropping the
  three version strings is the point of the default, but nothing in the app or
  the migration notes how to tell that a job stored under `"document-job-v1"`
  is now `contract_mismatch`. The migration guide says so; the failure would
  surface as `Failed(ContractMismatch, ..)` in `await`.

Seams that still need glue, and who owns them:

| Seam                                            | Glue                                      | Owner                                     |
| ----------------------------------------------- | ----------------------------------------- | ----------------------------------------- |
| llm_wire `Reason` to http_gun `Kind`            | 10 lines (`submission`, `http_error.new`) | llm_wire (carry `Failure`, or use `Kind`) |
| llm_wire retry advice (EXT-2)                   | `decide_extract`, 38 lines                | llm_wire (`retry.advise`)                 |
| llm_wire events carry no correlation (EXT-4)    | emitting-pid table, about 25 lines        | llm_wire                                  |
| Result write inside the acknowledgement (EXT-9) | the idempotent upsert                     | grind                                     |
| Plain submit returns a three-way admission      | 6 lines                                   | grind                                     |
| Optional observations forwarder                 | 10 lines                                  | http_gun                                  |

Migration guides: sufficient. The grind guide's extractor entry named the
symbols and the EXT-9 and EXT-11 replacements; the http_gun guide's `Kind`
section and destination examples were enough for the policy and the mapping.
Gaps: the grind guide says "write the extracted invoice inside the job with
`grind.connection` (one pool)", which suggests a transactional write the
facade does not offer; it gives one pool, not one transaction. The http_gun
guide does not say that llm_wire's `HttpFailure` carries a `Reason`, which is
where an app mapping llm_wire errors meets the opaque `Failure` first.

**Status (wave 3 fixes), start order:** resolved by grind 9ccbfb5. `grind.start`
then `grind.migrate` would now fail with `SchemaNotMigrated`; `start` takes
`grind.with_startup_migration`, which applies the migrations before any
consumer polls. The app's own table still follows on `grind.connection(jobs)`,
which is safe because no job is submitted before `jobs.start` returns.

### After the follow-up fixes

13 tests pass (`../scripts/with-postgres.sh gleam test`) and `gleam run` prints
the same batch. The fixes touched `jobs.gleam` (about 15 lines removed, 9
added) and the handler test (1 removed, 2 added): net -5. Removed: the
`grind.named` capture and the `jobs` parameter of `define`, the separate
`grind.migrate` call, and the 7-line `Admission` branch. EXT-9 (result write
inside the acknowledgement) is unchanged.
