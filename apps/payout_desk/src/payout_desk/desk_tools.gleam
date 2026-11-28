//// The payout desk served as MCP tools through Relay, so finance decides
//// from its own assistant. The tools are typed for the `payout` point:
////
//// - `payout_queue`: the payouts the caller may decide now.
//// - `open_payout`: the card, recorded as shown to the caller: the payout
////   the agent proposed and the one that stands, and the same context the
////   model had (the request and every read it received, each as it was
////   read and flagged when it changed since). The document is
////   `decisions/view`'s, served with its own codec.
//// - `decide_payout`: approve, reject or correct, on the card's ticket.
////
//// The caller is the person the bearer token names (`auth`); the decision
//// sets they hold are the application's (`db.validator`).

import decisions.{type Desk, Ticket}
import decisions/occurrence.{type Occurrence}
import decisions/policy
import decisions/view.{type View}
import decisions/vocabulary.{type Validator, Approve, Correct, Reason, Reject}
import decisions_postgres
import decisions_postgres/queue
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import json/blueprint/codec.{type Codec}
import payout_desk/auth.{type Principal}
import payout_desk/db
import payout_desk/domain.{type Payout, Payout}
import payout_desk/reads
import pog
import relay/tool

pub type Deps {
  Deps(
    db: pog.Connection,
    /// The pool the decision record's transactions start on.
    pool: decisions_postgres.Pool,
    desk: fn() -> Desk(Payout, decisions_postgres.Tx),
  )
}

// -- The queue ------------------------------------------------------------------------

pub type QueueRequest {
  QueueRequest(limit: Int)
}

fn queue_request_codec() -> Codec(QueueRequest) {
  use limit <- codec.field("limit", codec.int(), get: fn(q: QueueRequest) {
    q.limit
  })
  codec.success(QueueRequest(limit:))
}

pub type Queued {
  Queued(
    occurrence: String,
    seller: String,
    order: String,
    amount_cents: Int,
    waiting_for: List(String),
    approvals_have: Int,
    approvals_need: Int,
  )
}

fn queued_codec() -> Codec(Queued) {
  use occurrence <- codec.field(
    "occurrence",
    codec.string(),
    get: fn(q: Queued) { q.occurrence },
  )
  use seller <- codec.field("seller", codec.string(), get: fn(q: Queued) {
    q.seller
  })
  use order <- codec.field("order", codec.string(), get: fn(q: Queued) {
    q.order
  })
  use amount_cents <- codec.field(
    "amount_cents",
    codec.int(),
    get: fn(q: Queued) { q.amount_cents },
  )
  use waiting_for <- codec.field(
    "waiting_for",
    codec.list(codec.string()),
    get: fn(q: Queued) { q.waiting_for },
  )
  use approvals_have <- codec.field(
    "approvals_have",
    codec.int(),
    get: fn(q: Queued) { q.approvals_have },
  )
  use approvals_need <- codec.field(
    "approvals_need",
    codec.int(),
    get: fn(q: Queued) { q.approvals_need },
  )
  codec.success(Queued(
    occurrence:,
    seller:,
    order:,
    amount_cents:,
    waiting_for:,
    approvals_have:,
    approvals_need:,
  ))
}

pub type QueueReply {
  QueueReply(payouts: List(Queued))
}

fn queue_reply_codec() -> Codec(QueueReply) {
  use payouts <- codec.field(
    "payouts",
    codec.list(queued_codec()),
    get: fn(q: QueueReply) { q.payouts },
  )
  codec.success(QueueReply(payouts:))
}

pub fn queue_definition() -> tool.Definition(QueueRequest, QueueReply) {
  tool.define("payout_queue", queue_request_codec(), queue_reply_codec())
  |> tool.with_description("The payouts you may decide now, soonest due first.")
  |> tool.with_read_only_hint(True)
}

// -- The card -------------------------------------------------------------------------

pub type OpenRequest {
  OpenRequest(occurrence: String)
}

fn open_request_codec() -> Codec(OpenRequest) {
  use occurrence <- codec.field(
    "occurrence",
    codec.string(),
    get: fn(o: OpenRequest) { o.occurrence },
  )
  codec.success(OpenRequest(occurrence:))
}

