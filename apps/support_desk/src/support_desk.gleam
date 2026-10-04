//// `gleam run`: five support tickets through the desk. Each approver signs
//// in through a scripted OIDC provider, and their decisions are scripted.
//// Then one ticket's telemetry trail.

import fabric
import fabric/reviewer.{type Reviewer}
import fabric/run
import fabric/tool
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleam/time/duration
import sinal/correlation.{type Correlation}
import support_desk/app.{type App}
import support_desk/desk
import support_desk/domain.{type Resolution}
import support_desk/ledger
import support_desk/services
import support_desk/telemetry

/// What the human approver does with a pending refund.
pub type Approver {
  /// Signs in as this subject, then approves.
  ApproveAs(String)
  /// Signs in as "carol", then rejects.
  RejectBecause(String)
  /// Tries to answer with no credential first (refused), then does this.
  AnonymousFirst(Approver)
  /// Signs in as this subject, who lacks the approver scope, and tries to
  /// approve (refused), then does the next.
  UnscopedFirst(String, Approver)
}

pub fn main() -> Nil {
  let assert Ok(app) = app.start()
  io.println(
    "support_desk: an agent with typed tools, an approval gate and a refund saga",
  )
  let #(ticket, run_id) =
    handle_ticket(
      app,
      "T-1",
      "Please refund order A-100, it arrived broken.",
      AnonymousFirst(ApproveAs("alice")),
    )
  handle_ticket(
    app,
    "T-2",
    "Refund A-200 please, I changed my mind.",
    RejectBecause("over the desk's goodwill limit"),
  )
  handle_ticket(
    app,
    "T-3",
    "Order A-300 never worked, refund it.",
    ApproveAs("alice"),
  )
  handle_ticket(
    app,
    "T-4",
    "Refund order A-400 please.",
    UnscopedFirst("mallory", ApproveAs("bob")),
  )
  handle_ticket(
    app,
    "T-5",
    "I want my money back for A-500.",
    ApproveAs("alice"),
  )
  io.println("\nledger:")
  list.each(ledger.entries(app.ledger), fn(entry) {
    io.println(
      "  #"
      <> int.to_string(entry.id)
      <> " "
      <> entry.order_id
      <> " "
      <> entry.refund_id
      <> " "
      <> int.to_string(entry.amount_cents)
      <> " cents",
    )
  })
  io.println(
    "\nshop API calls: " <> string.join(services.calls(app.services), ", "),
  )
  io.println(
    "\ntelemetry trail for "
    <> correlation.to_string(ticket)
    <> " (fabric run "
    <> run_id
    <> "):",
  )
  telemetry.trail(app.telemetry, ticket)
  |> list.each(fn(o) { io.println("  " <> telemetry.render(o)) })
  let all = telemetry.observations(app.telemetry)
  let orphans = telemetry.unattributed(all)
  io.println(
    "not attributable to any ticket: "
    <> int.to_string(list.length(orphans))
    <> " of "
    <> int.to_string(list.length(all))
    <> " events",
  )
  app.stop(app)
}

/// Opens a ticket, answers its approvals, reconciles an uncertain refund
/// as an operator would, and prints how it ended.
pub fn handle_ticket(
  app: App,
  ticket: String,
  message: String,
  approver: Approver,
) -> #(Correlation, String) {
  io.println("\n" <> ticket <> ": " <> message)
  let assert Ok(ticket) = correlation.from_string(ticket)
  let session = desk.session(ticket, 0)
  let assert Ok(desk.Opened(run: handle, message: applied)) =
    desk.open_ticket(app.desk, session, message)
  case applied {
    desk.NotApplied ->
      io.println("  this ticket already has a run; the message was not applied")
    _ -> Nil
  }
  let run_id = run.id_to_string(fabric.id(handle))
  drive(app, handle, session, approver)
  #(ticket, run_id)
}

