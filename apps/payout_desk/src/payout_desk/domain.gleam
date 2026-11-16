//// The marketplace's payout domain: the output of the `payout` decision
//// point, the facts its policy reads, the policy as data, the typed context
//// the model and the card both read, and what really happened to a payout,
//// told back to the agent and checked against what it tells the seller.
////
//// Everything here is pure. The boundaries (`agent`, `desk_tools`, `jobs`,
//// `workflow`, `db`) call it.

import decisions.{type Point}
import decisions/fact
import decisions/model.{type Reader, type Sources}
import decisions/occurrence.{type Occurrence}
import decisions/policy.{
  type Policy, All, AnyoneHolding, Ask, Consult, Either, Never, Not, Policy,
  Proceed, Several, SomeoneElseHolding, When,
}
import decisions/vocabulary.{
  type Manifest, ApproveRejectOrCorrect, NotPerformed, Performed, Uncertain,
}
import decisions/wire
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import json/blueprint/codec.{type Codec}

// -- Money ------------------------------------------------------------------------

/// An amount in cents as the marketplace writes it: `"60.00"`.
pub fn money(cents: Int) -> String {
  let sign = case cents < 0 {
    True -> "-"
    False -> ""
  }
  let cents = int.absolute_value(cents)
  sign
  <> int.to_string(cents / 100)
  <> "."
  <> string.pad_start(int.to_string(cents % 100), 2, "0")
}

// -- The point's output -------------------------------------------------------------

/// What the agent proposes and finance may correct: pay `amount_cents` to
/// `seller` for `order`.
pub type Payout {
  Payout(seller: String, order: String, amount_cents: Int, reason: String)
}

pub fn payout_codec() -> Codec(Payout) {
  use seller <- codec.field("seller", codec.string(), get: fn(p: Payout) {
    p.seller
  })
  use order <- codec.field("order", codec.string(), get: fn(p: Payout) {
    p.order
  })
  use amount_cents <- codec.field(
    "amount_cents",
    codec.int(),
    get: fn(p: Payout) { p.amount_cents },
  )
  use reason <- codec.field("reason", codec.string(), get: fn(p: Payout) {
    p.reason
  })
  codec.success(Payout(seller:, order:, amount_cents:, reason:))
}

/// What the consulted `risk` point answers about a seller.
pub type Risk {
  Risk(level: String, reason: String)
}

pub fn risk_codec() -> Codec(Risk) {
  use level <- codec.field("level", codec.string(), get: fn(r: Risk) { r.level })
  use reason <- codec.field("reason", codec.string(), get: fn(r: Risk) {
    r.reason
  })
  codec.success(Risk(level:, reason:))
}

// -- Facts ------------------------------------------------------------------------------

/// The payout's amount in currency units, computed from the output.
pub fn amount() -> fact.Key(Float) {
  fact.number("amount")
}

/// The dispute the model read was resolved in the seller's favour. The
/// application computes it from the dispute record the model received.
pub fn dispute_for_seller() -> fact.Key(Bool) {
  fact.flag("dispute_for_seller")
}

/// The payout history the model read shows a chargeback in the last 90 days.
pub fn recent_chargeback() -> fact.Key(Bool) {
  fact.flag("recent_chargeback")
}

/// What the consulted `risk` point answered: `"low"` or `"high"`.
pub fn risk_level() -> fact.Key(String) {
  fact.text("risk")
}

pub const payout_point_name = "payout"

pub const risk_point_name = "risk"

/// The decision sets the application gives its staff.
pub const finance = "finance"

pub const head_of_finance = "head_of_finance"

/// The output's codec as the decision record keeps it.
pub fn payout_record_codec() -> wire.Codec(Payout) {
  wire.codec(payout_codec())
}

/// The event that makes every pending payout to a seller stale: their
/// account was suspended for review.
pub const seller_suspended = "seller_suspended"

