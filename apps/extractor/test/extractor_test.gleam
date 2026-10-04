import envoy
import extractor/clients
import extractor/document
import extractor/fixtures
import extractor/invoice
import extractor/jobs
import extractor/llm
import extractor/outcome
import extractor/scripted
import extractor/store
import extractor/telemetry
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import gleeunit
import grind
import grind/job
import grind/testing
import grind/worker
import http_gun
import http_gun/config as http_config
import http_gun/destination
import http_gun/error as http_error
import json/blueprint/codec
import llm_wire
import llm_wire/error
import llm_wire/message
import llm_wire/testing as wire_testing

pub fn main() -> Nil {
  gleeunit.main()
}

// Harness -----------------------------------------------------------------

type Context {
  Context(
    services: scripted.Services,
    collector: telemetry.Collector,
    http: clients.Clients,
    env: jobs.Env,
    pipeline: jobs.Pipeline,
  )
}

fn database_url() -> String {
  let assert Ok(url) = envoy.get("DATABASE_URL")
    as "run the tests through ../scripts/with-postgres.sh gleam test"
  url
}

/// Starts scripted services, telemetry, both clients and a Grind pipeline
/// on its own queue. `provider_port` picks the loopback port the LLM
/// client may reach and the models call.
fn with_pipeline(
  queue: String,
  documents: List(scripted.Document),
  provider_port: fn(scripted.Services) -> Int,
  run: fn(Context) -> a,
) -> a {
  let assert Ok(services) = scripted.start(documents)
  let assert Ok(collector) = telemetry.start()
  let assert Ok(http) =
    clients.start(
      clients.Loopback([fixtures.document_host], provider_port(services)),
      Some(collector.http_observations),
    )
  let base = "http://127.0.0.1:" <> int.to_string(provider_port(services))
  let env =
    jobs.Env(
      clients: http,
      model: llm.model(_, base, "sk-scripted"),
      limits: document.default_limits(),
    )
  let assert Ok(pipeline) = jobs.start(database_url(), queue, env)
  let result = run(Context(services:, collector:, http:, env:, pipeline:))
  jobs.stop(pipeline)
  clients.stop(http)
  telemetry.stop(collector)
  result
}

fn live(services: scripted.Services) -> Int {
  services.providers_port
}

fn submit(
  context: Context,
  id: String,
  provider: llm.Provider,
) -> #(jobs.DocumentJob, jobs.Handle) {
  let job =
    jobs.DocumentJob(
      document_id: id,
      url: scripted.document_url(context.services, fixtures.document_host, id),
      provider:,
    )
  let assert Ok(handle) = jobs.submit(context.pipeline, job)
  #(job, handle)
}

fn finish(context: Context, submitted: #(jobs.DocumentJob, jobs.Handle)) {
  let assert Ok(finished) =
    jobs.await(context.pipeline, submitted.1, duration.seconds(10))
  finished
}

// Common path -------------------------------------------------------------

pub fn invoice_codec_round_trips_and_checks_totals_test() {
  let invoice_codec = invoice.codec()
  let text = fixtures.model_output(fixtures.acme())
  assert codec.decode_json(invoice_codec, text) == Ok(fixtures.acme())
  let assert Ok(schema) = codec.schema_json(invoice_codec)
  assert string.contains(schema, "\"enum\":[\"USD\",\"EUR\",\"GBP\"]")
  assert string.contains(schema, "\"additionalProperties\":false")
  // A total that contradicts the lines fails inside the codec, not the schema.
  let assert Error(codec.DecodeError(
    path: [codec.Field("total_cents")],
    reason: codec.Custom(message),
  )) = codec.decode_json(invoice_codec, string.replace(text, "4490", "9999"))
  assert string.contains(message, "differs from line sum")
  // An unknown currency fails as an enum label, located at its field.
  assert codec.decode_json(invoice_codec, string.replace(text, "EUR", "YEN"))
    == Error(codec.DecodeError(
      [codec.Field("currency")],
      codec.UnknownEnumLabel,
    ))
}

