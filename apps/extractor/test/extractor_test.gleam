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
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import gleeunit
import grind/job
import grind/worker
import http_gun/error as http_error
import json/blueprint/codec
import llm_wire/session
import llm_wire/types

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

/// Starts scripted services, telemetry, both clients, the store and a
/// Grind pipeline on its own queue. `providers_base` overrides where the
/// LLM calls go.
fn with_pipeline(
  queue: String,
  documents: List(scripted.Document),
  providers_base: fn(scripted.Services) -> String,
  run: fn(Context) -> a,
) -> a {
  with_retention(queue, documents, providers_base, jobs.DescriptionOnly, run)
}

fn with_retention(
  queue: String,
  documents: List(scripted.Document),
  providers_base: fn(scripted.Services) -> String,
  retention: jobs.ErrorRetention,
  run: fn(Context) -> a,
) -> a {
  let assert Ok(services) = scripted.start(documents)
  let assert Ok(collector) = telemetry.start(queue)
  let assert Ok(http) =
    clients.start(
      clients.Loopback([fixtures.document_host]),
      Some(collector.http_observations),
    )
  let assert Ok(db) = store.start(database_url())
  let assert Ok(Nil) = store.migrate(db)
  let base = providers_base(services)
  let env =
    jobs.Env(
      clients: http,
      model: fn(provider) { llm.model(provider, base, "sk-scripted") },
      store: db,
      collector:,
      limits: document.default_limits(),
    )
  let assert Ok(pipeline) = jobs.start(database_url(), queue, env, retention)
  let result = run(Context(services:, collector:, http:, env:, pipeline:))
  jobs.stop(pipeline)
  clients.stop(http)
  telemetry.stop(collector)
  result
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
  let assert Ok(finished) = jobs.await(context.pipeline, submitted.1, 10_000)
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
  let assert Error(codec.TypedCodecFailure(codec.DecodeAtField("total_cents", _))) =
    codec.decode_json(invoice_codec, string.replace(text, "4490", "9999"))
  // An unknown currency fails as an enum label.
  let assert Error(codec.TypedCodecFailure(codec.DecodeAtField(
    "currency",
    codec.CannotDecode(codec.DecodeUnknownEnumLabel("YEN")),
  ))) = codec.decode_json(invoice_codec, string.replace(text, "EUR", "YEN"))
}

pub fn batch_is_extracted_and_stored_test() {
  use context <- with_pipeline(
    "extract_common",
    fixtures.batch(),
    scripted.providers_base,
  )
  let submitted = [
    submit(context, "acme", llm.OpenAi),
    submit(context, "initech", llm.Google),
  ]
  let assert [
    job.SucceededWith(jobs.Extracted(row_id: acme_row, invoice: acme)),
    job.SucceededWith(jobs.Extracted(invoice: initech, ..)),
  ] = list.map(submitted, finish(context, _))
  assert acme == fixtures.acme()
  assert initech == fixtures.initech()
  let assert Ok([stored]) = store.find(context.env.store, "acme")
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
    clients.start(clients.Loopback([fixtures.document_host]), None)
  let text = fixtures.render(fixtures.acme())
  let results =
    list.map([llm.OpenAi, llm.Anthropic, llm.Google], fn(provider) {
      let assert Ok(model) =
        llm.model(provider, scripted.providers_base(services), "sk-scripted")
      llm.extract(http.llm, model, "acme", text)
    })
  assert results
    == [Ok(fixtures.acme()), Ok(fixtures.acme()), Ok(fixtures.acme())]
  assert scripted.provider_calls(services, "acme") == 3
  // A 429 from each provider wire becomes the same Grind decision.
  let decisions =
    list.map([llm.OpenAi, llm.Anthropic, llm.Google], fn(provider) {
      let assert Ok(model) =
        llm.model(provider, scripted.providers_base(services), "sk-scripted")
      let assert Error(failure) =
        llm.extract(http.llm, model, "throttled", text)
      outcome.decide(outcome.ExtractFailed(failure))
    })
  assert decisions
    == list.repeat(outcome.Snooze(2000, "provider answered 429"), 3)
  clients.stop(http)
}

pub fn nullable_output_field_is_not_portable_to_google_test() {
  // An optional purchase-order number, explicit null when absent.
  let with_po =
    codec.object(codec.required("po_number", codec.nullable(codec.string())))
  let prepared =
    list.map([llm.OpenAi, llm.Anthropic, llm.Google], fn(provider) {
      let assert Ok(model) =
        llm.model(provider, "http://127.0.0.1:9", "sk-scripted")
      session.prepare_structured(
        model.settings,
        llm.request(model, "acme", "text"),
        "po",
        with_po,
      )
      |> result.is_ok
    })
  assert prepared == [True, True, False]
}

// Failure paths -----------------------------------------------------------

