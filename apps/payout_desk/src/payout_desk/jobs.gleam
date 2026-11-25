//// The durable work around a payout, as Grind jobs, and the follower of the
//// payout point's settlements.
////
//// Who owns what:
////
//// - **Grind** owns delivery: each job, its lease, its retries. A job whose
////   handler died is replayed after its lease expires
////   (`ReplayAfterLeaseExpiry`), because every handler here converges on
////   what is already recorded.
//// - **Fabric** owns the agent's conversations (`fabric_postgres`). The run
////   that proposes ends when its policy hands the proposal over; its
////   transcript stays there, with no process, for as long as people take,
////   and the follow-on run that tells the outcome continues from it.
//// - **decisions** owns the decision record, its wake-ups and settlement
////   notices (`decisions_postgres`), and the record of the effect
////   (`report`).
//// - **Saga** owns the payout's dependent steps and their compensation
////   (`workflow`).
//// - **The application** owns the joins: the request names its
////   occurrence; the occurrence's explanation names the run and the action;
////   the release key names the instruction, the Saga execution and the
////   provider's payment.
////
//// The jobs:
////
//// | Worker | Input | Does |
//// | --- | --- | --- |
//// | `payout.agent` | request id | Drives the agent's run until it hands `propose_payout` over, and admits the call at the `payout` point |
//// | `payout.pay` | occurrence id | Runs the payout workflow for a released occurrence and reports the effect |
//// | `payout.reconcile` | occurrence id | Settles an uncertain payout by asking the provider |
//// | `payout.tell` | occurrence id | Runs the follow-on run with what really happened, and tells the seller what the record says |

import decisions.{type Desk}
import decisions/model as decisions_model
import decisions/occurrence.{type Occurrence}
import decisions/vocabulary.{
  type Effect, Manifest, NotPerformed, ParentRun, Performed, RunAction, Subject,
  Trigger, Uncertain,
}
import decisions_postgres
import fabric/agent.{type Agent}
import fabric/run
import fabric/store.{type Store}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import grind
import grind/job
import grind/worker.{type Worker}
import payout_desk/agent.{type Session, Session} as payout_agent
import payout_desk/db
import payout_desk/desks.{type Desks}
import payout_desk/domain.{type Payout, type Reply}
import payout_desk/events
import payout_desk/provider.{type Provider}
import payout_desk/reads
import payout_desk/workflow
import pog
import saga/durable
import saga/execution
import saga/storage.{type Storage}
import sinal/correlation

pub const queue = "payouts"

/// Everything a handler needs, captured when the workers are defined.
pub type Deps {
  Deps(
    jobs: grind.Grind,
    runs: Store,
    agent: Agent(Session, Reply),
    desks: Desks,
    provider: Provider,
    sagas: Storage,
    provider_timeout_ms: Int,
    /// A fault point after the provider answered a payment, given the pay
    /// job's handler process; `fn(_) { Nil }` otherwise.
    after_paid: fn(process.Pid) -> Nil,
    /// A fault point after the agent's run handed its proposal over and
    /// ended, and before the proposal is admitted; `fn() { Nil }`
    /// otherwise.
    before_admit: fn() -> Nil,
  )
}

fn payouts(deps: Deps) -> Desk(Payout, pog.Connection) {
  desks.payout(deps.desks)
}

// -- Workers ------------------------------------------------------------------------

type Handler =
  fn(Deps, pog.Connection, String) -> worker.Response(String, String)

fn define(
  deps: Deps,
  id: String,
  handler: Handler,
) -> Worker(String, String, String) {
  let text = worker.codec(worker.infallible(json.string), decode.string)
  worker.responding(id, input: text, output: text, handle: fn(job, input) {
    handler(deps, worker.connection(job), input)
  })
  |> worker.with_error_codec(text)
  |> worker.with_queue(queue)
  |> worker.with_max_attempts(20)
  |> worker.with_retry_policy(fn(_, _) {
    worker.RetryAfter(duration.milliseconds(200))
  })
  // Every handler converges on what is recorded, so a lost one is replayed.
  |> worker.with_abandonment(worker.ReplayAfterLeaseExpiry(max_replays: 5))
}

