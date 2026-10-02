import envoy
import fabric/run
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import grind/job
import grind/postgres
import grind/worker
import pog
import research_agent/app.{type App}
import research_agent/db
import research_agent/jobs
import research_agent/node
import research_agent/saga_store
import research_agent/services.{type Services}
import research_agent/telemetry.{type Telemetry}
import saga/storage/conformance

pub fn main() -> Nil {
  gleeunit.main()
}

// Fixtures ------------------------------------------------------------------

fn database_url() -> String {
  let assert Ok(url) = envoy.get("DATABASE_URL")
    as "run the tests with ../scripts/with-postgres.sh gleam test"
  url
}

fn settings(
  world: Services,
  node: String,
  schema: String,
  telemetry: option.Option(Telemetry),
) -> app.Settings {
  app.Settings(
    database_url: database_url(),
    node:,
    schema:,
    services: services.base_url(world),
    fabric_lease_ms: 1000,
    telemetry:,
  )
}

type Fixture {
  Fixture(
    world: Services,
    node: App,
    notices: Subject(services.Notice),
    telemetry: Telemetry,
  )
}

fn with_node(schema: String, body: fn(Fixture) -> a) -> a {
  let assert Ok(world) = services.start()
  let notices = process.new_subject()
  services.watch(world, notices)
  let observed = telemetry.start(False)
  let assert Ok(node) =
    app.start(settings(world, "test-node", schema, Some(observed)))
  let result = body(Fixture(world, node, notices, observed))
  app.stop(node)
  telemetry.stop(observed)
  result
}

fn wait_for(
  notices: Subject(services.Notice),
  matching: fn(services.Notice) -> Bool,
  within: Int,
) -> Result(services.Notice, Nil) {
  case process.receive(notices, within) {
    Ok(notice) ->
      case matching(notice) {
        True -> Ok(notice)
        False -> wait_for(notices, matching, within)
      }
    Error(Nil) -> Error(Nil)
  }
}

// Common path -----------------------------------------------------------------

pub fn common_path_publishes_and_checkpoints_the_conversation_test() {
  use f <- with_node("t_common")
  services.script(f.world, "otp", services.happy_script(f.world, "otp"))
  let assert Ok(id) = app.start_research(f.node, "otp")
  let assert Ok(job.SucceededWith(published)) =
    app.await_outcome(f.node, id, 15_000)
  let assert True = string.starts_with(published.url, "https://blog.example/")
  let assert Ok(row) = app.row(f.node, id)
  let assert "published" = row.state

  // Fabric kept the whole conversation in Postgres: user prompt, two tool
  // requests with their results, and the answer.
  let assert Ok(snapshot) = app.snapshot(f.node, id)
  let assert 6 = list.length(snapshot.transcript)
  let assert 3 = snapshot.turns_used
  let assert run.Finished(run.Completed(_)) = snapshot.status

  let counts = services.counts(f.world)
  let assert services.Counts(
    search_calls: 1,
    page_calls: 1,
    llm_calls: 3,
    drafts_created: 1,
    drafts_deleted: 0,
    published: 1,
  ) = counts

  // Following the request across packages: grind (job id), fabric (run id)
  // and http_gun (correlation id) join; llm_wire and saga events cannot.
  let trace = telemetry.trace(f.telemetry, id)
  let sources = telemetry.sources(trace)
  let assert True = list.contains(sources, "grind")
  let assert True = list.contains(sources, "fabric")
  let assert True = list.contains(sources, "http_gun")
  let assert False = list.contains(sources, "llm_wire")
  let assert False = list.contains(sources, "saga")
  let unattributed = trace.unattributed
  let assert Ok(llm_events) = list.key_find(unattributed, "llm_wire")
  let assert True = llm_events > 0
  let assert Ok(saga_events) = list.key_find(unattributed, "saga")
  let assert True = saga_events > 0
  // The model's HTTP calls run on the client fixed at agent build time, so
  // they carry no correlation either.
  let assert Ok(http_unkeyed) = list.key_find(unattributed, "http_gun")
  let assert True = http_unkeyed > 0
}

// Failure: search API down during a turn --------------------------------------