/// The `payout` point. Finance may approve, reject or correct, and finance
/// may withdraw a payout during the hold the policy gave it (the hold
/// itself is the policy's, `payout_policy`); a payout a person approved is
/// released at once. `validity` is how long a payout may wait for its
/// verdicts. A suspended seller's pending payouts, held ones included, are
/// superseded.
pub fn payout_point(validity validity: Duration) -> Point(Payout) {
  decisions.point(payout_point_name, payout_record_codec())
  |> decisions.allowing(ApproveRejectOrCorrect)
  |> decisions.fact(amount(), fn(payout: Payout) {
    int.to_float(payout.amount_cents) /. 100.0
  })
  |> decisions.signal(dispute_for_seller())
  |> decisions.signal(recent_chargeback())
  |> decisions.signal(risk_level())
  |> decisions.withdrawn_by(finance)
  |> decisions.superseded_by(seller_suspended)
  |> decisions.valid_for(validity)
}

/// The `risk` point: a rule answers, and its settlement informs the payout
/// that consulted it.
pub fn risk_point() -> Point(Risk) {
  decisions.point(risk_point_name, wire.codec(risk_codec()))
}

/// Below this a payout whose dispute the seller won proceeds by itself.
pub const small_below_cents = 5000

/// From this a payout needs two approvals from finance, or, after an hour,
/// one from the head of finance.
pub const large_from_cents = 50_000

/// After this many minutes unanswered, the head of finance may approve a
/// large payout alone.
pub const escalate_after_minutes = 60

/// The payout policy as data, at `version`, with `hold` as the undo window
/// of the payouts it lets proceed:
///
/// 1. A seller with a recent chargeback is assessed by `risk` first.
/// 2. A high risk needs two approvals from finance.
/// 3. A large payout unanswered for an hour needs two approvals from
///    finance, neither of them whoever asked, or one from the head of
///    finance.
/// 4. A large payout needs two approvals from finance, neither of them
///    whoever asked.
/// 5. A small payout whose dispute the seller won proceeds, and waits out
///    `hold`, during which finance may withdraw it.
/// 6. Anything else needs one approval from finance, never from whoever
///    asked.
pub fn payout_policy(version version: Int, hold hold: Duration) -> Policy {
  let large = policy.at_least(amount(), int.to_float(large_from_cents) /. 100.0)
  let small = policy.below(amount(), int.to_float(small_below_cents) /. 100.0)
  Policy(
    version:,
    rules: [
      When(
        All([
          policy.is(recent_chargeback(), True),
          Not(policy.known(risk_level())),
        ]),
        Consult(risk_point_name),
      ),
      When(
        policy.is(risk_level(), "high"),
        Ask(Several(2, SomeoneElseHolding(finance))),
      ),
      When(
        All([large, policy.waited(escalate_after_minutes)]),
        Ask(
          Either([
            Several(2, SomeoneElseHolding(finance)),
            AnyoneHolding(head_of_finance),
          ]),
        ),
      ),
      When(large, Ask(Several(2, SomeoneElseHolding(finance)))),
      When(
        All([small, policy.is(dispute_for_seller(), True)]),
        Proceed(sample: Never, hold: Some(hold)),
      ),
    ],
    otherwise: Ask(SomeoneElseHolding(finance)),
  )
}

/// The risk point lets its rule's answer through.
pub fn risk_policy() -> Policy {
  Policy(version: 1, rules: [], otherwise: Proceed(sample: Never, hold: None))
}

/// The risk rule: two or more chargebacks in 90 days is high.
pub fn assess_risk(chargebacks_90_days: Int) -> Risk {
  case chargebacks_90_days >= 2 {
    True ->
      Risk(
        level: "high",
        reason: int.to_string(chargebacks_90_days) <> " chargebacks in 90 days",
      )
    False ->
      Risk(
        level: "low",
        reason: int.to_string(chargebacks_90_days) <> " chargeback in 90 days",
      )
  }
}

// -- What the model reads ----------------------------------------------------------------

/// Dora's request as support recorded it.
pub type Request {
  Request(id: String, seller: String, order: String, text: String)
}

