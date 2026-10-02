//// The research job: one Grind job drives one Fabric run to its end and
//// then the durable publication saga.
////
//// Who owns what:
//// - Grind owns delivery: the job, its lease, its retries and its final
////   state. A job whose node died becomes `uncertain`; `recover_abandoned`
////   authorizes its replay, because everything it does is resumable.
//// - Fabric owns the conversation: every turn and tool result is committed
////   to `fabric_runs` (fabric_postgres) before the next step, so a replayed
////   job `recover`s the run and continues from the last commit.
//// - Saga owns the publication's effects and their compensation, with its
////   checkpoint in `saga_executions`.
//// - The app owns the join: the `research` row that names the job id and
////   the run id, which none of the three packages can hold for the others.

import fabric
import fabric/agent.{type Agent}
import fabric/run
import fabric/store.{type Store}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import grind/job
import grind/postgres
import grind/worker.{type Worker}
import http_gun
import pog
import research_agent/db
import research_agent/domain.{type Published, type Research, Article}
import research_agent/publish
import research_agent/researcher.{type Context, type Endpoints}
import research_agent/saga_store.{type SagaStore}
import research_agent/telemetry.{type Telemetry}
import saga/execution

pub const queue = "research"

/// Everything a job handler needs, captured when the worker is defined.
pub type Deps {
  Deps(
    db: pog.Connection,
    runs: Store,
    agent: Agent(Context),
    http: http_gun.Client,
    sagas: SagaStore,
    endpoints: Endpoints,
    publisher: String,
    telemetry: Option(Telemetry),
  )
}

/// The job's typed failure. The worker's error codec keeps it through
/// persistence, so `outcome` returns it and the retry policy sees it.
pub type ResearchError {
  NoSources(reason: String)
  AgentStopped(reason: String)
  Storage(reason: String)
}