pub fn agent_worker(deps: Deps) -> Worker(String, String, String) {
  define(deps, "payout.agent", propose)
}

pub fn pay_worker(deps: Deps) -> Worker(String, String, String) {
  define(deps, "payout.pay", pay)
}

pub fn reconcile_worker(deps: Deps) -> Worker(String, String, String) {
  define(deps, "payout.reconcile", reconcile)
}

pub fn tell_worker(deps: Deps) -> Worker(String, String, String) {
  define(deps, "payout.tell", tell)
}

/// Submit a job in the caller's transaction, once per `id`.
fn submit(
  deps: Deps,
  tx: pog.Connection,
  definition: Worker(String, String, String),
  input: String,
  request: String,
  after: Option(duration.Duration),
) -> Result(Nil, String) {
  let submitted =
    job.new(definition, input)
    |> job.with_id(worker.id(definition) <> ":" <> input)
    |> job.with_correlation(correlation.from_key(request))
  let submitted = case after {
    Some(delay) -> job.after(submitted, delay)
    None -> submitted
  }
  grind.submit_in(deps.jobs, tx, submitted)
  |> result.replace(Nil)
  |> result.map_error(grind.describe_submit_error)
}

/// The occurrence's key: the request's. A request is one payout: its
/// expectation, any failed attempt of its agent and the occurrence its
/// gated tool call becomes are one record, and a redelivered or replayed
/// tool call of the request's run admits nothing twice. The call's own
/// identity (run and action) is the occurrence's trigger and explanation.
/// A request id is at most 64 bytes, so the key, and the release key that
/// adds `release:` to it, stay well within the store's 255.
pub fn request_key(request: String) -> String {
  "payout:" <> request
}

/// The longest request id `request` accepts, in bytes.
pub const max_request_id_bytes = 64

/// Record a request, expect a payout for it, and queue its agent, in one
/// transaction: from then on the record knows the payout is in flight,
/// and an event that makes it stale supersedes it even before the agent
/// proposes. A request id over `max_request_id_bytes` is refused.
pub fn request(
  deps: Deps,
  db: pog.Connection,
  request: domain.Request,
  requested_by requested_by: String,
) -> Result(Nil, String) {
  use Nil <- result.try(
    case string.byte_size(request.id) <= max_request_id_bytes {
      True -> Ok(Nil)
      False -> Error("a request id is at most 64 bytes")
    },
  )
  decisions_postgres.transaction_with(db, fn(tx) {
    use Nil <- result.try(
      db.put_request(tx, request, requested_by)
      |> result.map_error(fn(e) { decisions_postgres.Own(db.describe(e)) }),
    )
    use Nil <- result.try(
      decisions.expect(
        payouts(deps),
        tx,
        key: request_key(request.id),
        trigger: Trigger("request", request.id),
        about: Subject("seller", request.seller),
      )
      |> decisions_postgres.desk,
    )
    submit(deps, tx, agent_worker(deps), request.id, request.id, None)
    |> result.map_error(decisions_postgres.Own)
  })
  |> result.map_error(fn(failure) {
    case failure {
      decisions_postgres.LibraryFailed(failure) ->
        decisions_postgres.describe(failure)
      decisions_postgres.OwnFailed(detail) -> detail
    }
  })
}

// -- payout.agent -------------------------------------------------------------------

