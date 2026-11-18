//// "Did it happen?": charge a card, break the network at a chosen moment,
//// then retry with or without an idempotency key. The provider keeps an
//// idempotency ledger, and a sequence chart shows request, effect and reply.

import gleam/int
import gleam/list
import gleam/string
import site/msc

// STATE -----------------------------------------------------------------------

/// The moment the connection drops.
pub type Break {
  Never
  WhileConnecting
  WhileSending
  WhileProviderWorks
  WhileReplyTravels
}

pub const breaks = [
  Never,
  WhileConnecting,
  WhileSending,
  WhileProviderWorks,
  WhileReplyTravels,
]

/// What the caller's code can prove about the request.
pub type Evidence {
  Answered
  NotSent
  MaybeSent
}

pub type Curtain {
  Hidden
  Revealed
}

pub type Key {
  WithoutKey
  WithKey
}

/// Retries the reader made, and the conditions they were made under. They
/// only count while the break and the key are still the same.
pub type Retries {
  NoRetries
  Retried(at: Break, key: Key, count: Int)
}

/// The sentence beside the retry button.
pub type Note {
  ChooseAMoment
  ConnectionDrops(Break)
  Retry(Verdict)
}

pub type Verdict {
  /// A definite answer was already in hand; a keyless retry is a new charge.
  AlreadyAnswered
  /// A definite answer was in hand, and the key made the retry harmless.
  SameKeyReplaysAnswer
  SafeBecauseNotSent
  KeyReplayedOriginal
  KeyChargedNow
  ChargedTwice
  GotLucky
}

pub type Happen {
  Happen(at: Break, curtain: Curtain, key: Key, retries: Retries, note: Note)
}

pub fn initial() -> Happen {
  Happen(
    at: WhileSending,
    curtain: Hidden,
    key: WithoutKey,
    retries: NoRetries,
    note: ChooseAMoment,
  )
}

// TRANSITIONS -----------------------------------------------------------------

pub fn break_at(happen: Happen, at: Break) -> Happen {
  Happen(..happen, at:, curtain: Hidden, note: ConnectionDrops(at))
}

pub fn peek(happen: Happen) -> Happen {
  Happen(..happen, curtain: Revealed)
}

pub fn toggle_key(happen: Happen) -> Happen {
  Happen(..happen, key: case happen.key {
    WithKey -> WithoutKey
    WithoutKey -> WithKey
  })
}

pub fn retry(happen: Happen) -> Happen {
  let charged = charged_before_retry(happen.at)
  let verdict = case evidence(happen.at), happen.key, charged {
    Answered, WithKey, _ -> SameKeyReplaysAnswer
    Answered, WithoutKey, _ -> AlreadyAnswered
    NotSent, _, _ -> SafeBecauseNotSent
    MaybeSent, WithKey, True -> KeyReplayedOriginal
    MaybeSent, WithKey, False -> KeyChargedNow
    MaybeSent, WithoutKey, True -> ChargedTwice
    MaybeSent, WithoutKey, False -> GotLucky
  }
  Happen(
    ..happen,
    retries: Retried(
      at: happen.at,
      key: happen.key,
      count: retries_shown(happen) + 1,
    ),
    note: Retry(verdict),
  )
}

/// Retries made under the current break and key.
pub fn retries_shown(happen: Happen) -> Int {
  case happen.retries {
    Retried(at:, key:, count:) if at == happen.at && key == happen.key -> count
    _ -> 0
  }
}

// DESCRIPTION -----------------------------------------------------------------

pub fn label(at: Break) -> String {
  case at {
    Never -> "Never"
    WhileConnecting -> "While connecting"
    WhileSending -> "While sending"
    WhileProviderWorks -> "While provider works"
    WhileReplyTravels -> "While reply travels"
  }
}

pub fn evidence(at: Break) -> Evidence {
  case at {
    Never -> Answered
    WhileConnecting -> NotSent
    _ -> MaybeSent
  }
}