fn research_error_json(error: ResearchError) -> json.Json {
  let #(kind, reason) = case error {
    NoSources(reason) -> #("no_sources", reason)
    AgentStopped(reason) -> #("agent_stopped", reason)
    Storage(reason) -> #("storage", reason)
  }
  json.object([#("kind", json.string(kind)), #("reason", json.string(reason))])
}

fn research_error_decoder() -> decode.Decoder(ResearchError) {
  use kind <- decode.field("kind", decode.string)
  use reason <- decode.field("reason", decode.string)
  case kind {
    "no_sources" -> decode.success(NoSources(reason))
    "agent_stopped" -> decode.success(AgentStopped(reason))
    "storage" -> decode.success(Storage(reason))
    _ -> decode.failure(Storage(reason), "ResearchError")
  }
}

pub fn worker(deps: Deps) -> Worker(Research, Published, ResearchError) {
  let assert Ok(input) =
    worker.codec("research-1", domain.research_json, domain.research_decoder())
  let assert Ok(output) =
    worker.codec(
      "published-1",
      domain.published_json,
      domain.published_decoder(),
    )
  let assert Ok(error) =
    worker.codec(
      "research-error-1",
      research_error_json,
      research_error_decoder(),
    )
  // `define` needs a plain handler even though the queue handler below is
  // the one Grind calls (EXT-8).
  let assert Ok(defined) =
    worker.define_with_error_codec(
      "research.run",
      "1",
      input,
      output,
      error,
      fn(research) {
        case handle(deps, research) {
          worker.WorkerSucceeded(published) -> Ok(published)
          _ -> Error(AgentStopped("see the queue handler"))
        }
      },
    )
  let assert Ok(defined) = worker.with_max_attempts(defined, 2)
  defined
  |> worker.with_queue_handler(handle(deps, _))
  |> worker.with_retry_policy(
    worker.retry_policy(fn(failure, _context) {
      case failure {
        // A run that found nothing may succeed later, from a fresh run.
        worker.BusinessFailure(NoSources(_)) -> {
          let assert Ok(delay) = worker.retry_delay(200)
          worker.RetryAfter(delay)
        }
        worker.BusinessFailure(_) -> worker.DoNotRetry
      }
    }),
  )
}

pub fn handle(
  deps: Deps,
  research: Research,
) -> worker.WorkerResponse(Published, ResearchError) {
  let context = researcher.context(deps.http, deps.telemetry, research.id)
  case drive_agent(deps, context, research) {
    Ok(domain.Written(title, body)) -> {
      let _ = db.set_state(deps.db, research.id, "publishing", title)
      let article = Article(research.id, title, body)
      case publish.run(deps.sagas, context.http, deps.publisher, article) {
        Ok(execution.Completed(published)) -> {
          let _ = db.set_state(deps.db, research.id, "published", published.url)
          worker.WorkerSucceeded(published)
        }
        Ok(outcome) -> {
          let detail = publish.describe(outcome)
          let _ = db.set_state(deps.db, research.id, "failed", detail)
          // Rolled back (or needs a person): a retry would reconnect to the
          // same finished saga, so the job ends here.
          worker.WorkerDiscarded(detail)
        }
        Error(error) -> {
          let detail = "publication not driven: " <> string.inspect(error)
          let _ = db.set_state(deps.db, research.id, "failed", detail)
          worker.WorkerUncertain(detail)
        }
      }
    }
    Ok(domain.NoSources(reason)) -> {
      let _ =
        db.set_state(
          deps.db,
          research.id,
          "researching",
          "no sources: " <> reason,
        )
      worker.WorkerFailed(NoSources(reason))
    }
    Error(Cancelled) -> {
      let _ = db.set_state(deps.db, research.id, "cancelled", "")
      worker.WorkerCancelled("research cancelled")
    }
    Error(Stopped(reason)) -> {
      let _ = db.set_state(deps.db, research.id, "failed", reason)
      worker.WorkerFailed(AgentStopped(reason))
    }
  }
}

type Ending {
  Cancelled
  Stopped(reason: String)
}

/// Starts the run, or continues the one this research already has.
fn drive_agent(
  deps: Deps,
  context: Context,
  research: Research,
) -> Result(domain.Answer, Ending) {
  use row <- result.try(
    db.get(deps.db, research.id) |> result.map_error(Stopped),
  )
  use handle <- result.try(case row.run_id {
    None -> start_run(deps, context, research)
    Some(id) -> {
      let assert Ok(id) = run.parse_id(id)
      // On a leased store `recover` is safe at any time: it takes over only
      // a free or expired lease, or a lease of this store whose runner is
      // gone, and otherwise just opens the run.
      fabric.recover(deps.runs, deps.agent, context, id)
      |> result.map_error(fn(e) { Stopped("recover: " <> string.inspect(e)) })
      |> result.try(fn(handle) {
        // A previous attempt that found no sources ends a run; a retry
        // starts afresh.
        case fabric.await(handle, 0) {
          Ok(run.Finished(run.Completed(text))) ->
            case domain.parse_answer(text) {
              Ok(domain.NoSources(_)) -> start_run(deps, context, research)
              _ -> Ok(handle)
            }
          _ -> Ok(handle)
        }
      })
    }
  })
  follow(deps, context, handle)
}

fn start_run(
  deps: Deps,
  context: Context,
  research: Research,
) -> Result(fabric.Run(Context), Ending) {
  use handle <- result.try(
    fabric.start(deps.runs, deps.agent, context, domain.prompt(research))
    |> result.map_error(fn(e) { Stopped("start: " <> string.inspect(e)) }),
  )
  // Fabric issues the run id, so it is recorded only after the run's first
  // commit (FEEDBACK RA-2).
  let id = run.id_to_string(fabric.id(handle))
  telemetry.bind_run(deps.telemetry, id, research.id)
  use Nil <- result.map(
    db.set_run(deps.db, research.id, id) |> result.map_error(Stopped),
  )
  handle
}

fn follow(
  deps: Deps,
  context: Context,
  handle: fabric.Run(Context),
) -> Result(domain.Answer, Ending) {
  case fabric.await(handle, 1000) {
    Ok(run.Working) -> follow(deps, context, handle)
    Ok(run.Unattended) ->
      case fabric.recover(deps.runs, deps.agent, context, fabric.id(handle)) {
        Ok(handle) -> follow(deps, context, handle)
        Error(e) -> Error(Stopped("recover: " <> string.inspect(e)))
      }
    Ok(run.Suspended([], uncertain)) ->
      case reconcile_all(deps, context, handle, uncertain) {
        Ok(Nil) -> follow(deps, context, handle)
        Error(reason) -> Error(Stopped(reason))
      }
    Ok(run.Suspended(approvals, _)) ->
      Error(Stopped(
        int.to_string(list.length(approvals)) <> " unexpected approvals",
      ))
    Ok(run.Finished(run.Completed(text))) ->
      domain.parse_answer(text) |> result.map_error(Stopped)
    Ok(run.Finished(run.Cancelled)) -> Error(Cancelled)
    Ok(run.Finished(other)) -> Error(Stopped(string.inspect(other)))
    Error(e) -> Error(Stopped("await: " <> string.inspect(e)))
  }
}

fn reconcile_all(
  deps: Deps,
  context: Context,
  handle: fabric.Run(Context),
  uncertain: List(run.UncertainAction),
) -> Result(Nil, String) {
  use snapshot <- result.try(
    fabric.snapshot(handle) |> result.map_error(string.inspect),
  )
  list.try_each(uncertain, fn(action) {
    use content <- result.try(researcher.replay_read_only(
      deps.endpoints,
      context,
      snapshot,
      action,
    ))
    fabric.reconcile(handle, action.reference, content)
    |> result.replace(Nil)
    |> result.map_error(string.inspect)
  })
}

// Abandoned jobs ------------------------------------------------------------

/// Grind never redelivers a job whose node died: the expired attempt is
/// quarantined as `uncertain` and waits for an audited decision. Research is
/// resumable (Fabric holds the conversation, Saga the publication), so the
/// app authorizes the replay of each of its uncertain jobs. Returns how many
/// jobs it released.
pub fn recover_abandoned(
  grind: postgres.Database,
  research_worker: Worker(Research, Published, ResearchError),
  database: pog.Connection,
  node: String,
) -> Result(Int, String) {
  use _ <- result.try(
    postgres.quarantine_expired(grind, limit: 100)
    |> result.map_error(string.inspect),
  )
  use rows <- result.try(db.unfinished(database))
  list.try_fold(rows, 0, fn(released, row) {
    let assert Some(job_id) = row.job_id
    use handle <- result.try(
      postgres.bind_handle(grind, research_worker, job_id)
      |> result.map_error(string.inspect),
    )
    case postgres.state(grind, handle) {
      Ok(job.Uncertain) -> {
        let request =
          postgres.ResolutionRequest(
            resolution_id: "replay-"
              <> row.id
              <> "-"
              <> int.to_string(int.random(1_000_000_000)),
            resolved_by: node,
            details: "the agent run and the publication are checkpointed; a replay resumes them",
            decision: postgres.AuthorizeReplay,
          )
        postgres.resolve_uncertain(grind, handle, request)
        |> result.replace(released + 1)
        |> result.map_error(string.inspect)
      }
      Ok(_) -> Ok(released)
      Error(error) -> Error(string.inspect(error))
    }
  })
}