pub fn request_codec() -> Codec(Request) {
  use id <- codec.field("id", codec.string(), get: fn(r: Request) { r.id })
  use seller <- codec.field("seller", codec.string(), get: fn(r: Request) {
    r.seller
  })
  use order <- codec.field("order", codec.string(), get: fn(r: Request) {
    r.order
  })
  use text <- codec.field("text", codec.string(), get: fn(r: Request) { r.text })
  codec.success(Request(id:, seller:, order:, text:))
}

pub type Order {
  Order(id: String, seller: String, total_cents: Int, status: String)
}

pub fn order_codec() -> Codec(Order) {
  use id <- codec.field("id", codec.string(), get: fn(o: Order) { o.id })
  use seller <- codec.field("seller", codec.string(), get: fn(o: Order) {
    o.seller
  })
  use total_cents <- codec.field("total_cents", codec.int(), get: fn(o: Order) {
    o.total_cents
  })
  use status <- codec.field("status", codec.string(), get: fn(o: Order) {
    o.status
  })
  codec.success(Order(id:, seller:, total_cents:, status:))
}

/// How a dispute ended. `seller_owed_cents` is what the marketplace still
/// owes the seller for the order; `fee_cents` the chargeback fee in it.
pub type Dispute {
  Dispute(
    order: String,
    status: String,
    seller_owed_cents: Int,
    fee_cents: Int,
    note: String,
  )
}

pub fn dispute_codec() -> Codec(Dispute) {
  use order <- codec.field("order", codec.string(), get: fn(d: Dispute) {
    d.order
  })
  use status <- codec.field("status", codec.string(), get: fn(d: Dispute) {
    d.status
  })
  use seller_owed_cents <- codec.field(
    "seller_owed_cents",
    codec.int(),
    get: fn(d: Dispute) { d.seller_owed_cents },
  )
  use fee_cents <- codec.field("fee_cents", codec.int(), get: fn(d: Dispute) {
    d.fee_cents
  })
  use note <- codec.field("note", codec.string(), get: fn(d: Dispute) { d.note })
  codec.success(Dispute(order:, status:, seller_owed_cents:, fee_cents:, note:))
}

/// The dispute status that lets a small payout proceed.
pub const won_by_seller = "seller_favour"

pub type History {
  History(seller: String, paid_cents: List(Int), chargebacks_90_days: Int)
}

pub fn history_codec() -> Codec(History) {
  use seller <- codec.field("seller", codec.string(), get: fn(h: History) {
    h.seller
  })
  use paid_cents <- codec.field(
    "paid_cents",
    codec.list(codec.int()),
    get: fn(h: History) { h.paid_cents },
  )
  use chargebacks_90_days <- codec.field(
    "chargebacks_90_days",
    codec.int(),
    get: fn(h: History) { h.chargebacks_90_days },
  )
  codec.success(History(seller:, paid_cents:, chargebacks_90_days:))
}

/// The names of the agent's read tools. A read the model received is
/// recorded under its tool's name and argument, so these names are also
/// how the card and a replay find them.
pub const read_order = "lookup_order"

pub const read_dispute = "lookup_dispute"

pub const read_history = "payout_history"

/// Everything the model had: the request and the three reads.
pub type Case {
  Case(request: Request, order: Order, dispute: Dispute, history: History)
}

/// How the payout point reads its context into a `Case`: the request from
/// the context, then each read the agent makes, by its tool name and
/// argument. The same function serves the card (`decisions/view.context`)
/// and a replay (`decisions/learning`), so both see what the model saw.
pub fn read_case() -> Reader(Case) {
  fn(context: Manifest, sources: Sources) {
    use ref <- result.try(case context.refs {
      [ref, ..] -> Ok(ref)
      [] -> Error(model.Declined("the context names no request"))
    })
    use text <- result.try(sources.resolve(ref))
    use request <- result.try(decoded(request_codec(), "request", text))
    use order <- result.try(read(
      sources,
      order_codec(),
      read_order,
      request.order,
    ))
    use dispute <- result.try(read(
      sources,
      dispute_codec(),
      read_dispute,
      request.order,
    ))
    use history <- result.try(read(
      sources,
      history_codec(),
      read_history,
      request.seller,
    ))
    Ok(Case(request:, order:, dispute:, history:))
  }
}