/// Drive a request's agent and admit its gated call: the `payout.agent`
/// job's handler. Safe to run twice, at once or in turn: the run and the
/// occurrence are both found by the request, and a run that already handed
/// its call over is read, not run again. A request whose payout was
/// superseded before the agent proposed is not driven; one superseded
/// while it drove is refused at admission, and its run has already ended.
pub fn propose(
  deps: Deps,
  conn: pog.Connection,
  request_id: String,
) -> worker.Response(String, String) {
  case db.request(conn, request_id) {
    Error(error) -> worker.Discarded(db.describe(error))
    Ok(#(request, requested_by)) ->
      case prior(deps, conn, request.id) {
        Ended(vocabulary.Superseded(_)) ->
          worker.Succeeded("superseded before the agent proposed")
        Ended(vocabulary.DeadlinePassed) ->
          worker.Succeeded("its deadline passed before the agent proposed")
        Attempts(failed) ->
          drive_and_admit(deps, conn, request, requested_by, failed)
        // Without the record the job cannot tell which run is this
        // attempt's: driving the first one again could repeat a failure.
        Unread(detail) ->
          worker.Snoozed(
            duration.milliseconds(200),
            "the request's record was not read: " <> detail,
          )
      }
  }
}

/// What the request's record says before the agent is driven.
type Prior {
  /// The record ended before anything was proposed: a newer event superseded
  /// the payout, or a deadline of its own passed. No payout is expected with
  /// one today.
  Ended(cause: vocabulary.ExpiryCause)
  /// So many of the request's agent runs failed before this one.
  Attempts(failed: Int)
  /// The record could not be read.
  Unread(detail: String)
}

fn prior(deps: Deps, conn: pog.Connection, request: String) -> Prior {
  case
    decisions_postgres.transaction(conn, decisions.read_record(
      payouts(deps),
      _,
      key: request_key(request),
    ))
  {
    Ok(decisions.NotBegun(pending)) ->
      case pending.ended {
        Some(cause) -> Ended(cause)
        None -> Attempts(list.length(pending.attempts))
      }
    Ok(decisions.Begun(known)) -> Attempts(list.length(known.attempts))
    Error(error) -> Unread(decisions_postgres.describe(error))
  }
}

fn drive_and_admit(
  deps: Deps,
  conn: pog.Connection,
  request: domain.Request,
  requested_by: String,
  failed: Int,
) -> worker.Response(String, String) {
  {
    let session =
      Session(
        request: request.id,
        seller: request.seller,
        sources: reads.live(conn),
        settled: None,
      )
    let id = payout_agent.run_id(request.id, failed)
    case
      payout_agent.drive(
        deps.runs,
        deps.agent,
        session,
        id:,
        prompt: payout_agent.prompt(request),
        within: duration.seconds(10),
      )
    {
      // Delivered again after the payout was told: nothing to admit.
      Ok(payout_agent.Answered(_)) -> worker.Succeeded("answered")
      Ok(payout_agent.HandedOver(call:, actions:)) ->
        admit(deps, conn, request, requested_by, call, actions)
      Error(payout_agent.StillWorking) ->
        worker.Snoozed(duration.milliseconds(200), "the run is working")
      Error(payout_agent.RunsUnavailable(detail)) ->
        worker.Snoozed(duration.milliseconds(200), detail)
      Error(payout_agent.RunStopped(detail)) -> {
        // The record keeps the failed attempt under the request's key,
        // beside its expectation. It is what counts the request's
        // attempts (`prior`), so the job fails only once the attempt is
        // on it; until then the next delivery finds the same stopped run.
        case
          decisions_postgres.transaction(conn, decisions.record_failure(
            payouts(deps),
            _,
            key: request_key(request.id),
            trigger: Trigger("request", request.id),
            about: Subject("seller", request.seller),
            failure: decisions_model.Declined(detail),
          ))
        {
          Ok(_) -> worker.Failed(detail)
          Error(error) ->
            worker.Snoozed(
              duration.milliseconds(200),
              "the failed attempt was not recorded: "
                <> decisions_postgres.describe(error),
            )
        }
      }
    }
  }
}

fn admit(
  deps: Deps,
  conn: pog.Connection,
  request: domain.Request,
  requested_by: String,
  call: payout_agent.Handed,
  actions: List(run.ActionRecord),
) -> worker.Response(String, String) {
  deps.before_admit()
  let #(ref, _) = db.request_document(request)
  let context = Manifest(refs: [ref], renderer: "payout-1")
  case
    decisions_model.run(
      payout_agent.reported(call, actions),
      context,
      reads.live(conn),
    )
  {
    Error(failure) -> worker.Failed(decisions_model.describe(failure))
    Ok(recommendation) -> {
      let proposal =
        decisions.proposal(
          trigger: Trigger("tool_call", run.action_ref_to_string(call.action)),
          about: Subject("seller", request.seller),
          context:,
          recommending: recommendation,
        )
        |> decisions.asked_by(requested_by)
        |> decisions.hanging_from(ParentRun(run.id_to_string(call.action.run)))
      let admitted =
        decisions_postgres.transaction_with(conn, fn(tx) {
          use known <- result.try(
            decisions.recommend_once(
              payouts(deps),
              tx,
              key: request_key(request.id),
              proposal:,
            )
            |> decisions_postgres.desk,
          )
          db.admitted(tx, request.id, known.id)
          |> result.replace(known)
          |> result.map_error(decisions_postgres.Own)
        })
      case admitted {
        Ok(known) -> {
          events.announce(
            request.id,
            events.Admitted,
            occurrence.status_name(known.status),
          )
          worker.Succeeded(known.id)
        }
        // The seller's account was suspended while the agent worked: the
        // payout is stale before it began. The run already ended with its
        // handover, so nothing waits on it; the settlement follower tells
        // the seller.
        Error(decisions_postgres.LibraryFailed(decisions_postgres.Refused(decisions.SupersededBefore(
          _,
        )))) -> worker.Succeeded("superseded before the agent proposed")
        Error(decisions_postgres.LibraryFailed(decisions_postgres.Refused(
          refusal,
        ))) ->
          case decisions.disposition(refusal) {
            decisions.Transient | decisions.Retry ->
              worker.Snoozed(
                duration.milliseconds(200),
                decisions.describe(refusal),
              )
            decisions.Poisoned -> worker.Discarded(decisions.describe(refusal))
            decisions.Final -> worker.Failed(decisions.describe(refusal))
          }
        Error(decisions_postgres.LibraryFailed(failure)) ->
          worker.Snoozed(
            duration.milliseconds(200),
            decisions_postgres.describe(failure),
          )
        Error(decisions_postgres.OwnFailed(error)) ->
          worker.Snoozed(duration.milliseconds(200), db.describe(error))
      }
    }
  }
}

// -- The settlement follower -----------------------------------------------------------

/// What follows a payout's settlement, in the transaction that marks the
/// notice delivered: a released payout is paid; any other outcome is told.
pub fn follower(deps: Deps) -> decisions_postgres.Follower {
  #(domain.payout_point_name, fn(tx, id) {
    case decisions.read(payouts(deps), tx, occurrence: id) {
      Ok(known) -> follow(deps, tx, id, known)
      // Superseded before the agent proposed: there is no occurrence and no
      // handed-over call to continue from, so the seller is told here, once.
      Error(decisions.SupersededBefore(event:)) ->
        tell_superseded_before(tx, id, event)
      Error(refusal) -> Error(decisions.DeskRefused(refusal))
    }
  })
}