pub fn batch_is_extracted_and_stored_test() {
  use context <- with_pipeline("extract_common", fixtures.batch(), live)
  let submitted = [
    submit(context, "acme", llm.OpenAi),
    submit(context, "initech", llm.Google),
  ]
  let assert [
    grind.Succeeded(jobs.Extracted(row_id: acme_row, invoice: acme)),
    grind.Succeeded(jobs.Extracted(invoice: initech, ..)),
  ] = list.map(submitted, finish(context, _))
  assert acme == fixtures.acme()
  assert initech == fixtures.initech()
  let assert Ok([stored]) =
    store.find(jobs.connection(context.pipeline), "acme")
  assert stored.row_id == acme_row
  assert stored.provider == "openai"
  assert stored.invoice == fixtures.acme()
}

// Advanced: provider portability ------------------------------------------

pub fn same_extraction_runs_on_three_providers_test() {
  let throttled =
    fixtures.document("throttled", fixtures.acme(), scripted.AlwaysStatus(429))
  let assert Ok(services) = scripted.start([throttled, ..fixtures.batch()])
  let assert Ok(http) =
    clients.start(
      clients.Loopback([fixtures.document_host], services.providers_port),
      None,
    )
  let text = fixtures.render(fixtures.acme())
  let results =
    list.map([llm.OpenAi, llm.Anthropic, llm.Google], fn(provider) {
      let model =
        llm.model(provider, scripted.providers_base(services), "sk-scripted")
      llm.extract(http.llm, model, "acme", text)
    })
  assert results
    == [Ok(fixtures.acme()), Ok(fixtures.acme()), Ok(fixtures.acme())]
  assert scripted.provider_calls(services, "acme") == 3
  // A 429 from each provider wire becomes the same Grind decision.
  let delays =
    list.map([llm.OpenAi, llm.Anthropic, llm.Google], fn(provider) {
      let model =
        llm.model(provider, scripted.providers_base(services), "sk-scripted")
      let assert Error(failure) =
        llm.extract(http.llm, model, "throttled", text)
      let assert outcome.Snooze(delay, _) =
        outcome.decide(outcome.ExtractFailed(failure))
      delay
    })
  assert delays == list.repeat(duration.seconds(2), 3)
  clients.stop(http)
}

pub fn nullable_output_field_is_not_portable_to_google_test() {
  // An optional purchase-order number, explicit null when absent.
  let with_po = {
    use po_number <- codec.field(
      "po_number",
      codec.nullable(codec.string()),
      get: fn(po_number) { po_number },
    )
    codec.success(po_number)
  }
  let prepared =
    list.map([llm.OpenAi, llm.Anthropic, llm.Google], fn(provider) {
      let model = llm.model(provider, "http://127.0.0.1:9", "sk-scripted")
      llm_wire.prepare(
        model.settings,
        llm.request(model, "acme", "text")
          |> llm_wire.with_output("po", with_po),
      )
      |> result.is_ok
    })
  assert prepared == [True, True, False]
}

// Failure paths -----------------------------------------------------------

pub fn rate_limit_snoozes_for_the_retry_after_hint_test() {
  // The pure mapping: llm_wire's typed hint becomes a Grind snooze.
  let rate_limited =
    wire_testing.failure(
      message.Anthropic,
      error.Status(429, "{}", Some(duration.seconds(1))),
    )
  let assert outcome.Snooze(delay, _) =
    outcome.decide(outcome.ExtractFailed(llm.CallFailed(rate_limited)))
  assert delay == duration.seconds(1)
  let assert worker.Snoozed(after:, ..) =
    outcome.to_response(outcome.Snooze(delay, "provider answered 429"))
  assert after == duration.seconds(1)

  // No hint means backoff, which spends an attempt; an unbounded hint is cut.
  let overloaded =
    wire_testing.failure(message.OpenAI, error.Status(503, "{}", None))
  let assert outcome.Retry(outcome.Transient(outcome.Extract, _)) =
    outcome.decide(outcome.ExtractFailed(llm.CallFailed(overloaded)))
  let parked =
    wire_testing.failure(
      message.OpenAI,
      error.Status(429, "{}", Some(duration.hours(3))),
    )
  let assert outcome.Snooze(delay, _) =
    outcome.decide(outcome.ExtractFailed(llm.CallFailed(parked)))
  assert delay == outcome.longest_snooze()

  // End to end: the first call is refused, the job is snoozed, the second
  // call succeeds.
  use context <- with_pipeline("extract_rate_limit", fixtures.batch(), live)
  let started = timestamp.system_time()
  let submitted = submit(context, "globex", llm.Anthropic)
  let assert grind.Succeeded(jobs.Extracted(invoice:, ..)) =
    finish(context, submitted)
  let elapsed = timestamp.difference(started, timestamp.system_time())
  assert duration.to_seconds(elapsed) >=. 1.0
  assert invoice == fixtures.globex()
  assert scripted.provider_calls(context.services, "globex") == 2
  let trace = telemetry.trace(context.collector, "globex")
  assert list.any(trace.attributed, fn(record) {
    record.summary == "acknowledged scheduled"
  })
}

