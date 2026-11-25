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
//// - `POST /inbound` is the channel's webhook for a new message. Its body
////   must carry the channel's signature in `x-channel-signature`
////   (`access.sign`); any other delivery is a 401 and admits nothing.
////
//// Staff sign in through the clinic's OpenID provider:
////
//// - `GET /login` sends the browser to the provider with Hellhound's sealed
////   login cookie (`hellhound.begin_login`, `login_response`).
//// - `GET /auth/callback` completes the login (`hellhound.complete_login`).
////   A verified subject that the staff table names gets the desk session
////   cookie, which holds Hellhound's session reference, signed; any other
////   subject is signed out again and refused with 403.
//// - `POST /logout` ends the session: Hellhound removes its custody, so the
////   cookie no longer opens anything, and the cookie is expired.
////
//// Every desk route restores the session from that cookie and acts as the
//// validator the staff table names for its verified issuer and subject
//// (`access.member`); nothing in the request names the validator or the
//// decision sets. Cookie-carrying requests other than `GET` must come from
//// the desk's own origin (`wisp.csrf_known_header_protection`); the cookie
//// is also `SameSite=Lax`. With no sign-in or no channel secret
//// configured, the routes that need them refuse every request.

import clinic_registration/access.{type ChannelSecret, type Staff}
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
import gleam/bool
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http.{Get, Post}
import gleam/http/request
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import hellhound
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
    /// How staff sign in, and as whom they use the desk. `None` refuses
    /// every desk request.
    sign_in: Option(SignIn),
    /// The messaging channel's signing secret; `None` refuses the webhook.
    channel: Option(ChannelSecret),
  )
}

/// A started Hellhound client and the staff table it is checked against.
pub type SignIn {
  SignIn(client: hellhound.Client, staff: Staff)
}

/// The desk session cookie: Hellhound's session reference, signed.
pub const session_cookie = "clinic_session"

/// How long the desk session cookie lives, in seconds. Hellhound's own
/// session lifetime still applies within it.
const session_seconds = 28_800

/// Start the HTTP server on a loopback port (0 picks a free one) and
/// return the bound port. Call it from the process that owns the server
/// (`clinic_registration/owner`).
pub fn start(routes: Routes, port: Int, secret: String) -> Result(Int, String) {
  let bound = process.new_subject()
  wisp_mist.handler(handle(_, routes), secret)
  |> mist.new
  |> mist.bind("127.0.0.1")
  |> mist.port(port)
  |> mist.after_start(fn(port, _, _) { process.send(bound, port) })
  |> mist.start
  |> result.map_error(string.inspect)
  |> result.try(fn(_) {
    process.receive(bound, 2000)
    |> result.replace_error("the HTTP server did not report its port")
  })
}

pub fn handle(req: wisp.Request, routes: Routes) -> wisp.Response {
  use <- wisp.rescue_crashes
  case req.method, wisp.path_segments(req) {
    // The channel signs its deliveries and sends no cookie.
    Post, ["inbound"] -> inbound(req, routes)
    _, _ -> {
      use req <- wisp.csrf_known_header_protection(req)
      staff_routes(req, routes)
    }
  }
}

