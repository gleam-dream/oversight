//// `gleam run`: five support tickets through the desk, with the approver's
//// decisions scripted, then one ticket's telemetry trail.

import fabric
import fabric/run
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{Some}
import gleam/string
import support_desk/app.{type App}
import support_desk/desk
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
    "\ntelemetry trail for " <> ticket <> " (fabric run " <> run_id <> "):",
  )
  telemetry.trail(app.telemetry, ticket, run_id)
  |> list.each(fn(o) { io.println("  " <> telemetry.render(o)) })
  let all = telemetry.observations(app.telemetry)
  io.println(
    "not attributable to any ticket: "
    <> int.to_string(telemetry.count(all, telemetry.Saga))
    <> " saga events, "
    <> int.to_string(telemetry.count(all, telemetry.LlmWire))
    <> " llm_wire events, and every uncorrelated http_gun event",
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
) -> #(String, String) {
  io.println("\n" <> ticket <> ": " <> message)
  let session = desk.session(app.desk, ticket, 0)
  telemetry.register(app.telemetry, session.correlation, ticket)
  let assert Ok(handle) = desk.open_ticket(app.desk, session, message)
  let run_id = run.id_to_string(fabric.id(handle))
  drive(handle, session, approver)
  #(ticket, run_id)
}

fn drive(
  handle: fabric.Run(desk.Session),
  session: desk.Session,
  approver: Approver,
) -> Nil {
  case fabric.await(handle, 10_000) {
    Ok(run.Suspended([pending, ..], _)) -> {
      io.println(
        "  approval needed: " <> pending.tool <> " " <> pending.arguments_json,
      )
      let _ = case approver {
        ApproveAs(name) -> {
          io.println("  " <> name <> " approves")
          fabric.approve(
            handle,
            pending.reference,
            reviewer: Some(name),
            context: session,
          )
        }
        RejectBecause(reason) -> {
          io.println("  approver rejects: " <> reason)
          fabric.reject(
            handle,
            pending.reference,
            reason:,
            reviewer: Some("carol"),
          )
        }
      }
      drive(handle, session, approver)
    }
    Ok(run.Suspended([], [uncertain, ..])) -> {
      io.println("  uncertain effect, run paused: " <> uncertain.evidence)
      io.println("  operator reconciles: refund unconfirmed, finance checking")
      let _ = fabric.reconcile(handle, uncertain.reference, unconfirmed)
      drive(handle, session, approver)
    }
    Ok(run.Finished(outcome)) ->
      case desk.answer(outcome) {
        desk.Resolved(resolution) ->
          io.println("  resolved: " <> desk.describe(resolution))
        desk.Untyped(text, problem) ->
          io.println("  untyped answer (" <> problem <> "): " <> text)
        desk.Ended(other) -> io.println("  ended: " <> string.inspect(other))
      }
    other -> io.println("  stuck: " <> string.inspect(other))
  }
}

/// What an operator tells the model about a refund whose outcome the
/// payment provider never confirmed.
pub const unconfirmed = "{\"status\":\"unconfirmed\",\"note\":\"finance is checking with the payment provider\"}"