pub fn invalid_structured_output_is_discarded_test() {
  use context <- with_pipeline("extract_invalid_output", fixtures.batch(), live)
  let assert [grind.Discarded(currency), grind.Discarded(total)] =
    list.map(
      [
        submit(context, "bad-currency", llm.OpenAi),
        submit(context, "bad-total", llm.Google),
      ],
      finish(context, _),
    )
  // Schema validation rejects the enum; the codec's own check rejects the
  // total. The reason names the stage and keeps the start of the model output.
  assert string.starts_with(
    currency,
    "invalid structured output: schema validation failed: $[\"currency\"]: unknown enum label; output: {\"vendor\":",
  )
  assert string.starts_with(
    total,
    "invalid structured output: decode failed: $[\"total_cents\"]",
  )
  assert store.find(jobs.connection(context.pipeline), "bad-currency") == Ok([])
}

/// EXT-3: the failure is typed and keeps the model's raw output, so a caller
/// tells a schema rejection from a codec rejection without parsing text.
pub fn invalid_output_keeps_the_raw_output_and_a_typed_reason_test() {
  let assert Ok(services) = scripted.start(fixtures.batch())
  let assert Ok(http) =
    clients.start(
      clients.Loopback([fixtures.document_host], services.providers_port),
      None,
    )
  let extract = fn(id, provider) {
    let model =
      llm.model(provider, scripted.providers_base(services), "sk-scripted")
    llm.extract(http.llm, model, id, fixtures.render(fixtures.acme()))
  }
  let assert Error(llm.CallFailed(llm_wire.Failure(
    error: error.InvalidOutput(raw_output:, failure: error.SchemaRejected(_)),
    sent: llm_wire.Completed,
    partial_output: True,
    provider: message.OpenAI,
    ..,
  ))) = extract("bad-currency", llm.OpenAi)
  assert string.contains(raw_output, "\"currency\":\"YEN\"")
  let assert Error(llm.CallFailed(llm_wire.Failure(
    error: error.InvalidOutput(
      raw_output:,
      failure: error.DecodeRejected(codec.DecodeError(
        path: [codec.Field("total_cents")],
        reason: codec.Custom(message),
      )),
    ),
    provider: message.Anthropic,
    ..,
  ))) = extract("bad-total", llm.Anthropic)
  assert string.contains(raw_output, "\"total_cents\":9999")
  assert string.contains(message, "differs from line sum")
  clients.stop(http)
}

pub fn oversized_and_unsupported_documents_are_discarded_test() {
  let declared_huge =
    scripted.Document(
      id: "declared-huge",
      content_type: "text/plain",
      body: scripted.Fixed(string.repeat("y", 100_000)),
      behavior: scripted.Answer(""),
    )
  use context <- with_pipeline(
    "extract_oversized",
    [declared_huge, ..fixtures.batch()],
    live,
  )
  // The declared length stops the fetch at the response head.
  let declared =
    document.fetch(
      context.http.fetcher,
      scripted.document_url(
        context.services,
        fixtures.document_host,
        "declared-huge",
      ),
      document.default_limits(),
    )
  assert declared == Error(document.TooLarge(65_536, 100_000))
  // A chunked body without a length is stopped by the streaming cap.
  let assert [grind.Discarded(huge), grind.Discarded(pdf)] =
    list.map(
      [
        submit(context, "huge", llm.OpenAi),
        submit(context, "scan-pdf", llm.Google),
      ],
      finish(context, _),
    )
  assert string.starts_with(huge, "document exceeds 65536 bytes")
  assert pdf == "unsupported content type 'application/pdf'"
  assert scripted.provider_calls(context.services, "huge") == 0
}