pub fn evidence_label(at: Break) -> String {
  case at {
    Never -> "Response: 200 OK"
    WhileConnecting -> "NotSent"
    _ -> "MaybeSent"
  }
}

pub fn evidence_why(at: Break) -> String {
  case at {
    Never ->
      "A real answer came back. A 404 or 500 would be data too: the library reports it, and your code decides what it means."
    WhileConnecting ->
      "The connection never opened, so not one byte of the request left your machine. That is provable."
    WhileSending ->
      "Some bytes may have left. The provider might have the full request, part of it, or none."
    WhileProviderWorks ->
      "The whole request was sent, then the connection died. The provider may be halfway through."
    WhileReplyTravels ->
      "The provider finished and replied, but the answer never reached you. To your code this looks identical to the previous case."
  }
}

pub fn truth(at: Break) -> String {
  case at {
    Never -> "Charged once."
    WhileConnecting -> "Nothing. The provider never heard of you."
    WhileSending ->
      "Nothing this time: the request arrived incomplete. But you couldn’t know that."
    WhileProviderWorks ->
      "Charged once. The card was debited just before the line dropped."
    WhileReplyTravels -> "Charged once."
  }
}

pub fn safe_move(at: Break) -> String {
  case evidence(at) {
    Answered -> "Act on the answer. Nothing to reconcile."
    NotSent -> "Retrying is completely safe."
    MaybeSent ->
      "Don’t blindly retry. Retry with the same idempotency key, or ask the provider what it has."
  }
}

/// Whether the provider charged the card before any retry.
pub fn charged_before_retry(at: Break) -> Bool {
  case at {
    Never | WhileProviderWorks | WhileReplyTravels -> True
    WhileConnecting | WhileSending -> False
  }
}

pub fn note_text(note: Note) -> String {
  case note {
    ChooseAMoment -> "Choose a moment, then try a retry."
    ConnectionDrops(at) ->
      "Connection drops " <> string.lowercase(label(at)) <> ". Now try a retry."
    Retry(AlreadyAnswered) ->
      "You already have a definite answer. A retry here would be a second, separate charge."
    Retry(SameKeyReplaysAnswer) ->
      "Same key: the provider recognises it and replays the stored answer. Still charged exactly once."
    Retry(SafeBecauseNotSent) ->
      "Retried. Charged exactly once. NotSent made this safe with or without a key."
    Retry(KeyReplayedOriginal) ->
      "Retried with the same key. The provider recognised it and returned the original result: charged exactly once."
    Retry(KeyChargedNow) ->
      "Retried with the key. The provider had nothing under that key, so it charged now: exactly once."
    Retry(ChargedTwice) ->
      "Retried without a key. The provider saw a brand-new request: the customer is now charged TWICE."
    Retry(GotLucky) ->
      "Retried without a key and got lucky: charged once. Next time you might not be."
  }
}

// THE JOURNEY -----------------------------------------------------------------

pub type StageMark {
  Done
  ConnectionLost
  NotReached
}

pub type Stage {
  Stage(where: String, label: String, mark: StageMark)
}

const stages = [
  #("your app", "Check destination"),
  #("network", "Connect"),
  #("network", "Send request"),
  #("provider", "Charge the card"),
  #("network", "Send reply"),
  #("your app", "Read reply"),
]

pub fn journey(at: Break) -> List(Stage) {
  let break_at = case at {
    Never -> 99
    WhileConnecting -> 1
    WhileSending -> 2
    WhileProviderWorks -> 3
    WhileReplyTravels -> 4
  }
  list.index_map(stages, fn(s, i) {
    let mark = case i == break_at, i < break_at {
      True, _ -> ConnectionLost
      False, True -> Done
      False, False -> NotReached
    }
    Stage(where: s.0, label: s.1, mark:)
  })
}

// THE PROVIDER'S SIDE ---------------------------------------------------------

