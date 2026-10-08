import envoy
import fabric/run
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleeunit
import grind
import grind/admin
import grind/job
import legacy_publication
import pog
import research_agent/app.{type App}
import research_agent/domain
import research_agent/events
import research_agent/jobs
import research_agent/node
import research_agent/publish
import research_agent/services.{type Services}
import research_agent/telemetry.{type Telemetry}
import saga/durable
import saga/storage
import saga/storage/conformance
import saga_postgres
import sinal
import sinal/correlation

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
    fabric_lease: duration.seconds(1),
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
  let assert Ok(grind.Succeeded(published)) =
    app.await_outcome(f.node, id, duration.seconds(15))
  let assert True = string.starts_with(published.url, "https://blog.example/")
  let assert Ok(row) = app.row(f.node, id)
  let assert "published" = row.state
  // The unqualified `research` table lives in the node's schema, because the
  // app's pool keeps its own `search_path`.
  let assert Ok(pog.Returned(1, _)) =
    pog.query(
      "SELECT 1 FROM information_schema.tables
       WHERE table_schema = 't_common' AND table_name = 'research'",
    )
    |> pog.execute(f.node.db)

  // Fabric kept the whole conversation in Postgres: user prompt, two tool
  // requests with their results, and the answer.
  let assert Ok(snapshot) = app.snapshot(f.node, id)
  let assert 6 = list.length(snapshot.transcript)
  let assert 3 = snapshot.turns_used
  let assert run.Finished(run.Completed(domain.Written(_, _))) = snapshot.status

  // The model was asked for the union's schema, wrapped for the provider
  // (`fabric/llm`: the root of an output schema must be an object).
  let assert [first, ..] = services.llm_requests(f.world, "otp")
  let assert True =
    list.all(
      [
        "\"strict\":true",
        "\"required\":[\"answer\"]",
        "\"anyOf\"",
        "\"no_sources\"",
        "\"written\"",
      ],
      string.contains(first, _),
    )

  let counts = services.counts(f.world)
  let assert services.Counts(
    search_calls: 1,
    page_calls: 1,
    llm_calls: 3,
    drafts_created: 1,
    drafts_deleted: 0,
    published: 1,
  ) = counts

  // Following the request across packages: grind, saga, http_gun and
  // llm_wire carry the research's `Correlation`; fabric joins through its
  // run id.
  let trace = telemetry.trace(f.telemetry, id)
  let sources = telemetry.sources(trace)
  let assert True = list.contains(sources, "grind")
  // The app's own events carry the research id as a `Correlation`: they join
  // with no registry, in the order the states were reached.
  let assert True = list.contains(sources, "research_agent")
  let states =
    trace.events
    |> list.filter(fn(e) { e.source == "research_agent" })
    |> list.map(fn(e) { e.detail })
  let assert ["queued", "researching", "publishing", "published"] = states
  let assert True = list.contains(sources, "fabric")
  let assert True = list.contains(sources, "http_gun")
  // The durable saga carries the job's correlation: its run
  // and step events join the request, and none is left over.
  let assert True = list.contains(sources, "saga")
  // The model runs on the research's correlated client view, and llm_wire
  // reads the correlation from it: its events join, and none is left over.
  let assert True = list.contains(sources, "llm_wire")
  let assert Error(Nil) = list.key_find(trace.unattributed, "fabric")
  let assert Error(Nil) = list.key_find(trace.unattributed, "llm_wire")
  let assert Error(Nil) = list.key_find(trace.unattributed, "saga")
  let assert Error(Nil) = list.key_find(trace.unattributed, "http_gun")
}

// Failure: search API down during a turn --------------------------------------

pub fn search_down_once_is_explained_to_the_model_which_retries_test() {
  use f <- with_node("t_search_once")
  services.script(f.world, "beam", [
    services.CallSearch("beam"),
    services.CallSearch("beam"),
    services.CallRead(services.page_url(f.world, "beam-1")),
    services.article("The BEAM", "Small processes."),
  ])
  services.fail_searches(f.world, 1)
  let assert Ok(id) = app.start_research(f.node, "beam")
  let assert Ok(grind.Succeeded(_)) =
    app.await_outcome(f.node, id, duration.seconds(15))
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
    services.no_sources("the search service is unavailable"),
  ])
  services.set_search_down(f.world, True)
  let assert Ok(id) = app.start_research(f.node, "cobol")
  let assert Ok(outcome) = app.await_outcome(f.node, id, duration.seconds(15))
  // The worker's error codec keeps the typed `NoSources` through
  // persistence, with the cause that ended the job.
  let assert grind.Failed(
    grind.Business(jobs.NoSources("the search service is unavailable")),
    Some(job.BudgetExhausted),
    _,
  ) = outcome
  // Two attempts, each with its own run (search + answer).
  let assert services.Counts(search_calls: 2, llm_calls: 4, published: 0, ..) =
    services.counts(f.world)
}

