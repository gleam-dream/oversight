//// Pattern matching, arm by arm. The playground runs the `describe`
//// function from the compiled snippets (`snippets/src/shop/events.gleam`)
//// by hand: a case expression tries its arms from top to bottom and runs
//// the first whose pattern fits and whose guard, if any, holds.

import gleam/int
import gleam/list
import gleam/string

/// The values the reader can match, as in the snippet's `Event` type.
pub type Event {
  Pending
  Paid(items: List(String))
  Refunded(cents: Int, reason: String)
  Note(text: String)
}

/// The sample values on offer.
pub type Sample {
  LargeRefund
  SmallRefund
  PaidForNothing
  PaidForOne
  PaidForThree
  OrderNote
  OtherNote
  StillPending
}

pub const samples = [
  LargeRefund,
  SmallRefund,
  PaidForNothing,
  PaidForOne,
  PaidForThree,
  OrderNote,
  OtherNote,
  StillPending,
]

pub fn value(sample: Sample) -> Event {
  case sample {
    LargeRefund -> Refunded(cents: 25_000, reason: "damaged")
    SmallRefund -> Refunded(cents: 2000, reason: "late")
    PaidForNothing -> Paid(items: [])
    PaidForOne -> Paid(items: ["book"])
    PaidForThree -> Paid(items: ["book", "mug", "pen"])
    OrderNote -> Note("order-42")
    OtherNote -> Note("hello")
    StillPending -> Pending
  }
}

/// The value as Gleam writes it.
pub fn literal(event: Event) -> String {
  case event {
    Pending -> "Pending"
    Paid(items:) -> "Paid(items: " <> list_literal(items) <> ")"
    Refunded(cents:, reason:) ->
      "Refunded(cents: "
      <> int.to_string(cents)
      <> ", reason: "
      <> string.inspect(reason)
      <> ")"
    Note(text:) -> "Note(" <> string.inspect(text) <> ")"
  }
}

fn list_literal(items: List(String)) -> String {
  "[" <> string.join(list.map(items, string.inspect), ", ") <> "]"
}

// THE ARMS --------------------------------------------------------------------

pub type Arm {
  BigRefundArm
  RefundArm
  EmptyArm
  OneItemArm
  ManyItemsArm
  OrderNoteArm
  NothingArm
}

/// The arms in the order the case expression tries them.
pub const arms = [
  BigRefundArm,
  RefundArm,
  EmptyArm,
  OneItemArm,
  ManyItemsArm,
  OrderNoteArm,
  NothingArm,
]

/// The arm's pattern exactly as the snippet writes it, guard included. It
/// finds the arm's line in the snippet.
pub fn pattern(arm: Arm) -> String {
  case arm {
    BigRefundArm -> "Refunded(cents:, ..) if cents > 10_000 ->"
    RefundArm -> "Refunded(cents:, reason:) ->"
    EmptyArm -> "Paid(items: []) ->"
    OneItemArm -> "Paid(items: [only]) ->"
    ManyItemsArm -> "Paid(items: [first, ..rest]) ->"
    OrderNoteArm -> "Note(\"order-\" <> id) ->"
    NothingArm -> "Note(_) | Pending ->"
  }
}

/// A name a pattern bound, and the value it holds, as Gleam writes it.
pub type Binding {
  Binding(name: String, value: String)
}

pub type Attempt {
  /// An earlier arm already matched.
  NotTried
  /// The value does not have this shape.
  NoMatch
  /// The shape fits, but the guard is false.
  GuardFailed(bindings: List(Binding))
  Matched(bindings: List(Binding), result: String)
}

/// Try one arm on its own.
pub fn try_arm(arm: Arm, event: Event) -> Attempt {
  case arm, event {
    BigRefundArm, Refunded(cents:, ..) -> {
      let bindings = [Binding("cents", int.to_string(cents))]
      case cents > 10_000 {
        True -> Matched(bindings, "Ask finance")
        False -> GuardFailed(bindings)
      }
    }
    RefundArm, Refunded(cents:, reason:) ->
      Matched(
        [
          Binding("cents", int.to_string(cents)),
          Binding("reason", string.inspect(reason)),
        ],
        reason <> ", " <> int.to_string(cents),
      )
    EmptyArm, Paid(items: []) -> Matched([], "Paid for nothing?")
    OneItemArm, Paid(items: [only]) ->
      Matched([Binding("only", string.inspect(only))], "One item: " <> only)
    ManyItemsArm, Paid(items: [first, ..rest]) ->
      Matched(
        [
          Binding("first", string.inspect(first)),
          Binding("rest", list_literal(rest)),
        ],
        first <> " +" <> int.to_string(list.length(rest)),
      )
    OrderNoteArm, Note(text:) ->
      case string.starts_with(text, "order-") {
        True -> {
          let id = string.drop_start(text, string.length("order-"))
          Matched([Binding("id", string.inspect(id))], "About order " <> id)
        }
        False -> NoMatch
      }
    NothingArm, Note(_) | NothingArm, Pending -> Matched([], "Nothing to do")
    _, _ -> NoMatch
  }
}

// THE PROGRAM -----------------------------------------------------------------

/// The program the reader is looking at: the full case expression, or the
/// one with the `Paid(items: [])` arm deleted.
pub type Program {
  Complete
  WithoutEmptyArm
}

pub fn arms_of(program: Program) -> List(Arm) {
  case program {
    Complete -> arms
    WithoutEmptyArm -> list.filter(arms, fn(arm) { arm != EmptyArm })
  }
}

pub type Run {
  /// Every arm's attempt, in order; exactly one matched.
  Ran(attempts: List(#(Arm, Attempt)), result: String)
  /// The compiler refuses the program, so nothing runs at all.
  DoesNotCompile
}

/// Run the case expression on a value. Arms after the first match are not
/// tried. A program missing an arm does not compile, whatever the value.
pub fn run(program: Program, event: Event) -> Run {
  case program {
    WithoutEmptyArm -> DoesNotCompile
    Complete -> {
      let #(attempts, result) =
        list.fold(arms_of(program), #([], Error(Nil)), fn(acc, arm) {
          case acc {
            #(done, Ok(result)) -> #([#(arm, NotTried), ..done], Ok(result))
            #(done, Error(Nil)) ->
              case try_arm(arm, event) {
                Matched(result:, ..) as attempt -> #(
                  [#(arm, attempt), ..done],
                  Ok(result),
                )
                attempt -> #([#(arm, attempt), ..done], Error(Nil))
              }
          }
        })
      // Exhaustive by construction: some arm always matches.
      let assert Ok(result) = result
      Ran(list.reverse(attempts), result)
    }
  }
}

/// Remove an arm's line from the snippet, as the broken variant does.
pub fn source(program: Program, describe: String) -> String {
  case program {
    Complete -> describe
    WithoutEmptyArm ->
      string.split(describe, "\n")
      |> list.filter(fn(line) { !string.contains(line, pattern(EmptyArm)) })
      |> string.join("\n")
  }
}