pub fn search_down_once_is_explained_to_the_model_which_retries_test() {
  use f <- with_node("t_search_once")
  services.script(f.world, "beam", [
    services.CallSearch("beam"),
    services.CallSearch("beam"),
    services.CallRead(services.page_url(f.world, "beam-1")),
    services.Answer("TITLE: The BEAM\nSmall processes."),
  ])
  services.fail_searches(f.world, 1)
  let assert Ok(id) = app.start_research(f.node, "beam")
  let assert Ok(job.SucceededWith(_)) = app.await_outcome(f.node, id, 15_000)
  // The failed search reached the model as a tool result, not a crash.
  let assert Ok(snapshot) = app.snapshot(f.node, id)
  let assert Ok(failed) =
    list.find(snapshot.actions, fn(a) {
      case a.state {
        run.ToolFailed(_) -> True
        _ -> False
      }
    })
  // Fabric wraps the `Explain` text as the tool's error result.
  let assert run.ToolFailed(
    "{\"error\":\"the search service is unavailable (HTTP 503)\"}",
  ) = failed.state
  let assert 2 = services.counts(f.world).search_calls
}

pub fn search_down_for_good_retries_the_job_with_a_fresh_run_then_fails_test() {
  use f <- with_node("t_search_down")
  services.script(f.world, "cobol", [
    services.CallSearch("cobol"),
    services.Answer("NO SOURCES the search service is unavailable"),
  ])
  services.set_search_down(f.world, True)
  let assert Ok(id) = app.start_research(f.node, "cobol")
  let assert Ok(outcome) = app.await_outcome(f.node, id, 15_000)
  // The worker's error codec keeps the typed `NoSources` through
  // persistence, with the cause that ended the job (RA-9, grind 7a04831).
  let assert job.BusinessFailedWithCause(
    jobs.NoSources("the search service is unavailable"),
    worker.BudgetExhausted,
  ) = outcome
  // Two attempts, each with its own run (search + answer).
  let assert services.Counts(search_calls: 2, llm_calls: 4, published: 0, ..) =
    services.counts(f.world)
}

// Failure: publish fails after upload → compensation ----------------------------

