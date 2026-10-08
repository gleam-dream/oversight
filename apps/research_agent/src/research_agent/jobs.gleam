//// The research job: one Grind job drives one Fabric run to its end and
//// then the durable publication saga.
////
//// Who owns what:
//// - Grind owns delivery: the job, its lease, its retries and its final
////   state. A job whose node died is replayed after its lease expires
////   (`ReplayAfterLeaseExpiry`), because everything it does is resumable.
//// - Fabric owns the conversation: every turn and tool result is committed
////   to `fabric_runs` (fabric_postgres) before the next step, so a replayed
////   job `recover`s the run and continues from the last commit.
//// - Saga owns the publication's effects and their compensation, with its
////   checkpoint in `saga_executions` (saga_postgres).
//// - The app owns one join: the `research` row names the Grind job, which
////   Grind issues. The run id derives from the job (`run_id`), so a replayed
////   job starts its run idempotently and no row names the run.

import fabric
import fabric/agent.{type Agent}
import fabric/run
import fabric/store.{type Store}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/time/duration
import grind/worker.{type Worker}
import http_gun
import json/blueprint/codec
import pog
import research_agent/db
import research_agent/domain.{type Published, type Research, Article}
import research_agent/events
import research_agent/publish
import research_agent/researcher.{type Context, type Endpoints}
import research_agent/telemetry.{type Telemetry}
import research_agent/wire
import saga/durable
import saga/outcome
import saga/storage.{type Storage}
import sinal/correlation.{type Correlation}

pub const queue = "research"