/// The card document: `decisions/view`'s own codec for the payout's
/// output, so its JSON Schema is the one a client reads, and the client
/// decodes it with the same definition.
pub fn open_definition() -> tool.Definition(OpenRequest, View(Payout)) {
  tool.define(
    "open_payout",
    open_request_codec(),
    view.codec(domain.payout_record_codec()),
  )
  |> tool.with_description(
    "Open a payout's card: what the agent proposed, the payout that stands, and everything the model read, as it read it. Opening is recorded.",
  )
}

// -- The verdict ------------------------------------------------------------------------

pub type VerdictRequest {
  VerdictRequest(
    occurrence: String,
    seen: Int,
    /// `approve`, `reject` or `correct`.
    verdict: String,
    /// The corrected amount, for `correct`.
    amount_cents: Option(Int),
    /// The reason category, for `reject` and `correct`.
    reason: Option(String),
    note: Option(String),
  )
}

fn verdict_request_codec() -> Codec(VerdictRequest) {
  use occurrence <- codec.field(
    "occurrence",
    codec.string(),
    get: fn(v: VerdictRequest) { v.occurrence },
  )
  use seen <- codec.field("seen", codec.int(), get: fn(v: VerdictRequest) {
    v.seen
  })
  use verdict <- codec.field(
    "verdict",
    codec.string_enum([
      #("approve", "approve"),
      #("reject", "reject"),
      #("correct", "correct"),
    ]),
    get: fn(v: VerdictRequest) { v.verdict },
  )
  use amount_cents <- codec.optional_field(
    "amount_cents",
    codec.int(),
    get: fn(v: VerdictRequest) { v.amount_cents },
  )
  use reason <- codec.optional_field(
    "reason",
    codec.string(),
    get: fn(v: VerdictRequest) { v.reason },
  )
  use note <- codec.optional_field(
    "note",
    codec.string(),
    get: fn(v: VerdictRequest) { v.note },
  )
  codec.success(VerdictRequest(
    occurrence:,
    seen:,
    verdict:,
    amount_cents:,
    reason:,
    note:,
  ))
}

pub type Decided {
  Decided(status: String, standing_cents: Int, approvals_have: Int)
}

fn decided_codec() -> Codec(Decided) {
  use status <- codec.field("status", codec.string(), get: fn(d: Decided) {
    d.status
  })
  use standing_cents <- codec.field(
    "standing_cents",
    codec.int(),
    get: fn(d: Decided) { d.standing_cents },
  )
  use approvals_have <- codec.field(
    "approvals_have",
    codec.int(),
    get: fn(d: Decided) { d.approvals_have },
  )
  codec.success(Decided(status:, standing_cents:, approvals_have:))
}

pub fn decide_definition() -> tool.Definition(VerdictRequest, Decided) {
  tool.define("decide_payout", verdict_request_codec(), decided_codec())
  |> tool.with_description(
    "Approve, reject or correct a payout on the card you opened (its occurrence and seen).",
  )
}

// -- Handlers ------------------------------------------------------------------------------

pub fn tools(deps: Deps) -> List(tool.Tool(Principal)) {
  [
    tool.handle_call(queue_definition(), fn(call, request: QueueRequest) {
      reply(payout_queue(deps, tool.context(call), request.limit))
    }),
    tool.handle_call(open_definition(), fn(call, request: OpenRequest) {
      reply(open(deps, tool.context(call), request.occurrence))
    }),
    tool.handle_call(decide_definition(), fn(call, request: VerdictRequest) {
      reply(decide(deps, tool.context(call), request))
    }),
  ]
}

fn reply(result: Result(a, String)) -> Result(tool.Reply(a), tool.ToolError) {
  result |> result.map(tool.complete) |> result.map_error(tool.error_message)
}

fn validator(deps: Deps, principal: Principal) -> Result(Validator, String) {
  db.validator(deps.db, principal.subject) |> result.map_error(db.describe)
}

