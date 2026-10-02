//// The Grind side: the extraction worker, its persistence codecs, and the
//// batch pipeline (start, submit, await, stop).

import extractor/clients.{type Clients}
import extractor/document
import extractor/invoice.{type Invoice}
import extractor/llm
import extractor/outcome
import extractor/store
import extractor/telemetry
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
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

fn input_codec() -> worker.Codec(DocumentJob) {
  let assert Ok(codec) =
    worker.codec(
      "document-job-v1",
      fn(job: DocumentJob) {
        json.object([
          #("document_id", json.string(job.document_id)),
          #("url", json.string(job.url)),
          #("provider", json.string(llm.provider_name(job.provider))),
        ])
      },
      {
        use document_id <- decode.field("document_id", decode.string)
        use url <- decode.field("url", decode.string)
        use name <- decode.field("provider", decode.string)
        case llm.provider_from_name(name) {
          Ok(provider) ->
            decode.success(DocumentJob(document_id, url, provider))
          Error(Nil) ->
            decode.failure(
              DocumentJob(document_id, url, llm.OpenAi),
              "Provider",
            )
        }
      },
    )
  codec
}

/// Grind codecs are gleam_json + decode; the invoice codec is Blueprint.
/// Blueprint has no `json.Json` or `decode.Decoder` bridge, so the invoice
/// travels as Blueprint JSON text inside a JSON string.
fn output_codec() -> worker.Codec(Extracted) {
  let assert Ok(codec) =
    worker.codec(
      "extracted-v1",
      fn(extracted: Extracted) {
        let assert Ok(text) =
          codec.encode_json(invoice.codec(), extracted.invoice)
        json.object([
          #("row_id", json.int(extracted.row_id)),
          #("invoice", json.string(text)),
        ])
      },
      {
        use row_id <- decode.field("row_id", decode.int)
        use text <- decode.field("invoice", decode.string)
        case codec.decode_json(invoice.codec(), text) {
          Ok(invoice) -> decode.success(Extracted(row_id, invoice))
          Error(_) ->
            decode.failure(
              Extracted(row_id, invoice.Invoice("", "", "", invoice.Usd, [], 0)),
              "Invoice",
            )
        }
      },
    )
  codec
}

fn error_codec() -> worker.Codec(outcome.JobError) {
  let assert Ok(codec) =
    worker.codec(
      "job-error-v1",
      fn(error: outcome.JobError) {
        json.object([
          #("stage", json.string(outcome.stage_name(error.stage))),
          #("detail", json.string(error.detail)),
        ])
      },
      {
        use stage <- decode.field("stage", decode.string)
        use detail <- decode.field("detail", decode.string)
        case outcome.stage_from_name(stage) {
          Ok(stage) -> decode.success(outcome.Transient(stage, detail))
          Error(Nil) ->
            decode.failure(outcome.Transient(outcome.Extract, detail), "Stage")
        }
      },
    )
  codec
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