fn drive(
  app: App,
  handle: fabric.Run(desk.Session, Resolution),
  session: desk.Session,
  approver: Approver,
) -> Nil {
  case fabric.await(handle, within: duration.seconds(10)) {
    Ok(run.Suspended([pending, ..], _)) -> {
      io.println(
        "  approval needed: " <> pending.tool <> " " <> pending.arguments_json,
      )
      let answered = answer(app, handle, pending, session, approver)
      case answered {
        Ok(_) -> drive(app, handle, session, approver)
        Error(desk.Refused(error)) -> refused(error)
        Error(error) -> {
          io.println(
            "  refused, still pending: " <> desk.describe_answer_error(error),
          )
          drive(app, handle, session, retry(approver))
        }
      }
    }
    Ok(run.Suspended([], [uncertain, ..])) -> {
      io.println("  uncertain effect, run paused: " <> uncertain.evidence)
      io.println("  operator reconciles: refund unconfirmed, finance checking")
      case fabric.reconcile(handle, uncertain.reference, unconfirmed()) {
        Ok(_) -> drive(app, handle, session, approver)
        Error(error) -> refused(error)
      }
    }
    Ok(run.Finished(outcome)) -> {
      desk.close(session, handle, outcome)
      case outcome {
        run.Completed(resolution) ->
          io.println("  resolved: " <> desk.describe(resolution))
        run.AnswerInvalid(raw:, reason:) ->
          io.println("  invalid answer (" <> reason <> "): " <> raw)
        other -> io.println("  ended: " <> run.describe_outcome(other))
      }
    }
    Ok(other) -> io.println("  stuck: " <> string.inspect(other))
    Error(error) -> refused(error)
  }
}

/// One approver's attempt at the pending approval.
fn answer(
  app: App,
  handle: fabric.Run(desk.Session, Resolution),
  pending: run.PendingApproval,
  session: desk.Session,
  approver: Approver,
) -> Result(Reviewer, desk.AnswerError) {
  case approver {
    AnonymousFirst(_) -> {
      io.println("  someone with no sign-in tries to approve")
      desk.approve(app.desk, handle, pending, app.anonymous, session)
    }
    UnscopedFirst(subject, _) -> {
      io.println("  " <> subject <> " signs in and tries to approve")
      let assert Ok(credential) = app.sign_in(app, subject)
      desk.approve(app.desk, handle, pending, credential, session)
    }
    ApproveAs(subject) -> {
      let assert Ok(credential) = app.sign_in(app, subject)
      use reviewer <- result.map(desk.approve(
        app.desk,
        handle,
        pending,
        credential,
        session,
      ))
      io.println("  approved by " <> who(reviewer))
      reviewer
    }
    RejectBecause(reason) -> {
      let assert Ok(credential) = app.sign_in(app, "carol")
      use reviewer <- result.map(desk.reject(
        app.desk,
        handle,
        pending,
        credential,
        reason,
      ))
      io.println("  rejected by " <> who(reviewer) <> ": " <> reason)
      reviewer
    }
  }
}

/// The attempt that follows a refused one.
fn retry(approver: Approver) -> Approver {
  case approver {
    AnonymousFirst(next) -> next
    UnscopedFirst(_, next) -> next
    other -> other
  }
}

fn who(person: Reviewer) -> String {
  reviewer.subject(person)
  <> " (issuer "
  <> option.unwrap(reviewer.issuer(person), "none")
  <> ")"
}

/// A command Fabric refused: retry what may succeed later, report the rest.
fn refused(error: fabric.Error) -> Nil {
  let advice = case fabric.error_kind(error) {
    fabric.Retry | fabric.Unavailable -> "try again"
    _ -> "do not retry"
  }
  io.println("  refused (" <> advice <> "): " <> fabric.describe_error(error))
}

/// What an operator tells the model about a refund whose outcome the
/// payment provider never confirmed.
pub fn unconfirmed() -> String {
  tool.unconfirmed_reconciliation(
    "finance is checking with the payment provider",
  )
}
