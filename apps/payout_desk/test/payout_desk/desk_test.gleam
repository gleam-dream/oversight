//// The desk over MCP: who may call it, who may decide, and what a
//// verdict that cannot be given answers.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import payout_desk/desk_tools.{OpenRequest, QueueRequest, VerdictRequest}
import relay/client as mcp
import relay/content
import support

pub fn a_call_without_a_valid_token_is_refused_test() {
  use running <- support.with_app("mcp_auth", fn(s) { s })
  let refused = fn(token) {
    let client = support.connect(running, token)
    let assert Error(error) =
      mcp.call(client, desk_tools.queue_definition(), QueueRequest(10))
    let assert mcp.HttpStatus(status: 401, ..) = mcp.reason(error)
    Nil
  }
  refused(None)
  refused(Some("forged"))
}

pub fn only_finance_may_decide_and_a_correction_needs_an_amount_test() {
  use running <- support.with_app("mcp_sets", fn(s) { s })
  let id = support.ask(running, "r-mcp", "O-5001", "partial", 8000)
  // Sam signs in, but holds no finance set: nothing to decide.
  let sam = support.desk(running, "sam")
  let assert Ok(mcp.Succeeded(queue, _)) =
    mcp.call(sam, desk_tools.queue_definition(), QueueRequest(10))
  assert queue.payouts == []
  let assert Ok(mcp.ToolFailed(content, _)) =
    mcp.call(sam, desk_tools.open_definition(), OpenRequest(id))
  assert text(content) == "this validator may not decide this occurrence"
  // Fiona holds finance, and asked: she gets no card she could not decide.
  let fiona = support.desk(running, "fiona")
  let assert Ok(mcp.ToolFailed(content, _)) =
    mcp.call(fiona, desk_tools.open_definition(), OpenRequest(id))
  assert text(content) == "this validator may not decide this occurrence"
  let bia = support.desk(running, "bia")
  let assert Ok(mcp.Succeeded(card, _)) =
    mcp.call(bia, desk_tools.open_definition(), OpenRequest(id))
  let assert Ok(mcp.ToolFailed(content, _)) =
    mcp.call(
      bia,
      desk_tools.decide_definition(),
      VerdictRequest(id, card.seen, "correct", None, Some("fee"), None),
    )
  assert text(content) == "a correction needs amount_cents"
  // A ticket Bia was never shown is refused.
  let assert Ok(mcp.ToolFailed(content, _)) =
    mcp.call(
      bia,
      desk_tools.decide_definition(),
      VerdictRequest(id, card.seen - 1, "approve", None, None, None),
    )
  assert text(content) == "this card was never shown to this validator"
}

fn text(blocks: List(content.ContentBlock)) -> String {
  list.filter_map(blocks, fn(block) {
    case block {
      content.TextContent(text:, ..) -> Ok(text)
      _ -> Error(Nil)
    }
  })
  |> string.join(" ")
}