fn read(
  sources: Sources,
  codec: Codec(a),
  name: String,
  argument: String,
) -> Result(a, model.Failure) {
  use captured <- result.try(sources.read(name, argument))
  decoded(codec, name, captured.body)
}

fn decoded(
  codec: Codec(a),
  name: String,
  text: String,
) -> Result(a, model.Failure) {
  codec.decode_json(codec, text)
  |> result.map_error(fn(error) {
    model.Undecodable(name <> ": " <> codec.describe_decode_error(error))
  })
}

/// The signals the application reports beside the agent's proposal,
/// computed from what the model received, never from its text.
pub fn signals(
  dispute: Option(Dispute),
  history: Option(History),
) -> List(#(String, vocabulary.Fact)) {
  list.flatten([
    case dispute {
      Some(dispute) -> [
        fact.set(dispute_for_seller(), dispute.status == won_by_seller),
      ]
      None -> []
    },
    case history {
      Some(history) -> [
        fact.set(recent_chargeback(), history.chargebacks_90_days > 0),
      ]
      None -> []
    },
  ])
}

// -- What really happened ----------------------------------------------------------

/// What became of a payout, as the record says. This, and nothing the
/// model says, is what the agent and the seller are told.
pub type Truth {
  /// The provider paid `amount_cents`. `asked_cents` is what the agent
  /// proposed, different when finance corrected it.
  Paid(amount_cents: Int, asked_cents: Int, receipt: String)
  /// Released, and the provider did not pay.
  NotPaid(amount_cents: Int, reason: String)
  /// Finance rejected it.
  Rejected(reason: String)
  /// Nobody decided in time.
  Expired
  /// A newer event made the payout stale before it was released.
  Superseded(event: String)
  /// Finance took it back during the undo window the policy gave it.
  Withdrawn(by: String)
  /// The guard, the release check or the gated tool refused the release
  /// (the balance, for one).
  Refused(reason: String)
}

/// The outcome's name, as the agent's answer must state it.
pub fn outcome_name(truth: Truth) -> String {
  case truth {
    Paid(..) -> "paid"
    NotPaid(..) -> "not_paid"
    Rejected(..) -> "rejected"
    Expired -> "expired"
    Superseded(..) -> "superseded"
    Withdrawn(..) -> "withdrawn"
    Refused(..) -> "refused"
  }
}

/// The amount the seller receives under this outcome.
pub fn paid_cents(truth: Truth) -> Int {
  case truth {
    Paid(amount_cents:, ..) -> amount_cents
    _ -> 0
  }
}