/// The request whose payout the record under `key` is (`request_key`).
pub fn request_of_key(key: String) -> Result(String, Nil) {
  case string.starts_with(key, "payout:") {
    True -> Ok(string.drop_start(key, 7))
    False -> Error(Nil)
  }
}

fn tell_superseded_before(
  tx: pog.Connection,
  key: String,
  event: String,
) -> Result(Nil, decisions.HandlerFailure) {
  let failed = fn(detail) { decisions.ApplicationFailed(detail) }
  use request_id <- result.try(
    request_of_key(key)
    |> result.replace_error(failed("not a payout key: " <> key)),
  )
  use #(request, _) <- result.try(
    db.request(tx, request_id)
    |> result.map_error(fn(e) { failed(db.describe(e)) }),
  )
  let truth = domain.Superseded(event)
  use first <- result.map(
    db.tell(
      tx,
      key,
      db.Told(
        seller: request.seller,
        outcome: domain.outcome_name(truth),
        message: domain.plain_message(request.seller, truth),
        from_agent: False,
        agent_message: "",
      ),
    )
    |> result.map_error(fn(e) { failed(db.describe(e)) }),
  )
  case first {
    True -> events.announce(request_id, events.Told, domain.outcome_name(truth))
    False -> Nil
  }
}

fn follow(
  deps: Deps,
  tx: pog.Connection,
  id: String,
  known: Occurrence(Payout),
) -> Result(Nil, decisions.HandlerFailure) {
  {
    use request <- result.try(
      db.request_of(tx, id)
      |> result.map_error(fn(e) { decisions.ApplicationFailed(db.describe(e)) }),
    )
    events.announce(
      request,
      events.Settled,
      occurrence.status_name(known.status),
    )
    case known.status {
      occurrence.Released(..) ->
        submit(deps, tx, pay_worker(deps), id, request, None)
      _ -> submit(deps, tx, tell_worker(deps), id, request, None)
    }
    |> result.map_error(decisions.ApplicationFailed)
  }
}