/// Everything a job handler needs, captured when the worker is defined. The
/// research table is reached through `worker.connection`, Grind's own pool.
pub type Deps {
  Deps(
    runs: Store,
    agent: Agent(Context, domain.Answer),
    context: Context,
    http: http_gun.Client,
    sagas: Storage,
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

fn research_error_codec() -> codec.Codec(ResearchError) {
  codec.union({
    use no_sources <- codec.variant("no_sources", codec.string(), NoSources)
    use agent_stopped <- codec.variant(
      "agent_stopped",
      codec.string(),
      AgentStopped,
    )
    use storage <- codec.variant("storage", codec.string(), Storage)
    codec.match(fn(error) {
      case error {
        NoSources(reason) -> no_sources(reason)
        AgentStopped(reason) -> agent_stopped(reason)
        Storage(reason) -> storage(reason)
      }
    })
  })
}

pub fn worker(deps: Deps) -> Worker(Research, Published, ResearchError) {
  worker.responding(
    "research.run",
    input: wire.grind("research-1", domain.research_codec()),
    output: wire.grind("published-1", domain.published_codec()),
    handle: fn(job, research) { handle(deps, job, research) },
  )
  |> worker.with_error_codec(wire.grind(
    "research-error-2",
    research_error_codec(),
  ))
  |> worker.with_queue(queue)
  |> worker.with_max_attempts(2)
  |> worker.with_retry_policy(fn(error, _attempt) {
    case error {
      // A run that found nothing may succeed later, from a fresh run.
      NoSources(_) -> worker.RetryAfter(duration.milliseconds(200))
      _ -> worker.DoNotRetry
    }
  })
  // Fabric holds the conversation and Saga the publication, so a job whose
  // node died resumes both when Grind runs it again.
  |> worker.with_abandonment(worker.ReplayAfterLeaseExpiry(max_replays: 3))
}

pub fn handle(
  deps: Deps,
  job: worker.Context,
  research: Research,
) -> worker.Response(Published, ResearchError) {
  let conn = worker.connection(job)
  case drive_agent(deps, job, conn, research) {
    Ok(domain.Written(title, body)) -> {
      let _ = db.set_state(conn, research.id, events.Publishing, title)
      let article = Article(research.id, title, body)
      let published =
        publish.run(
          deps.sagas,
          deps.http,
          deps.publisher,
          article,
          worker.correlation(job),
          timeout: duration.seconds(60),
        )
      case published {
        Ok(report) -> {
          case
            outcome.classify(report, fn(error) {
              error.step <> ": " <> error.detail
            })
          {
            Ok(published) -> {
              let _ =
                db.set_state(conn, research.id, events.Published, published.url)
              worker.Succeeded(published)
            }
            Error(outcome.Definitely(detail)) ->
              publication_stopped(conn, research.id, events.Failed, detail)
            Error(outcome.Unknown(detail)) ->
              publication_stopped(conn, research.id, events.Uncertain, detail)
          }
        }
        Error(error) -> {
          let detail =
            "publication not driven: " <> durable.describe_error(error)
          case durable.error_kind(error) {
            // Another runner holds the saga, or the database blinked: the
            // saga's checkpoint is intact, so try again shortly.
            durable.Busy | durable.Transient ->
              worker.Snoozed(after: duration.seconds(1), reason: detail)
            durable.NeedsReconciliation
            | durable.Incompatible
            | durable.Defect -> {
              publication_stopped(conn, research.id, events.Uncertain, detail)
            }
          }
        }
      }
    }
    Ok(domain.NoSources(reason)) -> {
      let _ =
        db.set_state(
          conn,
          research.id,
          events.Researching,
          "no sources: " <> reason,
        )
      worker.Failed(NoSources(reason))
    }
    Error(Unavailable(reason)) ->
      worker.Snoozed(after: duration.seconds(1), reason:)
    Error(Cancelled) -> {
      let _ = db.set_state(conn, research.id, events.Cancelled, "")
      worker.Cancelled("research cancelled")
    }
    Error(Stopped(reason)) -> {
      let _ = db.set_state(conn, research.id, events.Failed, reason)
      worker.Failed(AgentStopped(reason))
    }
  }
}

fn publication_stopped(
  conn: pog.Connection,
  id: String,
  state: events.State,
  detail: String,
) -> worker.Response(Published, ResearchError) {
  let _ = db.set_state(conn, id, state, detail)
  case state {
    events.Failed -> worker.Discarded(detail)
    _ -> worker.Uncertain(detail)
  }
}

type Ending {
  /// Fabric's store could not be read or written: the job tries again.
  Unavailable(reason: String)
  Cancelled
  Stopped(reason: String)
}

/// The Fabric run of one attempt of a job. Grind's `job_id` is stable across
/// replays and `attempt` counts only business attempts, so a replayed job
/// finds its own run and a retried job (`NoSources`) starts a fresh one.
pub fn run_id(job_id: Int, attempt: Int) -> run.RunId {
  run.id_from_parts("research", [int.to_string(job_id), int.to_string(attempt)])
}

/// Starts the attempt's run, or continues the one a replay already has.
fn drive_agent(
  deps: Deps,
  job: worker.Context,
  conn: pog.Connection,
  research: Research,
) -> Result(domain.Answer, Ending) {
  let id = run_id(worker.job_id(job), worker.attempt(job))
  let correlation = worker.correlation(job)
  use handle <- result.try(start_run(deps, conn, research, id, correlation, 3))
  follow(deps, worker.cancellation(job), handle)
}

fn start_run(
  deps: Deps,
  conn: pog.Connection,
  research: Research,
  id: run.RunId,
  correlation: Correlation,
  tries: Int,
) -> Result(fabric.Run(Context, domain.Answer), Ending) {
  let started =
    fabric.start(
      deps.runs,
      deps.agent,
      id:,
      context: deps.context,
      prompt: domain.prompt(research),
      correlation: Some(correlation),
    )
  case started {
    Ok(handle) -> {
      use Nil <- result.map(
        db.set_state(conn, research.id, events.Researching, "")
        |> result.map_error(Stopped),
      )
      handle
    }
    // A replay: on a leased store `recover` is safe at any time. It takes
    // over only a free or expired lease, or a lease of this store whose
    // runner is gone, and otherwise just opens the run.
    Error(fabric.AlreadyStarted(_, same_input: True)) ->
      fabric.recover(deps.runs, deps.agent, deps.context, id)
      |> result.map_error(fn(e) {
        Stopped("recover: " <> fabric.describe_error(e))
      })
    // The same id may be started again: the first start may have landed
    // (`AlreadyStarted`), and a store that blinks while the taken id is
    // compared answers `StoreUnavailable`, which asks to start again.
    Error(fabric.StartUnconfirmed(..))
      | Error(fabric.StoreUnavailable(_))
      if tries > 1
    -> start_run(deps, conn, research, id, correlation, tries - 1)
    Error(e) -> {
      let detail = "start: " <> fabric.describe_error(e)
      case fabric.error_kind(e) {
        // The store is out of reach, but the id is free or ours: Grind
        // delivers the job again, and the start finds its run.
        fabric.Unavailable | fabric.Retry -> Error(Unavailable(detail))
        // Another start's run holds the id (`same_input: False`), or the
        // id holds a record this Fabric cannot read (`CorruptRecord`,
        // `UnsupportedVersion`): no retry changes that.
        _ -> Error(Stopped(detail))
      }
    }
  }
}

/// Waits for the run, or for Grind's cancellation of the job, whichever
/// comes first.
fn follow(
  deps: Deps,
  cancellation: process.Selector(Nil),
  handle: fabric.Run(Context, domain.Answer),
) -> Result(domain.Answer, Ending) {
  let next = fn(handle) { follow(deps, cancellation, handle) }
  case
    fabric.await_with(handle, within: duration.seconds(5), or: cancellation)
  {
    // Grind committed a cancellation of this job: cancel the run, which
    // kills its model call and closes the LLM stream.
    Ok(fabric.Interrupted(Nil)) ->
      case fabric.cancel(handle) {
        Ok(run.Finished(run.Cancelled)) -> Error(Cancelled)
        _ -> next(handle)
      }
    Ok(fabric.Reached(run.Working)) -> next(handle)
    Ok(fabric.Reached(run.Unattended)) ->
      case
        fabric.recover(deps.runs, deps.agent, deps.context, fabric.id(handle))
      {
        Ok(handle) -> next(handle)
        Error(e) -> Error(Stopped("recover: " <> fabric.describe_error(e)))
      }
    // The tools only read and replay (`tool.with_replay`), so an uncertain
    // effect is a read that kept failing: nothing here can settle it.
    Ok(fabric.Reached(run.Suspended([], uncertain))) ->
      Error(Stopped(
        int.to_string(list.length(uncertain)) <> " uncertain tool effects",
      ))
    Ok(fabric.Reached(run.Suspended(approvals, _))) ->
      Error(Stopped(
        int.to_string(list.length(approvals)) <> " unexpected approvals",
      ))
    Ok(fabric.Reached(run.Finished(run.Completed(answer)))) -> Ok(answer)
    Ok(fabric.Reached(run.Finished(run.Cancelled))) -> Error(Cancelled)
    Ok(fabric.Reached(run.Finished(other))) ->
      Error(Stopped(run.describe_outcome(other)))
    Error(e) -> Error(Stopped("await: " <> fabric.describe_error(e)))
  }
}
