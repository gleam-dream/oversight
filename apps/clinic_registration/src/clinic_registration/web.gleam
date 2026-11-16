//// The desk over HTTP, on Wisp and Mist, and the messaging channel's
//// webhook.
////
//// - `GET /queue` lists the registrations the validator may decide, the
////   soonest due first (`decisions_postgres/queue.page_at` for this point).
//// - `POST /cards/:occurrence/open` shows the card to the validator and
////   records the showing. It is a `POST` because it writes.
//// - `POST /cards/:occurrence/verdict` takes `{"seen": n, "verdict": v}`
////   in a later request: the ticket from the card, and a verdict in the
////   `decisions/wire` form (`{"t": "approve"}`, `{"t": "reject", "reason":
////   {...}}` or `{"t": "correct", "output": {...}, "reason": {...}}`).
//// - `GET /reviews` lists the sampled, released registrations nobody has
////   reviewed yet (`decisions_postgres/queue.review_queue`). A manager opens
////   one with `POST /cards/:occurrence/open` and reviews it with
////   `POST /cards/:occurrence/review`, the same body as a verdict. A review
////   changes nothing and counts toward agreement.
//// - `POST /cards/:occurrence/withdraw` takes back, during its undo window,
////   a registration the policy let proceed (reception may).
//// - `GET /pending` lists the messages still waiting for a recommendation
////   and since when (`decisions_postgres/queue.pending`), for an operator.
//// - `POST /inbound` is the channel's webhook for a new message. Its
////   signature is not verified: anyone who can reach the route can deliver
////   a message.
////
//// The desk routes need `x-clinic-validator: <name>; <set>,<set>`, read by
//// `authenticate` alone. This header is the stand-in for identity in this
//// example: a real application resolves the validator and the decision
//// sets they hold from its own sign-in.

import clinic_registration/desk
import clinic_registration/domain.{type Inbound, type Registration}
import clinic_registration/jobs
import clinic_registration/llm
import clinic_registration/telemetry
import decisions.{type Desk, type Refusal, Ticket}
import decisions/occurrence
import decisions/vocabulary.{
  type Validator, type Verdict, Approve, Correct, Reject,
}
import decisions/wire
import decisions_postgres
import decisions_postgres/queue
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http.{Get, Post}
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import mist
import pog
import wisp
import wisp/wisp_mist

/// What the routes need.
pub type Routes {
  Routes(
    db: pog.Connection,
    desk: Desk(Registration, pog.Connection),
    admit: fn(Inbound) -> Result(jobs.Admission, String),
  )
}

/// Start the HTTP server on a free loopback port. Call it from the process
/// that owns the server (`clinic_registration/owner`).
pub fn start(routes: Routes, secret: String) -> Result(Int, String) {
  let port = process.new_subject()
  wisp_mist.handler(handle(_, routes), secret)
  |> mist.new
  |> mist.bind("127.0.0.1")
  |> mist.port(0)
  |> mist.after_start(fn(bound, _, _) { process.send(port, bound) })
  |> mist.start
  |> result.map_error(string.inspect)
  |> result.try(fn(_) {
    process.receive(port, 2000)
    |> result.replace_error("the HTTP server did not report its port")
  })
}

pub fn handle(req: wisp.Request, routes: Routes) -> wisp.Response {
  use <- wisp.rescue_crashes
  case req.method, wisp.path_segments(req) {
    Post, ["inbound"] -> inbound(req, routes)
    method, segments -> {
      use validator <- require_validator(req)
      case method, segments {
        Get, ["queue"] -> show_queue(routes, validator)
        Post, ["cards", id, "open"] -> open(routes, validator, id)
        Post, ["cards", id, "verdict"] ->
          verdict(req, routes, validator, id, Deciding)
        Get, ["reviews"] -> show_reviews(routes)
        Post, ["cards", id, "withdraw"] -> withdraw(routes, validator, id)
        Get, ["pending"] -> show_pending(routes)
        Post, ["cards", id, "review"] ->
          verdict(req, routes, validator, id, Reviewing)
        _, _ -> wisp.not_found()
      }
    }
  }
}

/// The validator a request acts as, from `x-clinic-validator`. The one
/// place this example decides who is asking.
pub fn authenticate(header: Result(String, Nil)) -> Result(Validator, Nil) {
  use value <- result.try(header)
  let #(name, sets) = case string.split_once(value, ";") {
    Ok(#(name, sets)) -> #(name, sets)
    Error(Nil) -> #(value, "")
  }
  let holds =
    string.split(sets, ",")
    |> list.map(string.trim)
    |> list.filter(fn(set) { set != "" })
  case string.trim(name) {
    "" -> Error(Nil)
    name -> Ok(domain.validator(name, holds))
  }
}

