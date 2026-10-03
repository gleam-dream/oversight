//// Batch invoice extraction: document URLs become Grind jobs; each job
//// fetches its document through a bounded http_gun stream, asks an LLM for
//// a typed `Invoice` through llm_wire structured output with a Blueprint
//// codec, and stores the result in Postgres.
////
//// `gleam run` (with DATABASE_URL set) runs the scripted demo batch.

import envoy
import extractor/clients
import extractor/document
import extractor/fixtures
import extractor/invoice
import extractor/jobs
import extractor/llm
import extractor/scripted
import extractor/telemetry
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import grind
import grind/job
import http_gun

pub fn main() -> Nil {
  case envoy.get("DATABASE_URL") {
    Error(Nil) ->
      io.println(
        "DATABASE_URL is not set. Run: ../scripts/with-postgres.sh gleam run",
      )
    Ok(url) ->
      case run(url) {
        Ok(Nil) -> Nil
        Error(message) -> io.println("extractor failed: " <> message)
      }
  }
}

/// Which provider each demo document is sent to.
fn assignments() -> List(#(String, llm.Provider)) {
  [
    #("acme", llm.OpenAi),
    #("globex", llm.Anthropic),
    #("initech", llm.Google),
    #("bad-currency", llm.OpenAi),
    #("bad-total", llm.Anthropic),
    #("scan-pdf", llm.Google),
    #("huge", llm.OpenAi),
  ]
}

pub fn run(database_url: String) -> Result(Nil, String) {
  use services <- result.try(scripted.start(fixtures.batch()))
  use collector <- result.try(telemetry.start())
  use http <- result.try(
    clients.start(
      clients.Loopback([fixtures.document_host], services.providers_port),
      Some(collector.http_observations),
    )
    |> result.map_error(http_gun.describe_start_error),
  )
  let env =
    jobs.Env(
      clients: http,
      model: fn(provider) {
        llm.model(provider, scripted.providers_base(services), "sk-scripted")
      },
      collector:,
      limits: document.default_limits(),
    )
  use pipeline <- result.try(jobs.start(database_url, "extraction", env))
  io.println(
    "Submitting a batch of "
    <> int.to_string(list.length(assignments()))
    <> " documents",
  )
  let handles =
    list.filter_map(assignments(), fn(pair) {
      let #(id, provider) = pair
      let job =
        jobs.DocumentJob(
          document_id: id,
          url: scripted.document_url(services, fixtures.document_host, id),
          provider:,
        )
      jobs.submit(pipeline, job) |> result.map(fn(handle) { #(job, handle) })
    })
  let finished = jobs.await_all(pipeline, handles, 15_000)
  list.each(finished, fn(pair) {
    let #(job, result) = pair
    io.println(
      "  "
      <> string.pad_end(job.document_id, 13, " ")
      <> string.pad_end(llm.provider_name(job.provider), 10, " ")
      <> describe(result),
    )
  })
  io.println(
    "Provider calls for globex: "
    <> int.to_string(scripted.provider_calls(services, "globex"))
    <> " (the first was rate limited and snoozed)",
  )
  let trace = telemetry.trace(collector, "globex")
  io.println("Telemetry attributed to globex:")
  list.each(trace.attributed, fn(record) {
    io.println("  " <> telemetry.render(record))
  })
  io.println(
    "Unattributed events across the batch: "
    <> int.to_string(list.length(trace.unattributed))
    <> " (llm_wire "
    <> int.to_string(telemetry.count(trace.unattributed, telemetry.Llm))
    <> ", http_gun "
    <> int.to_string(telemetry.count(trace.unattributed, telemetry.Http))
    <> ")",
  )
  jobs.stop(pipeline)
  clients.stop(http)
  telemetry.stop(collector)
  Ok(Nil)
}

fn describe(result: Result(jobs.Finished, String)) -> String {
  case result {
    Ok(grind.Succeeded(jobs.Extracted(row_id:, invoice:))) ->
      "stored row "
      <> int.to_string(row_id)
      <> ": "
      <> invoice.vendor
      <> " "
      <> invoice.number
      <> ", "
      <> int.to_string(list.length(invoice.line_items))
      <> " lines, "
      <> int.to_string(invoice.total_cents)
      <> " "
      <> invoice.currency_code(invoice.currency)
    Ok(grind.Discarded(reason)) -> "discarded: " <> truncate(reason)
    Ok(grind.Pending(state)) -> "still pending: " <> job.state_name(state)
    Ok(other) -> string.inspect(other)
    Error(message) -> "read failed: " <> message
  }
}

fn truncate(text: String) -> String {
  case string.length(text) > 110 {
    True -> string.slice(text, 0, 110) <> "..."
    False -> text
  }
}
