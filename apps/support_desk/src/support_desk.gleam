//// `gleam run`: five support tickets through the desk, with the approver's
//// decisions scripted, then one ticket's telemetry trail.

import fabric
import fabric/run
import fabric/tool
import gleam/int
import gleam/io
import gleam/list
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
  ApproveAs(String)
  RejectBecause(String)
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
      ApproveAs("alice"),
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
  handle_ticket(app, "T-4", "Refund order A-400 please.", ApproveAs("bob"))
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
  drive(handle, session, approver)
  #(ticket, run_id)
}

fn drive(
  handle: fabric.Run(desk.Session, Resolution),
  session: desk.Session,
  approver: Approver,
) -> Nil {
  case fabric.await(handle, within: duration.seconds(10)) {
    Ok(run.Suspended([pending, ..], _)) -> {
      io.println(
        "  approval needed: " <> pending.tool <> " " <> pending.arguments_json,
      )
      let answered = case approver {
        ApproveAs(name) -> {
          io.println("  " <> name <> " approves")
          let assert Ok(reviewer) = desk.approver_named(name)
          fabric.approve(handle, pending.reference, reviewer:, context: session)
        }
        RejectBecause(reason) -> {
          io.println("  approver rejects: " <> reason)
          let assert Ok(reviewer) = desk.approver_named("carol")
          fabric.reject(handle, pending.reference, reason:, reviewer:)
        }
      }
      case answered {
        Ok(_) -> drive(handle, session, approver)
        Error(error) -> refused(error)
      }
    }
    Ok(run.Suspended([], [uncertain, ..])) -> {
      io.println("  uncertain effect, run paused: " <> uncertain.evidence)
      io.println("  operator reconciles: refund unconfirmed, finance checking")
      case fabric.reconcile(handle, uncertain.reference, unconfirmed()) {
        Ok(_) -> drive(handle, session, approver)
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