// -- payout.pay -------------------------------------------------------------------------

fn pay(
  deps: Deps,
  conn: pog.Connection,
  id: String,
) -> worker.Response(String, String) {
  let handler = process.self()
  let found = {
    use known <- result.try(
      decisions_postgres.transaction(conn, decisions.read(
        payouts(deps),
        _,
        occurrence: id,
      ))
      |> result.map_error(decisions_postgres.describe),
    )
    use key <- result.try(case known.status {
      occurrence.Released(key:, ..) -> Ok(key)
      _ -> Error("the occurrence is not released")
    })
    db.instruction(conn, key) |> result.map_error(db.describe)
  }
  case found {
    Error(detail) -> worker.Discarded(detail)
    Ok(instruction) -> {
      let wdeps =
        workflow.Deps(
          db: conn,
          provider: deps.provider,
          sagas: deps.sagas,
          provider_timeout_ms: deps.provider_timeout_ms,
          after_paid: fn() { deps.after_paid(handler) },
        )
      case
        workflow.start(wdeps, instruction)
        |> result.try(durable.drive(_, timeout: duration.seconds(30)))
      {
        Ok(execution.Completed(receipt))
        | Ok(execution.CompletedWithUnknownEffects(receipt, _)) ->
          settle(
            deps,
            conn,
            id,
            Performed(workflow.receipt(instruction.release_key, receipt)),
          )
        Ok(execution.Failed(
          cause: execution.StepFailed(error: workflow.Declined(reason), ..),
          ..,
        )) -> settle(deps, conn, id, NotPerformed(reason))
        Ok(execution.Unresolved(evidence:, ..)) ->
          uncertain(deps, conn, id, workflow.describe_fault(evidence))
        Ok(other) -> uncertain(deps, conn, id, string.inspect(other))
        Error(error) ->
          case durable.error_kind(error) {
            // Another runner holds the execution, or it was interrupted:
            // its checkpoint is intact, so drive it again shortly.
            durable.Busy | durable.Transient ->
              worker.Snoozed(
                duration.milliseconds(300),
                durable.describe_error(error),
              )
            _ -> uncertain(deps, conn, id, durable.describe_error(error))
          }
      }
    }
  }
}

/// Report a known effect and queue the telling, in one transaction.
fn settle(
  deps: Deps,
  conn: pog.Connection,
  id: String,
  effect: Effect,
) -> worker.Response(String, String) {
  report_then(deps, conn, id, effect, tell_worker(deps), None)
}

/// Report that nobody knows yet, and queue the lookup that settles it.
fn uncertain(
  deps: Deps,
  conn: pog.Connection,
  id: String,
  reason: String,
) -> worker.Response(String, String) {
  report_then(
    deps,
    conn,
    id,
    Uncertain(reason),
    reconcile_worker(deps),
    Some(duration.milliseconds(200)),
  )
}

/// What may stop reporting an effect beside the desk's own refusal.
type ReportError {
  NoRequest(db.DbError)
  NotQueued(reason: String)
}