pub fn provider_transport_failure_retries_until_budget_test() {
  // Port 9 on loopback refuses connections: a transport failure.
  use context <- with_pipeline("extract_transport", fixtures.batch(), fn(_) {
    9
  })
  let submitted = submit(context, "acme", llm.OpenAi)
  // The worker's error codec keeps the typed JobError and its detail.
  let assert grind.Failed(
    grind.Business(outcome.Transient(outcome.Extract, detail)),
    Some(job.BudgetExhausted),
    _,
  ) = finish(context, submitted)
  assert string.starts_with(detail, "HTTP failure: Connection failed")
  let trace = telemetry.trace(context.collector, "acme")
  assert list.count(trace.attributed, fn(record) {
      string.starts_with(record.summary, "claimed attempt")
    })
    == 3
}

// Advanced: one client or two ---------------------------------------------

pub fn fetcher_cannot_reach_the_provider_origin_test() {
  let assert Ok(services) = scripted.start(fixtures.batch())
  let assert Ok(http) =
    clients.start(
      clients.Loopback([fixtures.document_host], services.providers_port),
      None,
    )
  // A hostile batch entry points the fetcher at the provider server.
  let hostile = scripted.providers_base(services) <> "/openai/v1/responses"
  let assert Error(document.Transport(failure) as error) =
    document.fetch(http.fetcher, hostile, document.default_limits())
  assert http_error.reason(failure)
    == http_error.DestinationRejected(destination.HostNotAllowed)
  assert http_error.kind(failure) == http_error.Refused
  assert http_error.evidence(failure) == http_error.NotSent
  assert outcome.decide(outcome.FetchFailed(error))
    == outcome.Discard(
      "document fetch failed: Network destination rejected: host or port not allowed; not sent",
    )
  // The LLM client in turn cannot fetch documents.
  let assert Error(document.Transport(failure)) =
    document.fetch(
      http.llm,
      scripted.document_url(services, fixtures.document_host, "acme"),
      document.default_limits(),
    )
  assert http_error.kind(failure) == http_error.Refused
  // The port is pinned too: the document server shares the provider's host
  // address, and the LLM client still refuses it.
  let assert Error(document.Transport(failure)) =
    document.fetch(
      http.llm,
      "http://127.0.0.1:"
        <> int.to_string(services.documents_port)
        <> "/docs/acme",
      document.default_limits(),
    )
  assert http_error.reason(failure)
    == http_error.DestinationRejected(destination.HostNotAllowed)
  clients.stop(http)
}

/// EXT-7: llm_wire no longer matches the endpoint's host string. http_gun
/// applies the plaintext rule to the resolved address, so a host name that
/// resolves to loopback is admitted and one that resolves elsewhere is refused
/// before anything is sent.
pub fn plaintext_rule_follows_the_resolved_address_test() {
  let assert Ok(services) = scripted.start(fixtures.batch())
  let host = "llm.example.test:" <> int.to_string(services.providers_port)
  let start = fn(address) {
    let assert Ok(client) =
      http_config.default()
      |> http_config.with_destination(
        destination.default()
        |> destination.allow_loopback
        |> destination.only_hosts([host]),
      )
      |> http_config.with_resolver(fn(_host, _remaining) { Ok([address]) })
      |> http_gun.start
    client
  }
  let model = llm.model(llm.OpenAi, "http://" <> host, "sk-scripted")
  let text = fixtures.render(fixtures.acme())
  // The name resolves to loopback: the call runs.
  let loopback = start(destination.Ipv4(127, 0, 0, 1))
  assert llm.extract(loopback, model, "acme", text) == Ok(fixtures.acme())
  http_gun.stop(loopback)
  // The name resolves to a public address: plaintext is refused, unsent, and
  // the failure class decides the job without a string match.
  let public = start(destination.Ipv4(93, 184, 216, 34))
  let assert Error(
    llm.CallFailed(llm_wire.Failure(
      error: error.Http(failure),
      sent: llm_wire.NotSent,
      ..,
    )) as refused,
  ) = llm.extract(public, model, "acme", text)
  assert http_error.reason(failure)
    == http_error.DestinationRejected(destination.PlaintextRefused(
      destination.Public,
    ))
  let assert outcome.Discard(_) = outcome.decide(outcome.ExtractFailed(refused))
  http_gun.stop(public)
}

// Telemetry ---------------------------------------------------------------