pub type Tone {
  /// A first, correct charge.
  Charged
  /// Nothing recorded, or nothing charged.
  Quiet
  /// A second charge: the customer pays twice.
  Double
}

pub type Row {
  Row(request: String, key: String, tone: Tone, result: String)
}

/// The provider's idempotency ledger, the chart events and the number of
/// times the customer was charged.
pub type Picture {
  Picture(ledger: List(Row), events: List(msc.Event), charges: Int)
}

pub fn picture(happen: Happen) -> Picture {
  let keyed = happen.key == WithKey
  let key = case keyed {
    True -> "order-o1"
    False -> "(none)"
  }
  let charges = case charged_before_retry(happen.at) {
    True -> 1
    False -> 0
  }
  let first =
    Row(
      request: "#1",
      key:,
      tone: case charges {
        0 -> Quiet
        _ -> Charged
      },
      result: case happen.at {
        WhileConnecting -> "never arrived: nothing recorded"
        WhileSending -> "arrived incomplete: discarded"
        _ ->
          "card charged · ch_1 · response stored"
          <> case keyed {
            True -> " under the key"
            False -> ""
          }
      },
    )
  let with_key = case keyed {
    True -> " + key"
    False -> ""
  }
  let ok = msc.Message(2, 0, "200 OK", msc.Green, msc.Dashed)
  let maybe = msc.Note(0, "MaybeSent", msc.Amber)
  let events = case happen.at {
    WhileConnecting -> [
      msc.Lost(0, 1, "connect", msc.Grey),
      msc.Note(0, "NotSent", msc.Blue),
    ]
    WhileSending -> [msc.Lost(0, 2, "POST /charges", msc.Ink), maybe]
    Never -> [
      msc.send(0, 2, "POST /charges" <> with_key, msc.Ink),
      msc.Note(2, "charges the card", msc.Pink),
      ok,
    ]
    WhileProviderWorks | WhileReplyTravels -> [
      msc.send(0, 2, "POST /charges" <> with_key, msc.Ink),
      msc.Note(2, "charges the card", msc.Pink),
      msc.Lost(2, 0, "reply", msc.Grey),
      maybe,
    ]
  }
  let retry_label = case keyed {
    True -> "retry + same key"
    False -> "retry"
  }
  let #(rows, events, charges) =
    list.fold(
      range(1, retries_shown(happen)),
      #([first], list.reverse(events), charges),
      fn(acc, i) {
        let #(rows, events, charges) = acc
        let request = "#" <> int.to_string(i + 1)
        let events = [msc.send(0, 2, retry_label, msc.Ink), ..events]
        let #(row, note, charges) = case keyed && charges > 0 {
          True -> #(
            Row(
              request:,
              key:,
              tone: Charged,
              result: "key seen before → stored response replayed, no new charge",
            ),
            msc.Note(2, "replays stored result", msc.Green),
            charges,
          )
          False -> {
            let charges = charges + 1
            case charges > 1 {
              True -> #(
                Row(
                  request:,
                  key:,
                  tone: Double,
                  result: "NEW charge · ch_" <> int.to_string(charges),
                ),
                msc.Note(2, "charges AGAIN", msc.Red),
                charges,
              )
              False -> #(
                Row(
                  request:,
                  key:,
                  tone: Charged,
                  result: "card charged · ch_1",
                ),
                msc.Note(2, "charges the card", msc.Pink),
                charges,
              )
            }
          }
        }
        #([row, ..rows], [ok, note, ..events], charges)
      },
    )
  Picture(ledger: list.reverse(rows), events: list.reverse(events), charges:)
}

pub fn charged_text(charges: Int) -> String {
  "Customer charged "
  <> int.to_string(charges)
  <> case charges == 1 {
    True -> " time"
    False -> " times"
  }
}

/// The integers from `low` to `high` inclusive; empty when `high < low`.
fn range(low: Int, high: Int) -> List(Int) {
  case low > high {
    True -> []
    False -> [low, ..range(low + 1, high)]
  }
}