// Failure: the model's answer does not read --------------------------------------

pub fn a_refused_answer_gets_a_corrective_turn_and_then_publishes_test() {
  use f <- with_node("t_corrective")
  services.script(f.world, "rust", [
    services.CallSearch("rust"),
    services.GarbledOnce(services.article("Rust", "Ownership, without a GC.")),
  ])
  let assert Ok(id) = app.start_research(f.node, "rust")
  let assert Ok(grind.Succeeded(_)) =
    app.await_outcome(f.node, id, duration.seconds(15))
  // search, the refused answer, and the corrective turn's answer
  let assert services.Counts(search_calls: 1, llm_calls: 3, published: 1, ..) =
    services.counts(f.world)
  let assert Ok(snapshot) = app.snapshot(f.node, id)
  let assert run.Finished(run.Completed(domain.Written("Rust", _))) =
    snapshot.status
}

// Failure: publish fails after upload → compensation ----------------------------

pub fn publish_failure_after_upload_deletes_the_draft_test() {
  use f <- with_node("t_publish_fails")
  services.script(f.world, "lisp", services.happy_script(f.world, "lisp"))
  services.set_publish_fails(f.world, True)
  let assert Ok(id) = app.start_research(f.node, "lisp")
  let assert Ok(grind.Discarded(reason)) =
    app.await_outcome(f.node, id, duration.seconds(15))
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

pub fn cancelling_the_job_reaches_the_run_and_closes_the_llm_stream_test() {
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

  // Grind's cancellation alone: the handler sees it through its job
  // context (within a third of the 6 s lease) and cancels the Fabric run,
  // whose model task is killed, so the HTTP stream closes.
  let assert Ok(grind.CancellationRequested) = app.cancel_research(f.node, id)
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
  let assert Ok(grind.Cancelled(reason)) =
    app.await_outcome(f.node, id, duration.seconds(10))
  let assert Ok(snapshot) = app.snapshot(f.node, id)
  let assert run.Finished(run.Cancelled) = snapshot.status
  let assert Ok(row) = app.row(f.node, id)
  let assert "cancelled" = row.state
  let assert 0 = services.counts(f.world).drafts_created
  // Grind keeps the caller's reason, not the handler's `Cancelled` reason.
  let assert "cancelled by caller" = reason
  Nil
}

// Advanced: crash recovery across VMs ------------------------------------------

/// Starts research on a node in another VM, kills that VM when `ready`
/// matches a notice, then recovers on a node in this VM.
fn crash_and_recover(
  schema: String,
  expected_state: job.State,
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

  // A new node in this VM. Once Grind's lease (6 s) expires, the worker's
  // abandonment policy (`ReplayAfterLeaseExpiry`) requeues the job, and
  // this node's consumer runs it again: no app sweep, no operator decision.
  let observed = telemetry.start(False)
  let assert Ok(survivor) =
    app.start(settings(world, "node-b", schema, Some(observed)))
  check(Fixture(world, survivor, notices, observed), id)
  // The operator view shows one recovery delivery and no manual decision.
  let assert Ok([summary]) =
    admin.list(
      survivor.jobs,
      admin.query(limit: 10) |> admin.in_queue(jobs.queue),
    )
  let assert 1 = summary.replay_count
  let assert True = summary.state == expected_state
  // The replay did not use up a business attempt, as
  // `worker.with_max_attempts` documents: the job
  // finished as its first attempt.
  let assert 1 = summary.attempt
  let trace = telemetry.trace(observed, id)
  let assert False = list.any(trace.events, fn(e) { e.name == "job.resolved" })
  // Grind reports the replay: one `[grind, job, quarantined]` event with
  // `replayed: True`, joined to the request by its correlation.
  let assert [quarantined] =
    list.filter(trace.events, fn(e) { e.name == "job.quarantined" })
  let assert "lease expired, replayed" = quarantined.detail
  app.stop(survivor)
  telemetry.stop(observed)
}

pub fn a_killed_vm_resumes_from_the_last_checkpoint_test() {
  use f, id <- crash_and_recover(
    "t_crash_model",
    job.Succeeded,
    "gleam",
    fn(world) {
      [
        services.CallSearch("gleam"),
        services.StallOnce(
          services.CallRead(services.page_url(world, "gleam-1")),
        ),
        services.article("Gleam", "A friendly language for the BEAM."),
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
  let assert Ok(grind.Succeeded(_)) =
    app.await_outcome(f.node, id, duration.seconds(30))
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

pub fn a_read_interrupted_by_a_crash_is_replayed_by_fabric_test() {
  use f, id <- crash_and_recover(
    "t_crash_tool",
    job.Succeeded,
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
  let assert Ok(grind.Succeeded(_)) =
    app.await_outcome(f.node, id, duration.seconds(30))
  // The read is bound with `tool.with_replay`: the recovered run started
  // it again, with no uncertain effect for the app to reconcile.
  let assert Ok(snapshot) = app.snapshot(f.node, id)
  let assert Ok(read) =
    list.find(snapshot.actions, fn(a) { a.call.name == "read" })
  let assert run.Succeeded(_) = read.state
  let assert 1 = read.replays
  let assert services.Counts(search_calls: 1, page_calls: 2, published: 1, ..) =
    services.counts(f.world)
  Nil
}

// The shared pool checked against the owning package's contract ----------------

/// The saga storage is saga_postgres on the pool Grind built from the app's
/// `pog.Config` (the app's `search_path`, Grind's isolation and
/// idle-in-transaction timeout), and it still passes saga's conformance
/// suite there.
pub fn saga_postgres_on_the_shared_pool_passes_saga_conformance_test() {
  use f <- with_node("t_saga_conformance")
  let lease = duration.seconds(1)
  let assert Ok(Nil) =
    conformance.run(
      fn() {
        let schema = "t_saga_c" <> int.to_string(int.random(1_000_000_000))
        let assert Ok(config) =
          saga_postgres.config(f.node.db)
          |> saga_postgres.with_lease(lease)
          |> saga_postgres.with_schema(schema)
        let assert Ok(Nil) = saga_postgres.migrate(config)
        Ok(
          conformance.fixture(saga_postgres.storage(config), cleanup: fn() {
            let _ =
              pog.query("DROP SCHEMA " <> schema <> " CASCADE")
              |> pog.execute(f.node.db)
            Nil
          }),
        )
      },
      timeout: duration.seconds(5),
      owner_loss_within: duration.add(lease, duration.milliseconds(500)),
    )
}

// The app's own event ------------------------------------------------------------

/// `fields.enum` cannot check its list against the type, so every state must
/// round-trip through the event: a constructor missing from the list would
/// make observers skip it.
pub fn every_research_state_reaches_an_observer_with_its_correlation_test() {
  let seen = process.new_subject()
  let attachment =
    sinal.observe(events.state_changed(), fn(_, m: events.Transition) {
      process.send(seen, m)
    })
  let id = correlation.unique()
  let states = [
    events.Queued,
    events.Researching,
    events.Publishing,
    events.Published,
    events.Failed,
    events.Cancelled,
    events.Uncertain,
  ]
  list.each(states, fn(state) {
    events.announce(correlation.to_string(id), state)
  })
  let received =
    list.map(states, fn(_) {
      let assert Ok(transition) = process.receive(seen, 1000)
      transition
    })
  let assert Ok(Nil) = sinal.detach(attachment)
  let assert True =
    received == list.map(states, fn(state) { events.Transition(state, id) })
}

pub fn applied_creation_with_lost_reply_stays_uncertain_test() {
  use f <- with_node("t_creation_reply_loss")
  services.script(f.world, "lost", [services.article("Lost", "Body")])
  services.fault(f.world, services.Creation, services.DropReply)
  let assert Ok(id) = app.start_research(f.node, "lost")
  let assert Ok(grind.Uncertain(_)) =
    app.await_outcome(f.node, id, duration.seconds(15))
  let assert [#(_, services.Draft)] = services.drafts(f.world)
  let assert 1 = services.calls(f.world, services.Creation)
  let assert 0 = services.calls(f.world, services.Deletion)
  let assert Ok(row) = app.row(f.node, id)
  let assert "uncertain" = row.state
}

fn unknown_publication(
  schema: String,
  operation: services.Operation,
  fault: services.Fault,
) {
  use f <- with_node(schema)
  services.script(f.world, "unknown", [services.article("Unknown", "Body")])
  services.fault(f.world, operation, fault)
  let assert Ok(id) = app.start_research(f.node, "unknown")
  let assert Ok(grind.Uncertain(_)) =
    app.await_outcome(f.node, id, duration.seconds(15))
  let assert 1 = services.calls(f.world, services.Creation)
  let assert 1 = services.calls(f.world, operation)
  let assert 0 = services.calls(f.world, services.Deletion)
  let assert Ok(row) = app.row(f.node, id)
  let assert "uncertain" = row.state
  case operation {
    services.Creation -> {
      let assert [#(_, services.Draft)] = services.drafts(f.world)
      Nil
    }
    services.Upload -> {
      let assert [#(_, services.BodyUploaded)] = services.drafts(f.world)
      Nil
    }
    services.Publication -> {
      let assert [#(_, services.Live)] = services.drafts(f.world)
      Nil
    }
    _ -> panic as "unexpected operation"
  }
}

pub fn malformed_creation_success_is_uncertain_test() {
  unknown_publication(
    "t_create_malformed",
    services.Creation,
    services.MalformedReply,
  )
}

pub fn applied_upload_with_lost_reply_is_uncertain_test() {
  unknown_publication("t_upload_lost", services.Upload, services.DropReply)
}

pub fn applied_publication_with_lost_reply_is_uncertain_test() {
  unknown_publication(
    "t_publish_lost",
    services.Publication,
    services.DropReply,
  )
}

pub fn malformed_publication_success_is_uncertain_test() {
  unknown_publication(
    "t_publish_malformed",
    services.Publication,
    services.MalformedReply,
  )
}

pub fn rejected_publication_with_failed_cleanup_is_uncertain_test() {
  use f <- with_node("t_failed_cleanup")
  services.script(f.world, "cleanup", [services.article("Cleanup", "Body")])
  services.fault(f.world, services.Publication, services.Reject)
  services.fault(f.world, services.Deletion, services.Reject)
  let assert Ok(id) = app.start_research(f.node, "cleanup")
  let assert Ok(grind.Uncertain(_)) =
    app.await_outcome(f.node, id, duration.seconds(15))
  let assert [#(_, services.BodyUploaded)] = services.drafts(f.world)
  let assert 0 = services.counts(f.world).published
  let assert Ok(row) = app.row(f.node, id)
  let assert "uncertain" = row.state
}

fn interrupted_publication(schema: String, operation: services.Operation) {
  use f, id <- crash_and_recover(
    schema,
    job.Succeeded,
    "interrupted",
    fn(_) { [services.article("Interrupted", "Body")] },
    fn(world) { services.fault(world, operation, services.HoldReply) },
    fn(notice) { notice == services.MutationApplied(operation) },
  )
  let assert Ok(grind.Succeeded(_)) =
    app.await_outcome(f.node, id, duration.seconds(30))
  let assert 1 = services.calls(f.world, services.Creation)
  let assert 1 = services.calls(f.world, services.Upload)
  let assert 1 = services.calls(f.world, services.Publication)
  let assert 0 = services.calls(f.world, services.Deletion)
  let assert [#(_, services.Live)] = services.drafts(f.world)
  Nil
}

pub fn interrupted_creation_uses_readback_test() {
  interrupted_publication("t_crash_create", services.Creation)
}

pub fn interrupted_upload_uses_readback_test() {
  interrupted_publication("t_crash_upload", services.Upload)
}

pub fn interrupted_publication_uses_readback_test() {
  interrupted_publication("t_crash_publish", services.Publication)
}

pub fn legacy_checkpoint_is_refused_without_mutating_it_test() {
  use f <- with_node("t_legacy_publish")
  services.fault(f.world, services.Creation, services.DropReply)
  let article = domain.Article("legacy", "Legacy", "Body")
  let assert Ok(_) =
    legacy_publication.run(
      f.node.deps.sagas,
      f.node.http,
      services.base_url(f.world),
      article,
      correlation.from_key("legacy"),
      timeout: duration.seconds(10),
    )
  let assert Ok(before) =
    storage.do_load(f.node.deps.sagas, publish.execution_id("legacy"))
  let assert Error(error) =
    publish.run(
      f.node.deps.sagas,
      f.node.http,
      services.base_url(f.world),
      article,
      correlation.from_key("legacy"),
      timeout: duration.seconds(10),
    )
  let assert durable.Incompatible = durable.error_kind(error)
  let assert Ok(after) =
    storage.do_load(f.node.deps.sagas, publish.execution_id("legacy"))
  let assert True = before == after
  let assert 1 = services.calls(f.world, services.Creation)
  let assert 0 = services.calls(f.world, services.Deletion)
}

pub fn interrupted_publication_without_readback_stays_uncertain_test() {
  use f, id <- crash_and_recover(
    "t_crash_unknown",
    job.Uncertain,
    "unconfirmed",
    fn(_) { [services.article("Unconfirmed", "Body")] },
    fn(world) {
      services.fault(world, services.Publication, services.HoldReply)
      services.fault(world, services.Inspection, services.Reject)
    },
    fn(notice) { notice == services.MutationApplied(services.Publication) },
  )
  let assert Ok(grind.Uncertain(_)) =
    app.await_outcome(f.node, id, duration.seconds(30))
  let assert 1 = services.calls(f.world, services.Publication)
  let assert 0 = services.calls(f.world, services.Deletion)
  let assert [#(_, services.Live)] = services.drafts(f.world)
  let assert Ok(row) = app.row(f.node, id)
  let assert "uncertain" = row.state
  Nil
}