pub fn one_job_is_followed_across_packages_test() {
  use context <- with_pipeline("extract_telemetry", fixtures.batch(), live)
  let submitted = submit(context, "initech", llm.Google)
  let assert grind.Succeeded(_) = finish(context, submitted)
  let trace = telemetry.trace(context.collector, "initech")
  let grind = telemetry.count(trace.attributed, telemetry.Grind)
  let http = telemetry.count(trace.attributed, telemetry.Http)
  let llm_attributed = telemetry.count(trace.attributed, telemetry.Llm)
  let llm_lost = telemetry.count(trace.unattributed, telemetry.Llm)
  // admitted, claimed, acknowledged
  assert grind == 3
  // Two requests (document and provider), each with several milestones.
  assert http >= 8
  // started, request_sent, first_progress, terminal and cleanup: llm_wire reads
  // the correlation from the client view, so none is lost.
  assert llm_attributed >= 5
  assert llm_lost == 0
}

/// EXT-1 regression: with an error codec, a snoozed job is re-claimed and
/// runs again, and its finished job can be re-bound from its id.
pub fn snoozed_job_with_error_codec_runs_again_test() {
  use context <- with_pipeline("extract_snooze_typed", fixtures.batch(), live)
  let submitted = submit(context, "globex", llm.Anthropic)
  let assert grind.Succeeded(jobs.Extracted(invoice:, ..)) as finished =
    finish(context, submitted)
  assert invoice == fixtures.globex()
  // The rate-limited first call and the successful second call.
  assert scripted.provider_calls(context.services, "globex") == 2
  let assert Ok(rebound) =
    grind.bind(
      context.pipeline.jobs,
      context.pipeline.worker,
      job.id(submitted.1),
    )
  assert grind.outcome(context.pipeline.jobs, rebound) == Ok(finished)
}

// Failure classes ---------------------------------------------------------

/// EXT-2: http_gun's closed `Kind` and `is_retryable` decide fetch failures
/// and, once llm_wire's `Reason` is rebuilt into a `Failure`, extraction
/// failures; no exhaustive map of reasons is left in the app.
pub fn http_failures_are_decided_by_kind_test() {
  let fetch = fn(reason, evidence) {
    outcome.decide(
      outcome.FetchFailed(document.Transport(http_error.new(reason, evidence))),
    )
  }
  let refused = http_error.ConnectionFailed(http_error.ConnectionRefused)
  assert fetch(refused, http_error.NotSent)
    == outcome.Retry(outcome.Transient(
      outcome.Fetch,
      "document fetch failed: Connection failed: connection refused; not sent",
    ))
  let assert outcome.Retry(_) =
    fetch(http_error.DeadlineExceeded, http_error.MaybeSent)
  let assert outcome.Discard(_) =
    fetch(
      http_error.LimitExceeded(http_error.ResponseBodyBytes, 10, 11),
      http_error.NotSent,
    )
  let assert outcome.Discard(_) =
    fetch(
      http_error.InvalidRequest(http_error.InvalidTarget),
      http_error.NotSent,
    )
  // The same classes through an llm_wire failure.
  let extract = fn(reason, evidence) {
    outcome.decide(
      outcome.ExtractFailed(
        llm.CallFailed(wire_testing.failure(
          message.OpenAI,
          error.Http(http_error.new(reason, evidence)),
        )),
      ),
    )
  }
  let assert outcome.Retry(outcome.Transient(outcome.Extract, _)) =
    extract(refused, http_error.NotSent)
  let assert outcome.Discard(_) =
    extract(
      http_error.DestinationRejected(destination.HostNotAllowed),
      http_error.NotSent,
    )
}

/// The handler runs once in the calling process with a synthetic context,
/// without being submitted; it still writes on the runtime's pool.
pub fn handler_runs_without_a_queue_test() {
  use context <- with_pipeline("extract_handler", fixtures.batch(), live)
  let job =
    jobs.DocumentJob(
      document_id: "acme",
      url: scripted.document_url(
        context.services,
        fixtures.document_host,
        "acme",
      ),
      provider: llm.OpenAi,
    )
  let assert Ok(worker.Succeeded(jobs.Extracted(invoice:, ..))) =
    testing.perform_with(
      context.pipeline.worker,
      testing.context(job_id: 99, attempt: 2)
        |> testing.with_connection(jobs.connection(context.pipeline)),
      job,
    )
  assert invoice == fixtures.acme()
}
