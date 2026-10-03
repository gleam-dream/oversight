//// `gleam run` (with DATABASE_URL, e.g. `../scripts/with-postgres.sh gleam run`)
//// tells the story of four research requests against scripted services.

import envoy
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam/time/duration
import research_agent/app
import research_agent/services
import research_agent/telemetry

pub fn main() -> Nil {
  case envoy.get("DATABASE_URL") {
    Error(Nil) ->
      io.println(
        "research_agent needs PostgreSQL: run `../scripts/with-postgres.sh gleam run`.",
      )
    Ok(url) -> story(url)
  }
}

fn story(url: String) -> Nil {
  let assert Ok(world) = services.start()
  let notices = process.new_subject()
  services.watch(world, notices)
  let observed = telemetry.start(False)
  let assert Ok(node) =
    app.start(app.Settings(
      database_url: url,
      node: "demo-1",
      schema: "research_demo",
      services: services.base_url(world),
      fabric_lease: duration.seconds(3),
      telemetry: Some(observed),
    ))
  io.println(
    "research_agent: one node, scripted search, pages, publisher and LLM\n",
  )

  // 1. The common path.
  services.script(world, "otp", services.happy_script(world, "otp"))
  let assert Ok(first) = app.start_research(node, "otp")
  io.println("1. start_research(\"otp\") -> " <> first)
  let outcome = app.await_outcome(node, first, duration.seconds(10))
  io.println("   job outcome: " <> string.inspect(outcome))
  let assert Ok(snapshot) = app.snapshot(node, first)
  io.println(
    "   fabric checkpointed "
    <> int.to_string(list.length(snapshot.transcript))
    <> " conversation messages over "
    <> int.to_string(snapshot.turns_used)
    <> " model turns",
  )
  let trace = telemetry.trace(observed, first)
  io.println(
    "   telemetry joined to this request: "
    <> int.to_string(list.length(trace.events))
    <> " events from "
    <> string.join(telemetry.sources(trace), ", "),
  )
  io.println(
    "   events no request id could claim: "
    <> string.inspect(trace.unattributed),
  )

  // 2. The search API is down for one call: the model sees the failure and
  //    searches again.
  services.script(world, "beam", [
    services.CallSearch("beam"),
    services.CallSearch("beam"),
    services.CallRead(services.page_url(world, "beam-1")),
    services.Answer(
      "TITLE: The BEAM\nA virtual machine for many small processes.",
    ),
  ])
  services.fail_searches(world, 1)
  let assert Ok(second) = app.start_research(node, "beam")
  io.println("\n2. search answers 503 once -> " <> second)
  io.println(
    "   job outcome: "
    <> string.inspect(app.await_outcome(node, second, duration.seconds(10))),
  )

  // 3. Publishing fails after the body was uploaded: the saga deletes the
  //    draft and the job is discarded.
  services.script(world, "lisp", services.happy_script(world, "lisp"))
  services.set_publish_fails(world, True)
  let assert Ok(third) = app.start_research(node, "lisp")
  io.println("\n3. the publisher rejects the publish step -> " <> third)
  io.println(
    "   job outcome: "
    <> string.inspect(app.await_outcome(node, third, duration.seconds(10))),
  )
  io.println(
    "   drafts at the publisher: " <> string.inspect(services.drafts(world)),
  )
  services.set_publish_fails(world, False)

  // 4. Cancellation while the model is streaming.
  services.script(world, "erlang", [
    services.CallSearch("erlang"),
    services.Stall,
  ])
  let assert Ok(fourth) = app.start_research(node, "erlang")
  io.println("\n4. cancel while the LLM stream is open -> " <> fourth)
  let assert Ok(services.LlmStalled(_, _)) = wait_notice(notices, 10_000)
  let cancelled = app.cancel_research(node, fourth)
  io.println("   cancel_research: " <> string.inspect(cancelled))
  io.println("   provider saw: " <> string.inspect(wait_notice(notices, 5000)))
  io.println(
    "   job outcome: "
    <> string.inspect(app.await_outcome(node, fourth, duration.seconds(10))),
  )

  io.println(
    "\ncounts at the scripted services: "
    <> string.inspect(services.counts(world)),
  )
  app.stop(node)
  telemetry.stop(observed)
}

fn wait_notice(
  notices: process.Subject(services.Notice),
  within: Int,
) -> Result(services.Notice, Nil) {
  process.receive(notices, within)
}
