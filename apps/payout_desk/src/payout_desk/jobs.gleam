//// The durable work around a payout, as Grind jobs, and the follower of the
//// payout point's settlements.
////
//// Who owns what:
////
//// - **Grind** owns delivery: each job, its lease, its retries. A job whose
////   handler died is replayed after its lease expires
////   (`ReplayAfterLeaseExpiry`), because every handler here converges on
////   what is already recorded.
//// - **Fabric** owns the agent's conversation (`fabric_postgres`): a parked
////   run waits there, with no process, for as long as people take.
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
//// | `payout.agent` | request id | Drives the agent's run until it parks on `propose_payout`, and admits the call at the `payout` point |
//// | `payout.pay` | occurrence id | Runs the payout workflow for a released occurrence and reports the effect |
//// | `payout.reconcile` | occurrence id | Settles an uncertain payout by asking the provider |
//// | `payout.tell` | occurrence id | Resumes the run with what really happened, and tells the seller what the record says |

import decisions.{type Desk}
import decisions/model as decisions_model
import decisions/occurrence.{type Occurrence}
import decisions/vocabulary.{
  type Effect, Manifest, NotPerformed, ParentRun, Performed, RunAction, Subject,
  Trigger, Uncertain,
}
import decisions_postgres
import fabric
import fabric/agent.{type Agent}
import fabric/approvers.{type Approvers}
import fabric/reviewer
import fabric/run
import fabric/store.{type Store}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import grind
import grind/job
import grind/worker.{type Worker}
import json/blueprint/codec
import payout_desk/agent.{type Session, Session} as payout_agent
import payout_desk/db
import payout_desk/desks.{type Desks}
import payout_desk/domain.{type Payout, type Reply, type Truth}
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
    approvers: Approvers(String),
    desks: Desks,
    provider: Provider,
    sagas: Storage,
    provider_timeout_ms: Int,
    /// A fault point after the provider answered a payment, given the pay
    /// job's handler process; `fn(_) { Nil }` otherwise.
    after_paid: fn(process.Pid) -> Nil,
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

/// Record a request and queue its agent, in one transaction. A request id
/// over `max_request_id_bytes` is refused, so the keys built from it stay
/// within the store's bounds.
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
  db.transaction(db, fn(tx) {
    use Nil <- result.try(db.put_request(tx, request, requested_by))
    submit(deps, tx, agent_worker(deps), request.id, request.id, None)
    |> result.map_error(db.Query)
  })
  |> result.map_error(db.describe)
}

// -- payout.agent -------------------------------------------------------------------

/// Drive a request's agent and admit its gated call: the `payout.agent`
/// job's handler. Safe to run twice, at once or in turn: the run is found
/// by the request, and the call by its key.
pub fn propose(
  deps: Deps,
  conn: pog.Connection,
  request_id: String,
) -> worker.Response(String, String) {
  case db.request(conn, request_id) {
    Error(error) -> worker.Discarded(db.describe(error))
    Ok(#(request, requested_by)) -> {
      let session =
        Session(
          request: request.id,
          seller: request.seller,
          sources: reads.live(conn),
          settled: None,
        )
      let id = payout_agent.run_id(request.id)
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
        Ok(payout_agent.Waiting(call:, actions:)) ->
          admit(deps, conn, request, requested_by, call, actions)
        Error(payout_agent.StillWorking) ->
          worker.Snoozed(duration.milliseconds(200), "the run is working")
        Error(payout_agent.RunsUnavailable(detail)) ->
          worker.Snoozed(duration.milliseconds(200), detail)
        Error(payout_agent.RunStopped(detail)) -> {
          // The record keeps the failed attempt, under the run's key.
          let _ =
            decisions_postgres.transaction(conn, decisions.record_failure(
              payouts(deps),
              _,
              key: "payout:" <> run.id_to_string(id),
              trigger: Trigger("request", request.id),
              about: Subject("seller", request.seller),
              failure: decisions_model.Declined(detail),
            ))
          worker.Failed(detail)
        }
      }
    }
  }
}

/// The occurrence's key: the gated call's run and action. A redelivered or
/// replayed tool call admits nothing twice.
///
/// The store refuses an occurrence id over 255 bytes, and the release key
/// adds `release:` to it. The run is bounded (a request id is at most 64
/// bytes, `request`), but the call id inside the action is the model's, so
/// a key that would pass 200 bytes is replaced by the SHA-256 digest of the
/// same run and action: 71 bytes, still one key per call. The
/// recommendation's explanation keeps the run and action readable.
pub fn call_key(call: payout_agent.Parked) -> String {
  let readable = "payout:" <> call.run <> "/" <> call.action
  case string.byte_size(readable) <= 200 {
    True -> readable
    False -> "payout:" <> decisions_model.digest(call.run <> "/" <> call.action)
  }
}

/// The longest request id `request` accepts, in bytes.
pub const max_request_id_bytes = 64