fn require_validator(
  req: wisp.Request,
  next: fn(Validator) -> wisp.Response,
) -> wisp.Response {
  case authenticate(request.get_header(req, "x-clinic-validator")) {
    Ok(validator) -> next(validator)
    Error(Nil) ->
      error_response(
        401,
        "unauthenticated",
        "name the validator in x-clinic-validator",
      )
  }
}

fn show_queue(routes: Routes, validator: Validator) -> wisp.Response {
  case
    queue.page_at(
      routes.db,
      point: domain.point_name,
      for: validator,
      limit: 50,
      after: None,
    )
  {
    Ok(cards) ->
      json.object([
        #("validator", json.string(validator.subject)),
        #(
          "cards",
          json.array(cards, fn(card: queue.Queued) {
            json.object([
              #("occurrence", json.string(card.occurrence)),
              #("point", json.string(card.point)),
              #("due", wire.optional(card.due, wire.time)),
              #("arrived", wire.time(card.arrived)),
            ])
          }),
        ),
      ])
      |> json.to_string
      |> wisp.json_response(200)
    Error(_) ->
      error_response(503, "store_unavailable", "the queue could not be read")
  }
}

/// Take back a registration the policy let proceed, during its undo
/// window. The point lets reception do it (`withdrawn_by`).
fn withdraw(routes: Routes, validator: Validator, id: String) -> wisp.Response {
  case
    decisions_postgres.transaction(routes.db, decisions.withdraw_as(
      routes.desk,
      _,
      occurrence: id,
      by: validator,
    ))
  {
    Ok(known) ->
      json.object([
        #("occurrence", json.string(known.id)),
        #("status", json.string(occurrence.status_name(known.status))),
      ])
      |> json.to_string
      |> wisp.json_response(200)
    Error(failure) -> failure_response(failure)
  }
}

/// The messages still waiting for a recommendation, the oldest first, with
/// when each was received: their model has not answered yet, or has only
/// failed.
fn show_pending(routes: Routes) -> wisp.Response {
  case
    queue.pending(routes.db, point: domain.point_name, limit: 50, after: None)
  {
    Ok(records) ->
      json.object([
        #(
          "pending",
          json.array(records, fn(record: queue.Summary) {
            json.object([
              #("occurrence", json.string(record.occurrence)),
              #("since", wire.time(record.arrived)),
            ])
          }),
        ),
      ])
      |> json.to_string
      |> wisp.json_response(200)
    Error(_) ->
      error_response(
        503,
        "store_unavailable",
        "the pending records could not be read",
      )
  }
}

