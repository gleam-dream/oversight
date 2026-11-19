//// The Fabric policy gate: a support agent's model proposed four tool calls
//// in one run, and the reader's policy decides each one.
////
//// A policy maps each guarded kind of call to a Fabric decision. A person
//// answers the calls that require approval. What happened to each call, and
//// how the run ends, follow from those two alone.

import gleam/dict.{type Dict}
import gleam/list

pub type Decision {
  Allow
  Deny(reason: String)
  RequireApproval(requirement: String)
  HandOver(reason: String)
}

/// The kinds of call the reader writes a rule for.
pub type Rule {
  SmallRefunds
  LargeRefunds
  ClosingAccounts
}

pub const rules = [SmallRefunds, LargeRefunds, ClosingAccounts]

/// The four calls of the model's reply, in the order it proposed them.
pub type CallId {
  LookupOrder
  RefundLateFee
  RefundSetupCharge
  CloseAccount
}

pub const calls = [LookupOrder, RefundLateFee, RefundSetupCharge, CloseAccount]

pub type Answer {
  Approved
  Rejected
}

pub type Policy {
  Policy(small: Decision, large: Decision, closing: Decision)
}

pub type Gate {
  Gate(policy: Policy, answers: Dict(CallId, Answer))
}

/// What happened to one call.
pub type Outcome {
  Ran(read_only: Bool)
  Denied(reason: String)
  /// This call was handed over: the run ended here.
  HandedOver
  /// Another call of the handed-over reply that had not started when the run
  /// ended, including one that was waiting for a person.
  Withdrawn
  WaitingForPerson
  ApprovedThenRan
  RejectedByPerson
}

pub type Run {
  FinishedHandedOver
  SuspendedForApproval
  FinishedWithAnswer
}

pub const finance_approves = RequireApproval("a person in finance approves")

pub const refund_desk = HandOver("refunds are filed to a decision point")

pub const closing_needs_a_human = Deny("closing accounts needs a human")

pub const large_refunds_need_a_human = Deny("refunds over €100 need a human")

pub const default_policy =
  Policy(small: Allow, large: finance_approves, closing: closing_needs_a_human)

pub fn new() -> Gate {
  Gate(policy: default_policy, answers: dict.new())
}

/// The decisions the reader can choose for a rule, with their button labels.
pub fn options(rule: Rule) -> List(#(String, Decision)) {
  case rule {
    SmallRefunds -> [
      #("Allow", Allow),
      #("Approval", finance_approves),
      #("Hand over", refund_desk),
    ]
    LargeRefunds -> [
      #("Approval", finance_approves),
      #("Hand over", refund_desk),
      #("Deny", large_refunds_need_a_human),
    ]
    ClosingAccounts -> [
      #("Deny", closing_needs_a_human),
      #("Approval", finance_approves),
    ]
  }
}

pub fn rule_label(rule: Rule) -> String {
  case rule {
    SmallRefunds -> "Refunds up to €100"
    LargeRefunds -> "Refunds over €100"
    ClosingAccounts -> "Closing an account"
  }
}

pub fn decision(policy: Policy, rule: Rule) -> Decision {
  case rule {
    SmallRefunds -> policy.small
    LargeRefunds -> policy.large
    ClosingAccounts -> policy.closing
  }
}

/// Rewriting a rule withdraws every answer given under the old policy.
pub fn set_rule(gate: Gate, rule: Rule, decision: Decision) -> Gate {
  let policy = case rule {
    SmallRefunds -> Policy(..gate.policy, small: decision)
    LargeRefunds -> Policy(..gate.policy, large: decision)
    ClosingAccounts -> Policy(..gate.policy, closing: decision)
  }
  Gate(policy:, answers: dict.new())
}

/// Why an answer was not taken.
pub type Refusal {
  /// The run ended as HandedOver, which voided every approval request.
  RunEnded
  /// The call is not waiting for a person.
  NotAwaitingApproval
}

/// A person answers a call that is waiting for one.
pub fn answer(
  gate: Gate,
  call: CallId,
  answer: Answer,
) -> Result(Gate, Refusal) {
  case run(gate), list.key_find(outcomes(gate), call) {
    FinishedHandedOver, _ -> Error(RunEnded)
    _, Ok(WaitingForPerson) ->
      Ok(Gate(..gate, answers: dict.insert(gate.answers, call, answer)))
    _, _ -> Error(NotAwaitingApproval)
  }
}

pub fn reset_approvals(gate: Gate) -> Gate {
  Gate(..gate, answers: dict.new())
}

pub fn turn(call: CallId) -> Int {
  case call {
    LookupOrder -> 1
    _ -> 2
  }
}

pub fn call_text(call: CallId) -> String {
  case call {
    LookupOrder -> "lookup_order(customer: \"ana\")"
    RefundLateFee -> "refund_fee(amount: €40)"
    RefundSetupCharge -> "refund_fee(amount: €650)"
    CloseAccount -> "close_account(customer: \"ana\")"
  }
}

/// The rule that guards a call; read-only calls are always allowed.
pub fn guard(call: CallId) -> Result(Rule, Nil) {
  case call {
    LookupOrder -> Error(Nil)
    RefundLateFee -> Ok(SmallRefunds)
    RefundSetupCharge -> Ok(LargeRefunds)
    CloseAccount -> Ok(ClosingAccounts)
  }
}

/// Each call with what happened to it, in proposal order. A handover ends the
/// run in the commit that admits its reply: the reply's other calls that had
/// not started, allowed or waiting for a person, are withdrawn, refusals keep
/// their states, and the calls after it never reach the policy.
pub fn outcomes(gate: Gate) -> List(#(CallId, Outcome)) {
  let judged = list.map(calls, fn(call) { #(call, judge(gate, call)) })
  case list.find(judged, fn(pair) { pair.1 == HandedOver }) {
    Error(Nil) -> judged
    Ok(#(handed, _)) -> {
      let #(_, outcomes) =
        list.fold(judged, #(False, []), fn(acc, pair) {
          let #(after, done) = acc
          let #(call, outcome) = pair
          let outcome = case turn(call) == turn(handed), after, outcome {
            False, _, _ -> outcome
            True, True, _ -> Withdrawn
            True, False, HandedOver
            | True, False, Denied(_)
            | True, False, RejectedByPerson
            -> outcome
            True, False, _ -> Withdrawn
          }
          #(after || outcome == HandedOver, [#(call, outcome), ..done])
        })
      list.reverse(outcomes)
    }
  }
}

fn judge(gate: Gate, call: CallId) -> Outcome {
  case guard(call) {
    Error(Nil) -> Ran(read_only: True)
    Ok(rule) ->
      case decision(gate.policy, rule) {
        Allow -> Ran(read_only: False)
        Deny(reason) -> Denied(reason)
        HandOver(_) -> HandedOver
        RequireApproval(_) ->
          case dict.get(gate.answers, call) {
            Ok(Approved) -> ApprovedThenRan
            Ok(Rejected) -> RejectedByPerson
            Error(Nil) -> WaitingForPerson
          }
      }
  }
}

pub fn run(gate: Gate) -> Run {
  let outcomes = list.map(outcomes(gate), fn(pair) { pair.1 })
  case
    list.contains(outcomes, HandedOver),
    list.contains(outcomes, WaitingForPerson)
  {
    True, _ -> FinishedHandedOver
    False, True -> SuspendedForApproval
    False, False -> FinishedWithAnswer
  }
}