/// Report `effect` and queue `next` for the occurrence, in one transaction.
fn report_then(
  deps: Deps,
  conn: pog.Connection,
  id: String,
  effect: Effect,
  next: Worker(String, String, String),
  after: Option(duration.Duration),
) -> worker.Response(String, String) {
  let reported =
    decisions_postgres.transaction_with(conn, fn(tx) {
      use request <- result.try(
        db.request_of(tx, id)
        |> result.map_error(fn(e) { decisions_postgres.Own(NoRequest(e)) }),
      )
      use _ <- result.try(
        decisions.report(payouts(deps), tx, occurrence: id, effect:)
        |> decisions_postgres.desk,
      )
      use Nil <- result.try(
        submit(deps, tx, next, id, request, after)
        |> result.map_error(fn(e) { decisions_postgres.Own(NotQueued(e)) }),
      )
      Ok(request)
    })
  case reported {
    Ok(request) -> {
      events.announce(
        request,
        case effect {
          Performed(..) -> events.Paid
          NotPerformed(..) -> events.NotPaid
          Uncertain(..) -> events.Uncertain
        },
        case effect {
          Performed(receipt:) -> receipt.revision
          NotPerformed(reason:) | Uncertain(reason:) -> reason
        },
      )
      worker.Succeeded("reported")
    }
    Error(decisions_postgres.LibraryFailed(decisions_postgres.Refused(refusal))) ->
      case decisions.disposition(refusal) {
        decisions.Transient | decisions.Retry ->
          worker.Snoozed(
            duration.milliseconds(200),
            decisions.describe(refusal),
          )
        decisions.Poisoned | decisions.Final ->
          worker.Discarded(decisions.describe(refusal))
      }
    Error(decisions_postgres.LibraryFailed(failure)) ->
      worker.Snoozed(
        duration.milliseconds(200),
        decisions_postgres.describe(failure),
      )
    Error(decisions_postgres.OwnFailed(NoRequest(error))) ->
      worker.Discarded(db.describe(error))
    Error(decisions_postgres.OwnFailed(NotQueued(reason))) ->
      worker.Snoozed(duration.milliseconds(200), reason)
  }
}

// -- payout.reconcile -------------------------------------------------------------------

/// Ask the provider what happened under the release key; never pay again.
/// A payment it holds is posted; one it does not hold releases the
/// reservation, and the latest report says so.
fn reconcile(
  deps: Deps,
  conn: pog.Connection,
  id: String,
) -> worker.Response(String, String) {
  let key = {
    use known <- result.try(
      decisions_postgres.transaction(conn, decisions.read(
        payouts(deps),
        _,
        occurrence: id,
      ))
      |> result.map_error(decisions_postgres.describe),
    )
    case known.status {
      occurrence.Released(key:, ..) -> Ok(key)
      _ -> Error("the occurrence is not released")
    }
  }
  case key {
    Error(detail) -> worker.Discarded(detail)
    Ok(key) ->
      case provider.lookup(deps.provider, key) {
        provider.Found(receipt) ->
          case db.post(conn, key, receipt) {
            Ok(Nil) ->
              settle(deps, conn, id, Performed(workflow.receipt(key, receipt)))
            Error(error) ->
              worker.Snoozed(duration.milliseconds(200), db.describe(error))
          }
        provider.NotFound ->
          case db.release(conn, key) {
            Ok(Nil) ->
              settle(
                deps,
                conn,
                id,
                NotPerformed(
                  "the provider holds no payment under the release key",
                ),
              )
            Error(error) ->
              worker.Snoozed(duration.milliseconds(200), db.describe(error))
          }
      }
  }
}

// -- payout.tell ------------------------------------------------------------------------