fn show_reviews(routes: Routes) -> wisp.Response {
  case queue.review_queue(routes.db, domain.point_name, limit: 50) {
    Ok(ids) ->
      json.object([#("reviews", json.array(ids, json.string))])
      |> json.to_string
      |> wisp.json_response(200)
    Error(_) ->
      error_response(503, "store_unavailable", "the reviews could not be read")
  }
}

fn open(routes: Routes, validator: Validator, id: String) -> wisp.Response {
  let opened =
    decisions_postgres.transaction(routes.db, decisions.open(
      routes.desk,
      _,
      occurrence: id,
      by: validator,
      latest: llm.latest(routes.db),
    ))
  case opened {
    Ok(card) -> desk.card_json(routes.db, card) |> wisp.json_response(200)
    Error(failure) -> failure_response(failure)
  }
}

/// Whether a verdict decides a waiting registration or reviews a sampled,
/// released one after the fact.
type Giving {
  Deciding
  Reviewing
}

fn verdict(
  req: wisp.Request,
  routes: Routes,
  validator: Validator,
  id: String,
  giving: Giving,
) -> wisp.Response {
  use body <- wisp.require_json(req)
  let decoder = {
    use seen <- decode.field("seen", decode.int)
    use verdict <- decode.field(
      "verdict",
      wire.verdict_decoder(decisions.codec(domain.point())),
    )
    decode.success(#(seen, verdict))
  }
  case decode.run(body, decoder) {
    Error(_) ->
      error_response(
        422,
        "invalid_verdict",
        "send {\"seen\": n, \"verdict\": {...}}",
      )
    Ok(#(seen, verdict)) -> {
      let ticket = Ticket(occurrence: id, seen:)
      let decided = case giving {
        Deciding ->
          decisions_postgres.decide(
            routes.db,
            routes.desk,
            decisions.resume(routes.desk, _, ticket, by: validator),
            verdict,
          )
        Reviewing ->
          decisions_postgres.transaction(routes.db, fn(tx) {
            use card <- result.try(decisions.resume(
              routes.desk,
              tx,
              ticket,
              by: validator,
            ))
            decisions.review(routes.desk, tx, card, verdict)
          })
      }
      let outcome = case decided {
        Ok(known) -> occurrence.status_name(known.status)
        Error(failure) -> "refused: " <> decisions_postgres.describe(failure)
      }
      telemetry.emit(
        telemetry.verdict_given(),
        telemetry.Verdict(
          occurrence: id,
          validator: validator.subject,
          verdict: case giving {
            Deciding -> verdict_name(verdict)
            Reviewing -> "reviewed (" <> verdict_name(verdict) <> ")"
          },
          outcome:,
        ),
      )
      case decided {
        Ok(known) ->
          json.object([
            #("occurrence", json.string(known.id)),
            #("status", json.string(occurrence.status_name(known.status))),
          ])
          |> json.to_string
          |> wisp.json_response(200)
        Error(failure) -> failure_response(failure)
      }
    }
  }
}

fn verdict_name(verdict: Verdict(Registration)) -> String {
  case verdict {
    Approve -> "approved"
    Reject(..) -> "rejected"
    Correct(..) -> "corrected"
  }
}

/// The messaging channel's webhook. This example does not verify the
/// webhook's signature, so it is not a verified webhook: a real application
/// checks the channel's signature before it admits anything.
fn inbound(req: wisp.Request, routes: Routes) -> wisp.Response {
  use body <- wisp.require_json(req)
  let decoder = {
    use id <- decode.field("id", decode.string)
    use contact <- decode.field("from", decode.string)
    use profile_name <- decode.field("profile_name", decode.string)
    use text <- decode.field("text", decode.string)
    decode.success(domain.Inbound(id:, contact:, profile_name:, text:))
  }
  case decode.run(body, decoder) {
    Error(_) ->
      error_response(
        422,
        "invalid_message",
        "send {id, from, profile_name, text}",
      )
    Ok(message) ->
      case routes.admit(message) {
        Ok(jobs.Admitted(..)) -> wisp.json_response("{\"admitted\":true}", 202)
        Ok(jobs.Duplicate) -> wisp.json_response("{\"admitted\":false}", 200)
        // Nothing was kept (contention on the contact included): a 503
        // makes the channel deliver the message again.
        Error(reason) -> {
          wisp.log_warning("inbound " <> message.id <> ": " <> reason)
          error_response(
            503,
            "try_again",
            "the message was not kept; deliver it again",
          )
        }
      }
  }
}

fn failure_response(failure: decisions_postgres.Failure) -> wisp.Response {
  case failure {
    decisions_postgres.Refused(refusal:) -> refusal_response(refusal)
    decisions_postgres.RefusedUnrecorded(refusal:, ..) ->
      refusal_response(refusal)
    decisions_postgres.Conflict(..) | decisions_postgres.Contended(..) ->
      error_response(
        409,
        "conflict",
        "someone changed this card; open it again",
      )
    decisions_postgres.Unavailable(..) ->
      error_response(503, "store_unavailable", "try again")
  }
}

/// A refusal as an HTTP answer. Each variant is decided here; the text
/// goes to the client only as `detail`.
pub fn refusal_response(refusal: Refusal) -> wisp.Response {
  let detail = decisions.describe(refusal)
  case refusal {
    decisions.UnknownOccurrence -> error_response(404, "unknown_card", detail)
    decisions.OutputChanged ->
      error_response(
        409,
        "stale_card",
        "the record was corrected after this card was shown; open it again",
      )
    decisions.AlreadyDecided(..) ->
      error_response(409, "already_decided", detail)
    decisions.NotAwaiting -> error_response(410, "not_awaiting", detail)
    decisions.SupersededBefore(..) -> error_response(410, "superseded", detail)
    decisions.NotEligible | decisions.NeverShown | decisions.NotTheDecider ->
      error_response(403, "not_yours", detail)
    decisions.VerdictNotAllowed
    | decisions.ReasonRequired
    | decisions.NoteRequired
    | decisions.InvalidFacts(..) ->
      error_response(422, "invalid_verdict", detail)
    // The gated tool could not tell (a query failed): nothing was
    // recorded, and the same verdict on the same ticket may be sent again.
    decisions.ToolUnsure(..) ->
      error_response(
        503,
        "try_again",
        "the release could not be checked; send the verdict again",
      )
    decisions.ToolRefused(reason:, ..) ->
      error_response(409, "not_registered", reason)
    decisions.NotRecommended(..)
    | decisions.NotHeld
    | decisions.NotReleased
    | decisions.NotSampled
    | decisions.NotSettled
    | decisions.NotConsulting
    | decisions.KeyTaken(..) -> error_response(409, "not_possible", detail)
    decisions.ConsultFailed(..)
    | decisions.NoPolicy(..)
    | decisions.Unpublishable(..)
    | decisions.Unreadable(..)
    | decisions.Unencodable(..)
    | decisions.StoreFailed(..) -> {
      wisp.log_warning("desk: " <> detail)
      error_response(503, "unavailable", "the desk cannot do this now")
    }
  }
}

fn error_response(status: Int, code: String, detail: String) -> wisp.Response {
  json.object([#("error", json.string(code)), #("detail", json.string(detail))])
  |> json.to_string
  |> wisp.json_response(status)
}
