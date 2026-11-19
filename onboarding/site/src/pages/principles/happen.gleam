//// "Did it happen?": charge a card, break the network at a chosen moment,
//// then retry with or without an idempotency key. The provider keeps an
//// idempotency ledger, and a sequence chart shows request, effect and reply.

import gleam/int
import gleam/list
import gleam/pair
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

/// What the note asks of the reader while no retry is shown.
pub type Prompt {
  AskForAMoment
  AskForARetry
}

/// The sentence beside the retry button, derived from the state by `note`.
pub type Note {
  ChooseAMoment
  ConnectionDrops(Break)
  Retry(Verdict)
}

pub type Verdict {
  /// A definite answer was already in hand; a keyless retry is a new charge.
  AlreadyAnswered
  /// The key matched a stored answer, so the retry charged nothing new.
  SameKeyReplaysAnswer
  SafeBecauseNotSent
  KeyReplayedOriginal
  KeyChargedNow
  /// A keyless retry charged the card again: `times` charges in all.
  ChargedAgain(times: Int)
  GotLucky
}

/// What one retry did at the provider.
pub type Outcome {
  /// The key matched a stored result, which the provider replayed.
  Replayed
  /// The card was charged for the first time.
  ChargedFirst
  /// The card was charged once more: `times` charges in all.
  ChargedExtra(times: Int)
}

pub type Happen {
  Happen(
    at: Break,
    curtain: Curtain,
    key: Key,
    retries: Retries,
    prompt: Prompt,
  )
}

pub fn initial() -> Happen {
  Happen(
    at: WhileSending,
    curtain: Hidden,
    key: WithoutKey,
    retries: NoRetries,
    prompt: AskForAMoment,
  )
}

// TRANSITIONS -----------------------------------------------------------------

pub fn break_at(happen: Happen, at: Break) -> Happen {
  Happen(..happen, at:, curtain: Hidden, prompt: AskForARetry)
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
  Happen(
    ..happen,
    retries: Retried(
      at: happen.at,
      key: happen.key,
      count: retries_shown(happen) + 1,
    ),
    prompt: AskForARetry,
  )
}

/// Retries made under the current break and key.
pub fn retries_shown(happen: Happen) -> Int {
  case happen.retries {
    Retried(at:, key:, count:) if at == happen.at && key == happen.key -> count
    _ -> 0
  }
}

/// What each retry shown did at the provider, oldest first. The ledger and
/// the note both read it, so they always agree.
pub fn outcomes(happen: Happen) -> List(Outcome) {
  let keyed = happen.key == WithKey
  list.repeat(Nil, retries_shown(happen))
  |> list.map_fold(charges_before_retry(happen.at), fn(charges, _) {
    case keyed && charges > 0, charges + 1 {
      True, _ -> #(charges, Replayed)
      False, 1 -> #(1, ChargedFirst)
      False, times -> #(times, ChargedExtra(times))
    }
  })
  |> pair.second
}

/// The note for the latest retry shown, or a prompt when none is shown.
pub fn note(happen: Happen) -> Note {
  case list.last(outcomes(happen)), happen.prompt {
    Ok(outcome), _ -> Retry(verdict(happen, outcome))
    Error(Nil), AskForAMoment -> ChooseAMoment
    Error(Nil), AskForARetry -> ConnectionDrops(happen.at)
  }
}

fn verdict(happen: Happen, outcome: Outcome) -> Verdict {
  case outcome, happen.at, happen.key {
    Replayed, WhileProviderWorks, _ | Replayed, WhileReplyTravels, _ ->
      KeyReplayedOriginal
    Replayed, _, _ -> SameKeyReplaysAnswer
    ChargedFirst, WhileConnecting, _ -> SafeBecauseNotSent
    ChargedFirst, _, WithKey -> KeyChargedNow
    ChargedFirst, _, WithoutKey -> GotLucky
    ChargedExtra(times: 2), Never, _ -> AlreadyAnswered
    ChargedExtra(times:), _, _ -> ChargedAgain(times:)
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

/// How many times the provider charged the card before any retry.
pub fn charges_before_retry(at: Break) -> Int {
  case at {
    Never | WhileProviderWorks | WhileReplyTravels -> 1
    WhileConnecting | WhileSending -> 0
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
    Retry(ChargedAgain(times: 2)) ->
      "Retried without a key. The provider saw a brand-new request: the customer is now charged TWICE."
    Retry(ChargedAgain(times:)) ->
      "Retried without a key. The provider saw a brand-new request: the customer is now charged "
      <> int.to_string(times)
      <> " times."
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
  let charged = charges_before_retry(happen.at)
  let first =
    Row(
      request: "#1",
      key:,
      tone: case charged {
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
  let arrives = [
    msc.send(0, 2, "POST /charges" <> with_key, msc.Ink),
    msc.Note(2, "charges the card", msc.Pink),
  ]
  let events = case happen.at {
    WhileConnecting -> [
      msc.Lost(0, 1, "connect", msc.Grey),
      msc.Note(0, "NotSent", msc.Blue),
    ]
    WhileSending -> [msc.Lost(0, 2, "POST /charges", msc.Ink), maybe]
    Never -> list.append(arrives, [ok])
    // The line dies at the provider, mid-work: no reply is ever sent.
    WhileProviderWorks ->
      list.append(arrives, [msc.Lost(2, 2, "connection lost", msc.Grey), maybe])
    WhileReplyTravels ->
      list.append(arrives, [msc.Lost(2, 0, "reply", msc.Grey), maybe])
  }
  let retry_label = case keyed {
    True -> "retry + same key"
    False -> "retry"
  }
  let outcomes = outcomes(happen)
  let #(rows, events) =
    list.index_fold(
      outcomes,
      #([first], list.reverse(events)),
      fn(acc, outcome, i) {
        let #(rows, events) = acc
        let request = "#" <> int.to_string(i + 2)
        let #(row, note) = case outcome {
          Replayed -> #(
            Row(
              request:,
              key:,
              tone: Charged,
              result: "key seen before → stored response replayed, no new charge",
            ),
            msc.Note(2, "replays stored result", msc.Green),
          )
          ChargedFirst -> #(
            Row(request:, key:, tone: Charged, result: "card charged · ch_1"),
            msc.Note(2, "charges the card", msc.Pink),
          )
          ChargedExtra(times:) -> #(
            Row(
              request:,
              key:,
              tone: Double,
              result: "NEW charge · ch_" <> int.to_string(times),
            ),
            msc.Note(2, "charges AGAIN", msc.Red),
          )
        }
        let events = [msc.send(0, 2, retry_label, msc.Ink), ..events]
        #([row, ..rows], [ok, note, ..events])
      },
    )
  let charges =
    list.fold(outcomes, charged, fn(charges, outcome) {
      case outcome {
        Replayed -> charges
        ChargedFirst -> 1
        ChargedExtra(times:) -> times
      }
    })
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