/// Tell the seller a settled payout: the `payout.tell` job's handler. The
/// follow-on run continues the handed-over run's conversation with the
/// recorded outcome as the proposal's result. Safe to run twice: the
/// follow-on run is found by the request, and the seller is told once.
pub fn tell(
  deps: Deps,
  conn: pog.Connection,
  id: String,
) -> worker.Response(String, String) {
  let found = {
    use known <- result.try(
      decisions_postgres.transaction(conn, decisions.read(
        payouts(deps),
        _,
        occurrence: id,
      ))
      |> result.map_error(decisions_postgres.describe),
    )
    use truth <- result.try(
      domain.truth_of(known) |> option.to_result("the outcome is not known yet"),
    )
    use handed <- result.try(handed_action(known))
    use request <- result.try(
      db.request_of(conn, id) |> result.map_error(db.describe),
    )
    Ok(#(known, truth, handed, request))
  }
  case found {
    Error(detail) -> worker.Discarded(detail)
    Ok(#(known, truth, handed, request)) -> {
      let session =
        Session(
          request:,
          seller: known.subject.id,
          sources: reads.live(conn),
          settled: Some(truth),
        )
      case
        payout_agent.tell(
          deps.runs,
          deps.agent,
          session,
          handed:,
          truth:,
          within: duration.seconds(10),
        )
      {
        Ok(payout_agent.Answered(reply)) ->
          deliver(conn, known, Some(reply)) |> answered("told")
        // The follow-on run ended without an answer, or the run named by
        // the record has no handover to continue from: the application
        // tells the seller from the record alone.
        Ok(payout_agent.HandedOver(..)) | Error(payout_agent.RunStopped(_)) ->
          deliver(conn, known, None) |> answered("told without the agent")
        Error(payout_agent.StillWorking) ->
          worker.Snoozed(duration.milliseconds(300), "the run is not done")
        Error(payout_agent.RunsUnavailable(detail)) ->
          worker.Snoozed(duration.milliseconds(300), detail)
      }
    }
  }
}

/// The handed-over action an occurrence's explanation names, read back from
/// Fabric's text forms of its run id and action id.
fn handed_action(known: Occurrence(Payout)) -> Result(run.ActionRef, String) {
  case known.recommendation.explanation {
    RunAction(run: run_text, action: action_text) -> {
      use id <- result.try(
        run.parse_id(run_text)
        |> result.replace_error("not a run id: " <> run_text),
      )
      use action <- result.map(
        run.parse_action_id(action_text)
        |> result.replace_error("not an action id: " <> action_text),
      )
      run.ActionRef(run: id, id: action)
    }
    _ -> Error("the recommendation names no handed-over action")
  }
}

/// The tell job's answer once `deliver` ran: it succeeds only when the
/// seller's reply is stored. Otherwise it snoozes, and the next delivery
/// finds the follow-on run and stores the reply.
fn answered(
  delivered: Result(db.Told, Undelivered),
  done: String,
) -> worker.Response(String, String) {
  case delivered {
    Ok(_) -> worker.Succeeded(done)
    Error(NotKnownYet) ->
      worker.Snoozed(duration.milliseconds(300), "the outcome is not known yet")
    Error(Failed(detail)) ->
      worker.Snoozed(
        duration.milliseconds(300),
        "the reply was not stored: " <> detail,
      )
  }
}

/// Why a reply was not delivered.
pub type Undelivered {
  /// The record does not say what happened yet: no reply is sent on the
  /// strength of a model's claim.
  NotKnownYet
  Failed(detail: String)
}

/// Tell the seller what the record says, once per payout. The agent's
/// reply is sent when it claims exactly the record's outcome and amount;
/// otherwise the application sends its own plain message and keeps the
/// agent's for review.
pub fn deliver(
  conn: pog.Connection,
  known: Occurrence(Payout),
  reply: Option(Reply),
) -> Result(db.Told, Undelivered) {
  use truth <- result.try(
    domain.truth_of(known) |> option.to_result(NotKnownYet),
  )
  let seller = known.subject.id
  let told = case reply {
    Some(reply) ->
      case domain.is_truthful(reply, truth) {
        True ->
          db.Told(
            seller:,
            outcome: domain.outcome_name(truth),
            message: reply.message,
            from_agent: True,
            agent_message: reply.message,
          )
        False ->
          db.Told(
            seller:,
            outcome: domain.outcome_name(truth),
            message: domain.plain_message(seller, truth),
            from_agent: False,
            agent_message: reply.message,
          )
      }
    None ->
      db.Told(
        seller:,
        outcome: domain.outcome_name(truth),
        message: domain.plain_message(seller, truth),
        from_agent: False,
        agent_message: "",
      )
  }
  use first <- result.try(
    db.tell(conn, known.id, told)
    |> result.map_error(fn(e) { Failed(db.describe(e)) }),
  )
  case first {
    True -> {
      let request = db.request_of(conn, known.id) |> result.unwrap(known.id)
      events.announce(request, events.Told, told.outcome)
    }
    False -> Nil
  }
  Ok(told)
}