pub fn payout_queue(
  deps: Deps,
  principal: Principal,
  limit: Int,
) -> Result(QueueReply, String) {
  use validator <- result.try(validator(deps, principal))
  use page <- result.try(
    queue.page_at(
      deps.pool,
      point: domain.payout_point_name,
      for: validator,
      limit:,
      after: None,
    )
    |> result.map_error(string.inspect),
  )
  use payouts <- result.map(
    list.try_map(page, fn(q) {
      use known <- result.map(read(deps, q.occurrence))
      let #(standing, approved) = occurrence.standing(known)
      let #(waiting_for, need) = waiting(known)
      Queued(
        occurrence: known.id,
        seller: standing.seller,
        order: standing.order,
        amount_cents: standing.amount_cents,
        waiting_for:,
        approvals_have: list.length(approved),
        approvals_need: need,
      )
    }),
  )
  QueueReply(payouts:)
}

fn read(deps: Deps, id: String) -> Result(Occurrence(Payout), String) {
  decisions_postgres.transaction(deps.pool, decisions.read(
    deps.desk(),
    _,
    occurrence: id,
  ))
  |> result.map_error(decisions_postgres.describe)
}

fn waiting(known: Occurrence(Payout)) -> #(List(String), Int) {
  case known.status {
    occurrence.Awaiting(eligible:) -> #(
      policy.sets(eligible),
      policy.approvals(eligible),
    )
    _ -> #([], 0)
  }
}

/// Open the card for `principal`, recording the showing. Everything on it
/// comes from the record, resolved as it was read.
pub fn open(
  deps: Deps,
  principal: Principal,
  id: String,
) -> Result(View(Payout), String) {
  use validator <- result.try(validator(deps, principal))
  use card <- result.map(
    decisions_postgres.transaction(deps.pool, fn(tx) {
      decisions.open(
        deps.desk(),
        tx,
        occurrence: id,
        by: validator,
        latest: reads.latest(deps.db),
      )
    })
    |> result.map_error(decisions_postgres.describe),
  )
  view.of(card, content: reads.content(deps.db))
}

/// What a verdict that did not go through answers. A release the tool could
/// not check (`ToolUnsure`) is no refusal of the verdict: nothing was
/// recorded, so the caller sends the same verdict again.
fn verdict_failure(failure: decisions_postgres.Failure) -> String {
  case failure {
    decisions_postgres.Refused(decisions.ToolUnsure(_)) ->
      "the payout could not be checked just now; nothing was recorded, try again"
    decisions_postgres.Contended(_) | decisions_postgres.Unavailable(_) ->
      "the desk is busy; nothing was recorded, try again"
    _ -> decisions_postgres.describe(failure)
  }
}

/// Give a verdict on the card the ticket names.
pub fn decide(
  deps: Deps,
  principal: Principal,
  request: VerdictRequest,
) -> Result(Decided, String) {
  use validator <- result.try(validator(deps, principal))
  use known <- result.try(read(deps, request.occurrence))
  let #(standing, _) = occurrence.standing(known)
  let reason = fn() {
    Reason(category: option.unwrap(request.reason, ""), note: request.note)
  }
  use verdict <- result.try(case request.verdict, request.amount_cents {
    "approve", _ -> Ok(Approve)
    "reject", _ -> Ok(Reject(reason()))
    "correct", Some(amount_cents) ->
      Ok(Correct(Payout(..standing, amount_cents:), reason()))
    "correct", None -> Error("a correction needs amount_cents")
    other, _ -> Error("no verdict named " <> other)
  })
  let ticket = Ticket(occurrence: request.occurrence, seen: request.seen)
  use decided <- result.map(
    decisions_postgres.decide(
      deps.pool,
      deps.desk(),
      fn(tx) {
        use card <- result.try(decisions.resume(
          deps.desk(),
          tx,
          ticket,
          by: validator,
        ))
        case request.note {
          Some(note) -> decisions.note(deps.desk(), tx, card, note)
          None -> Ok(card)
        }
      },
      verdict,
    )
    |> result.map_error(verdict_failure),
  )
  let #(standing, approved) = occurrence.standing(decided)
  Decided(
    status: occurrence.status_name(decided.status),
    standing_cents: standing.amount_cents,
    approvals_have: list.length(approved),
  )
}