fn staff_routes(req: wisp.Request, routes: Routes) -> wisp.Response {
  case req.method, wisp.path_segments(req) {
    Get, ["login"] -> login(routes)
    Get, ["auth", "callback"] -> callback(req, routes)
    Post, ["logout"] -> logout(req, routes)
    method, segments -> {
      use validator <- require_validator(req, routes)
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

// -- Sign-in -------------------------------------------------------------------

/// Send the browser to the provider. The pending login travels in
/// Hellhound's sealed cookie; the server keeps nothing.
fn login(routes: Routes) -> wisp.Response {
  use sign_in <- require_sign_in(routes)
  case hellhound.begin_login(sign_in.client, hellhound.default_login()) {
    Ok(redirect) -> hellhound.login_response(wisp.response(303), redirect)
    Error(error) -> login_failure(error)
  }
}

/// Complete the login. Whatever the outcome, the answer expires this
/// login's cookie (`hellhound.callback_response`).
fn callback(req: wisp.Request, routes: Routes) -> wisp.Response {
  use sign_in <- require_sign_in(routes)
  let callback = request.set_body(req, "")
  let completed = case hellhound.complete_login(sign_in.client, callback) {
    Error(hellhound.CustodyUnconfirmed(recovery)) ->
      hellhound.recover_custody(sign_in.client, recovery)
    completed -> completed
  }
  case completed {
    Error(error) -> login_failure(error)
    Ok(session) ->
      case access.member(sign_in.staff, hellhound.session_identity(session)) {
        Ok(_) ->
          wisp.redirect("/queue")
          |> wisp.set_cookie(
            req,
            session_cookie,
            hellhound.session_reference(session),
            wisp.Signed,
            session_seconds,
          )
        // A verified person who is not staff keeps no session here.
        Error(Nil) -> {
          let _ =
            hellhound.logout(
              sign_in.client,
              session,
              hellhound.default_logout(),
            )
          error_response(403, "not_staff", "this sign-in is not clinic staff")
        }
      }
  }
  |> hellhound.callback_response(sign_in.client, callback)
}

fn login_failure(error: hellhound.LoginError) -> wisp.Response {
  let detail = hellhound.describe_login_error(error)
  case hellhound.login_error_action(error) {
    hellhound.RejectRequest -> error_response(400, "bad_callback", detail)
    hellhound.Reauthenticate ->
      error_response(401, "sign_in_again", "start again at /login")
    hellhound.RetryLater | hellhound.Recover | hellhound.FixConfiguration -> {
      wisp.log_warning("sign-in: " <> detail)
      error_response(503, "sign_in_unavailable", "sign-in is unavailable")
    }
  }
}

/// End the session: Hellhound removes its custody and revokes the refresh
/// token, and the cookie is expired. Signing out without a session, or
/// with one that already ended, is signed out too.
fn logout(req: wisp.Request, routes: Routes) -> wisp.Response {
  use sign_in <- require_sign_in(routes)
  let signed_out =
    wisp.response(204)
    |> wisp.set_cookie(req, session_cookie, "", wisp.Signed, 0)
  case staff_session(req, sign_in) {
    Error(_) -> signed_out
    Ok(#(session, _)) ->
      case
        hellhound.logout(sign_in.client, session, hellhound.default_logout())
      {
        Ok(_) | Error(hellhound.LogoutSession(_)) -> signed_out
        Error(error) -> {
          wisp.log_warning(
            "sign-out: " <> hellhound.describe_logout_error(error),
          )
          error_response(503, "unavailable", "the session may still be open")
        }
      }
  }
}

fn require_sign_in(
  routes: Routes,
  next: fn(SignIn) -> wisp.Response,
) -> wisp.Response {
  case routes.sign_in {
    Some(sign_in) -> next(sign_in)
    None -> error_response(503, "sign_in_unconfigured", "no sign-in is set up")
  }
}

/// Every desk route acts as one validator: the one the staff table names
/// for the verified subject of the session in the desk cookie, resolved
/// before the body is read.
fn require_validator(
  req: wisp.Request,
  routes: Routes,
  next: fn(Validator) -> wisp.Response,
) -> wisp.Response {
  case routes.sign_in {
    None -> unauthenticated()
    Some(sign_in) ->
      case staff_session(req, sign_in) {
        Ok(#(_, validator)) -> next(validator)
        Error(response) -> response
      }
  }
}

/// The session in the desk cookie and the validator it acts as.
///
/// The validator comes from the application's staff table, keyed by the
/// verified issuer and subject, which do not change during a session; the
/// provider's other claims are not read, so their age does not matter
/// here (`hellhound.current_identity` is for permissions read from claims).
fn staff_session(
  req: wisp.Request,
  sign_in: SignIn,
) -> Result(#(hellhound.Session, Validator), wisp.Response) {
  use reference <- result.try(
    wisp.get_cookie(req, session_cookie, wisp.Signed)
    |> result.replace_error(unauthenticated()),
  )
  use session <- result.try(
    hellhound.restore_session(sign_in.client, reference)
    |> result.map_error(session_failure),
  )
  use validator <- result.try(
    access.member(sign_in.staff, hellhound.session_identity(session))
    |> result.replace_error(error_response(
      403,
      "not_staff",
      "this sign-in is not clinic staff",
    )),
  )
  Ok(#(session, validator))
}

fn session_failure(error: hellhound.SessionError) -> wisp.Response {
  case hellhound.session_error_action(error) {
    hellhound.Reauthenticate -> unauthenticated()
    hellhound.RejectRequest ->
      error_response(400, "bad_session", "the session cannot be used")
    hellhound.RetryLater | hellhound.Recover | hellhound.FixConfiguration -> {
      wisp.log_warning("session: " <> hellhound.describe_session_error(error))
      error_response(503, "unavailable", "the session cannot be read now")
    }
  }
}

fn unauthenticated() -> wisp.Response {
  error_response(401, "unauthenticated", "sign in at /login")
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

/// The messaging channel's webhook. The signature is checked over the
/// exact bytes received, before they are parsed.
fn inbound(req: wisp.Request, routes: Routes) -> wisp.Response {
  use <- wisp.require_content_type(req, "application/json")
  use body <- wisp.require_bit_array_body(req)
  let signature = request.get_header(req, access.signature_header)
  use <- bool.guard(
    !access.verified(routes.channel, signature, body),
    error_response(401, "unsigned", "the channel's signature did not verify"),
  )
  let decoder = {
    use id <- decode.field("id", decode.string)
    use contact <- decode.field("from", decode.string)
    use profile_name <- decode.field("profile_name", decode.string)
    use text <- decode.field("text", decode.string)
    decode.success(domain.Inbound(id:, contact:, profile_name:, text:))
  }
  case json.parse_bits(body, decoder) {
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
    decisions.DeadlinePassedBefore(..) ->
      error_response(410, "deadline_passed", detail)
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