fn admit(
  deps: Deps,
  conn: pog.Connection,
  request: domain.Request,
  requested_by: String,
  call: payout_agent.Parked,
  actions: List(run.ActionRecord),
) -> worker.Response(String, String) {
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
          trigger: Trigger("tool_call", call.run <> "/" <> call.action),
          about: Subject("seller", request.seller),
          context:,
          recommending: recommendation,
        )
        |> decisions.asked_by(requested_by)
        |> decisions.hanging_from(ParentRun(call.run))
      let admitted =
        decisions_postgres.transaction_with(conn, fn(tx) {
          use known <- result.try(
            decisions.recommend_once(
              payouts(deps),
              tx,
              key: call_key(call),
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
    use known <- result.try(
      decisions.read(payouts(deps), tx, occurrence: id)
      |> result.map_error(decisions.DeskRefused),
    )
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
  })
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

/// The decision point as Fabric's approver: the credential is a payout
/// occurrence's id, and it answers only for an occurrence whose outcome is
/// known on the record. The reviewer Fabric records is whoever decided it
/// (`occurrence.decided_by`), or `decisions:expired` when nobody did.
pub fn approvers(
  db: pog.Connection,
  desk: fn() -> Desk(Payout, pog.Connection),
) -> Approvers(String) {
  approvers.new(
    "decisions",
    fn(occurrence_id: String, requirement: run.Requirement) {
      case requirement == payout_agent.requirement {
        False -> Error(approvers.NotAuthorized("only payouts are decided here"))
        True ->
          case
            decisions_postgres.transaction(db, decisions.read(
              desk(),
              _,
              occurrence: occurrence_id,
            ))
          {
            Error(failure) ->
              Error(approvers.Unavailable(decisions_postgres.describe(failure)))
            Ok(known) ->
              case domain.truth_of(known) {
                None ->
                  Error(approvers.NotAuthorized("the payout is not settled"))
                Some(_) ->
                  reviewer.new(case occurrence.decided_by(known) {
                    Some(occurrence.APerson(subject:)) -> subject
                    Some(occurrence.ThePolicy(version:)) ->
                      "policy:" <> int.to_string(version)
                    // Nobody decided an expired payout: its validity ended.
                    None -> "decisions:" <> occurrence.status_name(known.status)
                  })
                  |> result.map_error(fn(e) {
                    approvers.NotAuthenticated(reviewer.describe_error(e))
                  })
              }
          }
      }
    },
  )
}

fn tell(
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
    use #(run_text, action) <- result.try(
      case known.recommendation.explanation {
        RunAction(run:, action:) -> Ok(#(run, action))
        _ -> Error("the recommendation names no run")
      },
    )
    use run_id <- result.try(
      run.parse_id(run_text)
      |> result.replace_error("not a run id: " <> run_text),
    )
    use request <- result.try(
      db.request_of(conn, id) |> result.map_error(db.describe),
    )
    Ok(#(known, truth, run_id, action, request))
  }
  case found {
    Error(detail) -> worker.Discarded(detail)
    Ok(#(known, truth, run_id, action, request)) -> {
      let session =
        Session(
          request:,
          seller: known.subject.id,
          sources: reads.live(conn),
          settled: Some(truth),
        )
      case resume(deps, session, known.id, run_id, action, truth) {
        Error(detail) -> worker.Snoozed(duration.milliseconds(300), detail)
        Ok(handle) ->
          case payout_agent.settle(handle, duration.seconds(10)) {
            Ok(payout_agent.Answered(reply)) -> {
              let _ = deliver(conn, known, Some(reply))
              worker.Succeeded("told")
            }
            Error(payout_agent.RunStopped(_)) -> {
              let _ = deliver(conn, known, None)
              worker.Succeeded("told without the agent")
            }
            Ok(payout_agent.Waiting(..)) | Error(_) ->
              worker.Snoozed(duration.milliseconds(300), "the run is not done")
          }
      }
    }
  }
}

/// Answer the run's pending approval of the gated call with the outcome:
/// let it through when the payout was released, reject it otherwise. An
/// approval already answered (a redelivered job) or expired (the trap)
/// leaves the run as it is.
fn resume(
  deps: Deps,
  session: Session,
  occurrence_id: String,
  run_id: run.RunId,
  action: String,
  truth: Truth,
) -> Result(fabric.Run(Session, Reply), String) {
  use handle <- result.try(
    fabric.open(deps.runs, deps.agent, session, run_id)
    |> result.map_error(fabric.describe_error),
  )
  use pending <- result.try(
    fabric.pending(handle) |> result.map_error(fabric.describe_error),
  )
  let mine =
    list.find(pending, fn(p) {
      string.inspect(p.reference.id.turn) <> "." <> p.reference.id.call_id
      == action
    })
  case mine {
    Error(Nil) -> Ok(handle)
    Ok(p) -> {
      use proof <- result.try(
        approvers.check(deps.approvers, occurrence_id, p.reference.requirement)
        |> result.map_error(approvers.describe_denial),
      )
      let answered = case domain.lets_call_through(truth) {
        True -> fabric.approve(handle, p.reference, proof:, context: session)
        False ->
          fabric.reject(
            handle,
            p.reference,
            proof:,
            reason: codec.encode_json(domain.truth_codec(), truth)
              |> result.unwrap(domain.outcome_name(truth)),
          )
      }
      case answered {
        Ok(_) | Error(fabric.AlreadyAnswered) | Error(fabric.ApprovalExpired) ->
          Ok(handle)
        Error(error) -> Error(fabric.describe_error(error))
      }
    }
  }
}

/// Why a reply was not delivered.
pub type Undelivered {
  /// The record does not say what happened yet: no reply is sent on the
  /// strength of an approval, an expired request or a model's claim.
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
