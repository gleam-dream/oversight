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
import grind/job
import grind/postgres
import grind/queue
import grind/registry
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
    store: pog.Connection,
    collector: telemetry.Collector,
    limits: document.Limits,
  )
}

// Worker ------------------------------------------------------------------

/// The worker keeps a retryable failure as a typed `JobError` through its
/// error codec, so an exhausted retry reads back with the app's detail.
pub fn define(env: Env) -> Worker {
  // Grind requires a plain `Result` handler even though the queue handler
  // below replaces it for every queued attempt.
  let perform = fn(job) {
    attempt(env, job)
    |> result.map_error(fn(failure) {
      case outcome.decide(failure) {
        outcome.Retry(error) -> error
        outcome.Snooze(_, reason) | outcome.Discard(reason) ->
          outcome.Transient(outcome.Extract, reason)
      }
    })
  }
  let assert Ok(definition) =
    worker.define_with_error_codec(
      "extractor.invoice",
      "v1",
      input_codec(),
      output_codec(),
      error_codec(),
      perform,
    )
  let assert Ok(definition) = worker.with_max_attempts(definition, 3)
  definition
  |> worker.with_queue_handler(fn(job) {
    case attempt(env, job) {
      Ok(extracted) -> worker.WorkerSucceeded(extracted)
      Error(failure) -> outcome.to_response(outcome.decide(failure))
    }
  })
  |> worker.with_retry_policy(
    worker.retry_policy(fn(_failure, context) {
      let assert Ok(delay) = worker.retry_delay(200 * context.current_attempt)
      worker.RetryAfter(delay)
    }),
  )
}

/// One attempt: fetch, extract, store.
pub fn attempt(
  env: Env,
  job: DocumentJob,
) -> Result(Extracted, outcome.Failure) {
  let correlation = telemetry.begin_attempt(env.collector, job.document_id)
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
    store.save(
      env.store,
      job.document_id,
      llm.provider_name(job.provider),
      invoice,
    )
    |> result.map_error(outcome.StoreFailed),
  )
  Ok(Extracted(row_id:, invoice:))
}

// Codecs ------------------------------------------------------------------

/// One Blueprint codec serves as the Grind codec: `to_json` and `decoder`
/// replace a hand-written gleam_json twin. A value the codec rejects fails
/// `submit` with `InvalidInput` instead of panicking.
fn grind_codec(version: String, blueprint: codec.Codec(a)) -> worker.Codec(a) {
  let assert Ok(wire) =
    worker.codec(
      version,
      fn(value) {
        codec.to_json(blueprint, value)
        |> result.map_error(codec.describe_encode_error)
      },
      codec.decoder(blueprint),
    )
  wire
}

fn input_codec() -> worker.Codec(DocumentJob) {
  grind_codec("document-job-v1", {
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
  grind_codec("extracted-v2", {
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
  grind_codec("job-error-v1", {
    use stage <- codec.field("stage", stage, get: fn(e) { e.stage })
    use detail <- codec.field("detail", codec.string(), get: fn(e) { e.detail })
    codec.success(outcome.Transient(stage:, detail:))
  })
}

// Pipeline ----------------------------------------------------------------

pub type Pipeline {
  Pipeline(
    database: postgres.Database,
    consumer: queue.Consumer,
    worker: Worker,
    queue: String,
    collector: telemetry.Collector,
  )
}

pub fn start(
  database_url: String,
  queue_name: String,
  env: Env,
) -> Result(Pipeline, String) {
  use settings <- result.try(
    postgres.settings(database_url)
    |> postgres.with_pool_size(4)
    |> postgres.validate
    |> result.map_error(string.inspect),
  )
  use database <- result.try(
    postgres.start(settings) |> result.map_error(string.inspect),
  )
  use Nil <- result.try(
    postgres.migrate(database) |> result.map_error(string.inspect),
  )
  let definition = define(env)
  use workers <- result.try(
    registry.new(queue_name)
    |> result.try(registry.register(_, definition))
    |> result.map_error(string.inspect),
  )
  use policy <- result.try(
    queue.QueuePolicy(
      ..queue.default_policy(),
      polling: queue.PollEvery(100),
      maximum_concurrency: 4,
    )
    |> queue.validate_policy
    |> result.map_error(string.inspect),
  )
  use consumer <- result.try(
    queue.start(database, workers, policy) |> result.map_error(string.inspect),
  )
  Ok(Pipeline(
    database:,
    consumer:,
    worker: definition,
    queue: queue_name,
    collector: env.collector,
  ))
}

pub fn submit(pipeline: Pipeline, job: DocumentJob) -> Result(Handle, String) {
  // The queue string is repeated here; nothing ties it to the registry.
  postgres.submit(pipeline.database, pipeline.queue, pipeline.worker, job)
  |> result.map(fn(handle) {
    telemetry.job_submitted(
      pipeline.collector,
      job.id_value(handle),
      job.document_id,
    )
    handle
  })
  |> result.map_error(string.inspect)
}

pub type Finished =
  job.Outcome(Extracted, outcome.JobError)

/// Polls until the job leaves the pending states or the timeout passes.
/// Grind has no await or completion subscription for one handle.
pub fn await(
  pipeline: Pipeline,
  handle: Handle,
  timeout_ms: Int,
) -> Result(Finished, String) {
  case postgres.outcome(pipeline.database, handle) {
    Ok(job.Pending(_)) if timeout_ms > 0 -> {
      process.sleep(50)
      await(pipeline, handle, timeout_ms - 50)
    }
    Ok(finished) -> Ok(finished)
    Error(error) -> Error(string.inspect(error))
  }
}

pub fn await_all(
  pipeline: Pipeline,
  handles: List(#(DocumentJob, Handle)),
  timeout_ms: Int,
) -> List(#(DocumentJob, Result(Finished, String))) {
  list.map(handles, fn(pair) { #(pair.0, await(pipeline, pair.1, timeout_ms)) })
}

pub fn stop(pipeline: Pipeline) -> Nil {
  let _ = queue.stop(pipeline.consumer)
  let _ = postgres.close(pipeline.database)
  Nil
}