pub fn rate_limit_snoozes_for_the_retry_after_hint_test() {
  // The pure mapping: llm_wire's typed hint becomes a Grind snooze.
  let rate_limited =
    llm.CallFailed(
      provider: types.Anthropic,
      error: types.HttpStatusError(429, "{}", Some(types.RetryDelaySeconds(1))),
      evidence: types.RetryEvidence(
        types.RequestMayHaveReachedProvider,
        True,
        False,
      ),
    )
  assert outcome.decide(outcome.ExtractFailed(rate_limited))
    == outcome.Snooze(1000, "provider answered 429")
  let assert worker.WorkerSnoozed(delay, _) =
    outcome.to_response(outcome.Snooze(1000, "provider answered 429"))
  assert worker.retry_delay_milliseconds(delay) == 1000

  // End to end: the first call is refused, the job is snoozed, the second
  // call succeeds.
  use context <- with_pipeline(
    "extract_rate_limit",
    fixtures.batch(),
    scripted.providers_base,
  )
  let started = timestamp.system_time()
  let submitted = submit(context, "globex", llm.Anthropic)
  let assert job.SucceededWith(jobs.Extracted(invoice:, ..)) =
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
  use context <- with_pipeline(
    "extract_invalid_output",
    fixtures.batch(),
    scripted.providers_base,
  )
  let assert [job.DiscardedWithReason(currency), job.DiscardedWithReason(total)] =
    list.map(
      [
        submit(context, "bad-currency", llm.OpenAi),
        submit(context, "bad-total", llm.Google),
      ],
      finish(context, _),
    )
  // Schema validation rejects the enum; the codec's own check rejects the total.
  assert string.starts_with(
    currency,
    "invalid structured output: Structured output failed schema validation",
  )
  assert string.starts_with(
    total,
    "invalid structured output: Structured output failed codec decode",
  )
  assert store.find(context.env.store, "bad-currency") == Ok([])
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
    scripted.providers_base,
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
  let assert [job.DiscardedWithReason(huge), job.DiscardedWithReason(pdf)] =
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
    "http://127.0.0.1:9"
  })
  let submitted = submit(context, "acme", llm.OpenAi)
  // Without an error codec (the EXT-1 workaround) the typed JobError is
  // gone; only Grind's fixed description survives.
  let assert job.FailedOperationallyWithCause(detail, worker.BudgetExhausted) =
    finish(context, submitted)
  assert detail == "worker returned an application error"
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
    clients.start(clients.Loopback([fixtures.document_host]), None)
  // A hostile batch entry points the fetcher at the provider server.
  let hostile = scripted.providers_base(services) <> "/openai/v1/responses"
  let assert Error(
    document.Transport(http_error.Failure(
      reason: http_error.DestinationRejected,
      evidence: http_error.NotSubmitted,
    )) as error,
  ) = document.fetch(http.fetcher, hostile, document.default_limits())
  assert outcome.decide(outcome.FetchFailed(error))
    == outcome.Discard(
      "document fetch failed: Network destination rejected; not submitted",
    )
  // The LLM client in turn cannot fetch documents.
  let assert Error(document.Transport(http_error.Failure(
    reason: http_error.DestinationRejected,
    ..,
  ))) =
    document.fetch(
      http.llm,
      scripted.document_url(services, fixtures.document_host, "acme"),
      document.default_limits(),
    )
  clients.stop(http)
}

// Telemetry ---------------------------------------------------------------

pub fn one_job_is_followed_across_packages_test() {
  use context <- with_pipeline(
    "extract_telemetry",
    fixtures.batch(),
    scripted.providers_base,
  )
  let submitted = submit(context, "initech", llm.Google)
  let assert job.SucceededWith(_) = finish(context, submitted)
  let trace = telemetry.trace(context.collector, "initech")
  let grind = telemetry.count(trace.attributed, telemetry.Grind)
  let http = telemetry.count(trace.attributed, telemetry.Http)
  let llm_attributed = telemetry.count(trace.attributed, telemetry.Llm)
  let llm_lost = telemetry.count(trace.unattributed, telemetry.Llm)
  // admitted, claimed, acknowledged
  assert grind == 3
  // Two requests (document and provider), each with several milestones.
  assert http >= 8
  // Only `prepared` runs in the worker process; request_sent, first_progress,
  // terminal and cleanup run in llm_wire's stream owner and carry no key.
  assert llm_attributed == 1
  assert llm_lost >= 4
}

/// Documents the Grind defect behind EXT-1: with an error codec, a snoozed
/// job is re-claimed as a contract mismatch instead of running again.
pub fn snooze_with_error_codec_is_a_contract_mismatch_test() {
  use context <- with_retention(
    "extract_snooze_typed",
    fixtures.batch(),
    scripted.providers_base,
    jobs.TypedErrors,
  )
  let submitted = submit(context, "globex", llm.Anthropic)
  assert finish(context, submitted)
    == job.FailedOperationally(
      "stored error codec version none does not match registered version job-error-v1",
    )
  // The second, successful provider call never happens.
  assert scripted.provider_calls(context.services, "globex") == 1
}