pub fn publish_failure_after_upload_deletes_the_draft_test() {
  use f <- with_node("t_publish_fails")
  services.script(f.world, "lisp", services.happy_script(f.world, "lisp"))
  services.set_publish_fails(f.world, True)
  let assert Ok(id) = app.start_research(f.node, "lisp")
  let assert Ok(job.DiscardedWithReason(reason)) =
    app.await_outcome(f.node, id, 15_000)
  let assert True = string.contains(reason, "publish")
  let assert [#(_, services.Deleted)] = services.drafts(f.world)
  let assert services.Counts(
    drafts_created: 1,
    drafts_deleted: 1,
    published: 0,
    ..,
  ) = services.counts(f.world)
  let assert Ok(row) = app.row(f.node, id)
  let assert "failed" = row.state
}

// Failure: cancellation ---------------------------------------------------------

pub fn cancellation_reaches_the_run_and_closes_the_llm_stream_test() {
  use f <- with_node("t_cancel")
  services.script(f.world, "erlang", [
    services.CallSearch("erlang"),
    services.Stall,
  ])
  let assert Ok(id) = app.start_research(f.node, "erlang")
  let assert Ok(_) =
    wait_for(
      f.notices,
      fn(n) {
        case n {
          services.LlmStalled("erlang", 1) -> True
          _ -> False
        }
      },
      10_000,
    )

  // Grind's cancellation alone: recorded, but the handler is never told, so
  // the agent keeps streaming.
  let assert Ok(postgres.CancellationRequested) = app.cancel_job(f.node, id)
  let assert Error(Nil) =
    wait_for(
      f.notices,
      fn(n) {
        case n {
          services.LlmStreamClosed(_, _) -> True
          _ -> False
        }
      },
      500,
    )

  // The app's API also cancels the Fabric run: its model task is killed and
  // the HTTP stream closes.
  let assert Ok(app.Cancellation(_, Some(run.Finished(run.Cancelled)))) =
    app.cancel_research(f.node, id)
  let assert Ok(services.LlmStreamClosed("erlang", 1)) =
    wait_for(
      f.notices,
      fn(n) {
        case n {
          services.LlmStreamClosed(_, _) -> True
          _ -> False
        }
      },
      5000,
    )
  let assert Ok(job.CancelledWithReason(_)) =
    app.await_outcome(f.node, id, 10_000)
  let assert 0 = services.counts(f.world).drafts_created
}

// Advanced: crash recovery across VMs ------------------------------------------

/// Starts research on a node in another VM, kills that VM when `ready`
/// matches a notice, then recovers on a node in this VM.
fn crash_and_recover(
  schema: String,
  topic: String,
  script: fn(Services) -> List(services.Step),
  arm: fn(Services) -> Nil,
  ready: fn(services.Notice) -> Bool,
  check: fn(Fixture, String) -> Nil,
) -> Nil {
  let assert Ok(world) = services.start()
  let notices = process.new_subject()
  services.watch(world, notices)
  services.script(world, topic, script(world))
  arm(world)
  let assert Ok(peer) = node.start_peer()
  let assert Ok(id) =
    node.start_research_on(peer, settings(world, "node-a", schema, None), topic)
  let assert Ok(_) = wait_for(notices, ready, 20_000)
  node.kill(peer)

  // A new node in this VM. Grind's lease (6 s) must expire before the
  // abandoned attempt is quarantined; then the app authorizes its replay.
  let observed = telemetry.start(False)
  let assert Ok(survivor) =
    app.start(settings(world, "node-b", schema, Some(observed)))
  let assert Ok(1) = release_abandoned(survivor, 40)
  check(Fixture(world, survivor, notices, observed), id)
  app.stop(survivor)
  telemetry.stop(observed)
}

fn release_abandoned(node: App, tries: Int) -> Result(Int, String) {
  case app.recover_abandoned(node) {
    Ok(0) if tries > 0 -> {
      process.sleep(250)
      release_abandoned(node, tries - 1)
    }
    other -> other
  }
}

pub fn a_killed_vm_resumes_from_the_last_checkpoint_test() {
  use f, id <- crash_and_recover(
    "t_crash_model",
    "gleam",
    fn(world) {
      [
        services.CallSearch("gleam"),
        services.StallOnce(
          services.CallRead(services.page_url(world, "gleam-1")),
        ),
        services.Answer("TITLE: Gleam\nA friendly language for the BEAM."),
      ]
    },
    fn(_) { Nil },
    fn(n) {
      case n {
        services.LlmStalled("gleam", 1) -> True
        _ -> False
      }
    },
  )
  let assert Ok(job.SucceededWith(_)) = app.await_outcome(f.node, id, 20_000)
  // Resumed, not restarted: the search done before the crash is not repeated,
  // and the model call lost with the VM is issued again (3 + 1 calls).
  let assert services.Counts(
    search_calls: 1,
    page_calls: 1,
    llm_calls: 4,
    published: 1,
    ..,
  ) = services.counts(f.world)
  let assert Ok(snapshot) = app.snapshot(f.node, id)
  let assert True = snapshot.incarnation >= 1
  let assert Ok(row) = app.row(f.node, id)
  let assert "published" = row.state
  Nil
}

pub fn a_tool_interrupted_by_a_crash_is_reconciled_by_the_app_test() {
  use f, id <- crash_and_recover(
    "t_crash_tool",
    "elixir",
    services.happy_script(_, "elixir"),
    fn(world) { services.stall_page(world, "elixir-1") },
    fn(n) {
      case n {
        services.PageStalled("elixir-1") -> True
        _ -> False
      }
    },
  )
  let assert Ok(job.SucceededWith(_)) = app.await_outcome(f.node, id, 20_000)
  // The read became an uncertain effect; the app read the page again and
  // reconciled the action with that result.
  let assert Ok(snapshot) = app.snapshot(f.node, id)
  let assert Ok(read) =
    list.find(snapshot.actions, fn(a) { a.call.name == "read" })
  let assert run.Reconciled(_) = read.state
  let assert services.Counts(search_calls: 1, page_calls: 2, published: 1, ..) =
    services.counts(f.world)
  Nil
}

// Glue checked against the owning package's contract ---------------------------

pub fn the_postgres_saga_storage_passes_saga_conformance_test() {
  let assert Ok(config) =
    pog.url_config(process.new_name("conformance_pool"), database_url())
  let assert Ok(started) = pog.start(config)
  let conn = started.data
  let assert Ok(Nil) = db.migrate(conn)
  let assert Ok(Nil) =
    conformance.run(
      fn() {
        let id = "conformance-" <> int.to_string(int.random(1_000_000_000))
        let store = saga_store.new(conn, "conformance", 10_000)
        Ok(
          conformance.Fixture(saga_store.storage(store, id), fn() {
            saga_store.delete(store, id)
          }),
        )
      },
      5000,
    )
}
