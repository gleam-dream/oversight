//// The desk's in-memory refund ledger: one actor, append and remove.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/result

pub type Entry {
  Entry(id: Int, order_id: String, refund_id: String, amount_cents: Int)
}

pub opaque type Ledger {
  Ledger(subject: Subject(Message))
}

type Message {
  Append(
    order_id: String,
    refund_id: String,
    amount_cents: Int,
    reply: Subject(Int),
  )
  Remove(id: Int, reply: Subject(Bool))
  Entries(reply: Subject(List(Entry)))
}

type State {
  State(next: Int, entries: List(Entry))
}

pub fn start() -> Result(Ledger, String) {
  actor.new(State(1, []))
  |> actor.on_message(fn(state: State, message) {
    case message {
      Append(order_id, refund_id, amount, reply) -> {
        process.send(reply, state.next)
        let entry = Entry(state.next, order_id, refund_id, amount)
        actor.continue(State(state.next + 1, [entry, ..state.entries]))
      }
      Remove(id, reply) -> {
        let kept = list.filter(state.entries, fn(entry) { entry.id != id })
        process.send(reply, list.length(kept) != list.length(state.entries))
        actor.continue(State(..state, entries: kept))
      }
      Entries(reply) -> {
        process.send(reply, list.reverse(state.entries))
        actor.continue(state)
      }
    }
  })
  |> actor.start
  |> result.map(fn(started) { Ledger(started.data) })
  |> result.replace_error("could not start the ledger")
}

pub fn append(
  ledger: Ledger,
  order_id: String,
  refund_id: String,
  amount_cents: Int,
) -> Int {
  process.call(ledger.subject, 1000, Append(
    order_id,
    refund_id,
    amount_cents,
    _,
  ))
}

/// Removes an entry; `False` when it was not there.
pub fn remove(ledger: Ledger, id: Int) -> Bool {
  process.call(ledger.subject, 1000, Remove(id, _))
}

pub fn entries(ledger: Ledger) -> List(Entry) {
  process.call(ledger.subject, 1000, Entries)
}
