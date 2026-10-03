//// The Grind side: the extraction worker, its persistence codecs, and the
//// batch pipeline (start, submit, await, stop).

import extractor/clients.{type Clients}
import extractor/document
import extractor/invoice.{type Invoice}
import extractor/llm
import extractor/outcome
import extractor/store
import extractor/telemetry
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/string
import gleam/time/duration
import grind
import grind/job
import grind/queue
import grind/worker
import http_gun
import json/blueprint/codec
import llm_wire/types
import pog

pub type DocumentJob {
  DocumentJob(document_id: String, url: String, provider: llm.Provider)
}

pub type Extracted {
  Extracted(row_id: Int, invoice: Invoice)
}

pub type Worker =
  worker.Worker(DocumentJob, Extracted, outcome.JobError)

pub type Handle =
  job.JobHandle(DocumentJob, Extracted, outcome.JobError)

/// What one attempt needs. The worker closure captures it at definition.
pub type Env {
  Env(
    clients: Clients,
    model: fn(llm.Provider) -> Result(llm.Model, types.WireError),
    collector: telemetry.Collector,
    limits: document.Limits,
  )
}

// Worker ------------------------------------------------------------------

/// The worker keeps a retryable failure as a typed `JobError` through its
/// error codec, so an exhausted retry reads back with the app's detail. The
/// result row is written on Grind's own pool, which `worker.connection`
/// hands to the handler.
pub fn define(env: Env, queue_name: String) -> Worker {
  worker.responding(
    "extractor.invoice",
    input: input_codec(),
    output: output_codec(),
    handle: fn(context, job) {
      case attempt(env, worker.connection(context), context, job) {
        Ok(extracted) -> worker.Succeeded(extracted)
        Error(failure) -> outcome.to_response(outcome.decide(failure))
      }
    },
  )
  |> worker.with_error_codec(error_codec())
  |> worker.with_queue(queue_name)
  |> worker.with_max_attempts(3)
  |> worker.with_retry_policy(fn(_error, attempt) {
    worker.RetryAfter(duration.milliseconds(200 * attempt))
  })
}

/// One attempt: fetch, extract, store.
pub fn attempt(
  env: Env,
  db: pog.Connection,
  context: worker.Context,
  job: DocumentJob,
) -> Result(Extracted, outcome.Failure) {
  let correlation = telemetry.begin_attempt(env.collector, context)
  let fetcher = http_gun.with_correlation(env.clients.fetcher, correlation)
  let llm_client = http_gun.with_correlation(env.clients.llm, correlation)
  use fetched <- result.try(
    document.fetch(fetcher, job.url, env.limits)
    |> result.map_error(outcome.FetchFailed),
  )
  use model <- result.try(
    env.model(job.provider)
    |> result.map_error(fn(error) {
      outcome.ExtractFailed(llm.NotPrepared(error))
    }),
  )
  use invoice <- result.try(
    llm.extract(llm_client, model, job.document_id, fetched.text)
    |> result.map_error(outcome.ExtractFailed),
  )
  use row_id <- result.try(
    store.save(db, job.document_id, llm.provider_name(job.provider), invoice)
    |> result.map_error(outcome.StoreFailed),
  )
  Ok(Extracted(row_id:, invoice:))
}

// Codecs ------------------------------------------------------------------

/// One Blueprint codec serves as the Grind codec: `to_json` and `decoder`
/// replace a hand-written gleam_json twin. A value the codec rejects fails
/// `submit` with `InvalidInput` instead of panicking.
fn grind_codec(blueprint: codec.Codec(a)) -> worker.Codec(a) {
  worker.codec(
    fn(value) {
      codec.to_json(blueprint, value)
      |> result.map_error(codec.describe_encode_error)
    },
    codec.decoder(blueprint),
  )
}

fn input_codec() -> worker.Codec(DocumentJob) {
  grind_codec({
    use document_id <- codec.field("document_id", codec.string(), get: fn(job) {
      job.document_id
    })
    use url <- codec.field("url", codec.string(), get: fn(job) { job.url })
    use provider <- codec.field("provider", llm.provider_codec(), get: fn(job) {
      job.provider
    })
    codec.success(DocumentJob(document_id:, url:, provider:))
  })
}

fn output_codec() -> worker.Codec(Extracted) {
  grind_codec({
    use row_id <- codec.field("row_id", codec.int(), get: fn(e) { e.row_id })
    use invoice <- codec.field("invoice", invoice.codec(), get: fn(e) {
      e.invoice
    })
    codec.success(Extracted(row_id:, invoice:))
  })
}

fn error_codec() -> worker.Codec(outcome.JobError) {
  let stage =
    codec.string_enum([
      #("fetch", outcome.Fetch),
      #("extract", outcome.Extract),
      #("store", outcome.Store),
    ])
  grind_codec({
    use stage <- codec.field("stage", stage, get: fn(e) { e.stage })
    use detail <- codec.field("detail", codec.string(), get: fn(e) { e.detail })
    codec.success(outcome.Transient(stage:, detail:))
  })
}

// Pipeline ----------------------------------------------------------------

pub type Pipeline {
  Pipeline(jobs: grind.Grind, worker: Worker)
}

/// Starts Grind on one pool of the app's own `pog.Config`, migrating its
/// schema before any consumer starts, and creates the app's table on the
/// same pool.
pub fn start(
  database_url: String,
  queue_name: String,
  env: Env,
) -> Result(Pipeline, String) {
  let name = process.new_name("extractor_jobs")
  let definition = define(env, queue_name)
  use pool <- result.try(
    pog.url_config(process.new_name("extractor_pool"), database_url)
    |> result.replace_error("invalid DATABASE_URL"),
  )
  let config =
    grind.new(pool |> pog.pool_size(8))
    |> grind.with_startup_migration
    |> grind.with_worker(definition)
    |> grind.with_queue(
      queue.new(queue_name)
      |> queue.with_poll_interval(duration.milliseconds(100))
      |> queue.with_concurrency(4),
    )
  use jobs <- result.try(
    grind.start(config, name) |> result.map_error(grind.describe_start_error),
  )
  use Nil <- result.try(
    store.migrate(grind.connection(jobs)) |> result.map_error(string.inspect),
  )
  Ok(Pipeline(jobs:, worker: definition))
}

pub fn connection(pipeline: Pipeline) -> pog.Connection {
  grind.connection(pipeline.jobs)
}

pub fn submit(pipeline: Pipeline, job: DocumentJob) -> Result(Handle, String) {
  job.new(pipeline.worker, job)
  |> job.with_correlation(telemetry.document_correlation(job.document_id))
  |> grind.submit(pipeline.jobs, _)
  |> result.map_error(grind.describe_submit_error)
  |> result.map(grind.handle)
}

pub type Finished =
  grind.Outcome(Extracted, outcome.JobError)

pub fn await(
  pipeline: Pipeline,
  handle: Handle,
  timeout_ms: Int,
) -> Result(Finished, String) {
  grind.await(pipeline.jobs, handle, within: duration.milliseconds(timeout_ms))
  |> result.map_error(grind.describe_read_error)
}

pub fn await_all(
  pipeline: Pipeline,
  handles: List(#(DocumentJob, Handle)),
  timeout_ms: Int,
) -> List(#(DocumentJob, Result(Finished, String))) {
  list.map(handles, fn(pair) { #(pair.0, await(pipeline, pair.1, timeout_ms)) })
}

pub fn stop(pipeline: Pipeline) -> Nil {
  let _ = grind.stop(pipeline.jobs)
  Nil
}