pub fn truth_codec() -> Codec(Truth) {
  codec.union({
    use paid <- codec.variant(
      "paid",
      {
        use amount_cents <- codec.field(
          "amount_cents",
          codec.int(),
          get: fn(t: #(Int, Int, String)) { t.0 },
        )
        use asked_cents <- codec.field(
          "asked_cents",
          codec.int(),
          get: fn(t: #(Int, Int, String)) { t.1 },
        )
        use receipt <- codec.field(
          "receipt",
          codec.string(),
          get: fn(t: #(Int, Int, String)) { t.2 },
        )
        codec.success(#(amount_cents, asked_cents, receipt))
      },
      fn(t) { Paid(t.0, t.1, t.2) },
    )
    use not_paid <- codec.variant(
      "not_paid",
      {
        use amount_cents <- codec.field(
          "amount_cents",
          codec.int(),
          get: fn(t: #(Int, String)) { t.0 },
        )
        use reason <- codec.field(
          "reason",
          codec.string(),
          get: fn(t: #(Int, String)) { t.1 },
        )
        codec.success(#(amount_cents, reason))
      },
      fn(t) { NotPaid(t.0, t.1) },
    )
    use rejected <- codec.variant("rejected", codec.string(), Rejected)
    use expired <- codec.unit_variant("expired", Expired)
    use superseded <- codec.variant("superseded", codec.string(), Superseded)
    use withdrawn <- codec.variant("withdrawn", codec.string(), Withdrawn)
    use refused <- codec.variant("refused", codec.string(), Refused)
    codec.match(fn(truth) {
      case truth {
        Paid(amount_cents:, asked_cents:, receipt:) ->
          paid(#(amount_cents, asked_cents, receipt))
        NotPaid(amount_cents:, reason:) -> not_paid(#(amount_cents, reason))
        Rejected(reason) -> rejected(reason)
        Expired -> expired
        Superseded(event) -> superseded(event)
        Withdrawn(by) -> withdrawn(by)
        Refused(reason) -> refused(reason)
      }
    })
  })
}

/// What the record says happened (`occurrence.account`), in the words the
/// agent and the seller are told, or `None` while it is not known yet: the
/// payout waits for people or its hold, or its release waits for the
/// provider, or the provider's answer is uncertain.
pub fn truth_of(known: Occurrence(Payout)) -> Option(Truth) {
  let asked = known.recommendation.output.amount_cents
  case occurrence.account(known) {
    occurrence.Undecided | occurrence.Done(effect: None, ..) -> None
    occurrence.Done(final:, effect: Some(Performed(receipt:)), ..) ->
      Some(Paid(
        amount_cents: final.amount_cents,
        asked_cents: asked,
        receipt: receipt.revision,
      ))
    occurrence.Done(final:, effect: Some(NotPerformed(reason:)), ..) ->
      Some(NotPaid(amount_cents: final.amount_cents, reason:))
    // `account` reports an uncertain effect as `None`.
    occurrence.Done(effect: Some(Uncertain(_)), ..) -> None
    occurrence.TurnedDown(reason:, ..) ->
      Some(Rejected(option.unwrap(reason.note, reason.category)))
    occurrence.Lapsed(vocabulary.Superseded(event:)) -> Some(Superseded(event))
    occurrence.Lapsed(vocabulary.DeadlinePassed) -> Some(Expired)
    occurrence.TakenBack(by:) -> Some(Withdrawn(by))
    occurrence.Blocked(reason:) -> Some(Refused(reason))
  }
}

// -- What the agent says --------------------------------------------------------------

/// The agent's typed final answer: what it tells the seller, and the
/// outcome and amount it claims, so the application can check the claim
/// against the record before anyone reads the message.
pub type Reply {
  Reply(outcome: String, amount_cents: Int, message: String)
}

pub fn reply_codec() -> Codec(Reply) {
  use outcome <- codec.field("outcome", codec.string(), get: fn(r: Reply) {
    r.outcome
  })
  use amount_cents <- codec.field(
    "amount_cents",
    codec.int(),
    get: fn(r: Reply) { r.amount_cents },
  )
  use message <- codec.field("message", codec.string(), get: fn(r: Reply) {
    r.message
  })
  codec.success(Reply(outcome:, amount_cents:, message:))
}

/// Whether a reply claims what the record says: the same outcome and the
/// amount the seller really receives.
pub fn is_truthful(reply: Reply, truth: Truth) -> Bool {
  reply.outcome == outcome_name(truth)
  && reply.amount_cents == paid_cents(truth)
}

/// The message the application sends instead of a reply that claims
/// something the record does not say.
pub fn plain_message(seller: String, truth: Truth) -> String {
  let name = string.capitalise(seller)
  case truth {
    Paid(amount_cents:, asked_cents:, ..) if amount_cents != asked_cents ->
      name
      <> ", we paid you "
      <> money(amount_cents)
      <> ". Finance corrected the "
      <> money(asked_cents)
      <> " we first proposed."
    Paid(amount_cents:, ..) ->
      name <> ", we paid you " <> money(amount_cents) <> "."
    NotPaid(..) ->
      name <> ", the payout could not be made; nothing left your balance."
    Rejected(reason) ->
      name <> ", finance did not approve the payout: " <> reason <> "."
    Expired ->
      name <> ", your request was not decided in time; nothing was paid."
    Superseded(..) ->
      name
      <> ", the payout was stopped while your account is under review; nothing was paid."
    Withdrawn(..) -> name <> ", the payout was withdrawn; nothing was paid."
    Refused(..) -> name <> ", the payout could not be made; nothing was paid."
  }
}
