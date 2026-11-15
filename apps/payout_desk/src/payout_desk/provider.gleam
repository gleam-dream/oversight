//// The payment provider, scripted locally: an actor that pays a seller at
//// most once per idempotency key and answers lookups by that key. It
//// stands for an outside system, so it is started apart from the
//// application and outlives the application's restarts.
////
//// `script` queues how the next payments are answered: paid and answered,
//// declined, or paid with the answer lost (the caller times out).

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/result

pub type Provider {
  Provider(subject: Subject(Message))
}

/// How the provider answers one payment request.
pub type Behaviour {
  /// Pays and answers with a receipt.
  Answer
  /// Does not pay, and says why.
  Decline(reason: String)
  /// Pays, and its answer never arrives.
  AnswerLost
}

pub type PayError {
  Declined(reason: String)
  /// No answer within the caller's deadline. The payment may have been made.
  TimedOut
}

pub type Lookup {
  Found(receipt: String)
  NotFound
}

/// How often each key was asked to pay, how often it was looked up, and
/// how many payments the provider made under it (never more than one).
pub type Counts {
  Counts(pay_requests: Int, lookups: Int, payments: Int)
}

pub opaque type Message {
  Pay(key: String, amount_cents: Int, reply: Subject(Result(String, PayError)))
  LookUp(key: String, reply: Subject(Lookup))
  Script(behaviours: List(Behaviour))
  CountsOf(key: String, reply: Subject(Counts))
}

type State {
  State(
    script: List(Behaviour),
    paid: Dict(String, #(String, Int)),
    counts: Dict(String, Counts),
  )
}

pub fn start() -> Result(Provider, actor.StartError) {
  actor.new(State(script: [], paid: dict.new(), counts: dict.new()))
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { Provider(started.data) })
}

pub fn stop(provider: Provider) -> Nil {
  case process.subject_owner(provider.subject) {
    Ok(pid) -> {
      process.unlink(pid)
      process.kill(pid)
    }
    Error(Nil) -> Nil
  }
}

/// Answer the next payment requests this way, in order; after them, pay
/// and answer.
pub fn script(provider: Provider, behaviours: List(Behaviour)) -> Nil {
  process.send(provider.subject, Script(behaviours))
}

/// Ask for a payment under `key`. A key already paid answers with its
/// first receipt and pays nothing more.
pub fn pay(
  provider: Provider,
  key key: String,
  amount_cents amount_cents: Int,
  within within: Int,
) -> Result(String, PayError) {
  let reply = process.new_subject()
  process.send(provider.subject, Pay(key:, amount_cents:, reply:))
  process.receive(reply, within)
  |> result.replace_error(TimedOut)
  |> result.flatten
}

/// What the provider holds under `key`.
pub fn lookup(provider: Provider, key: String) -> Lookup {
  process.call(provider.subject, 1000, LookUp(key, _))
}

pub fn counts(provider: Provider, key: String) -> Counts {
  process.call(provider.subject, 1000, CountsOf(key, _))
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Script(behaviours) ->
      actor.continue(
        State(..state, script: list.append(state.script, behaviours)),
      )
    CountsOf(key:, reply:) -> {
      process.send(reply, counted(state, key))
      actor.continue(state)
    }
    LookUp(key:, reply:) -> {
      let state =
        count(state, key, fn(c) { Counts(..c, lookups: c.lookups + 1) })
      process.send(reply, case dict.get(state.paid, key) {
        Ok(#(receipt, _)) -> Found(receipt)
        Error(Nil) -> NotFound
      })
      actor.continue(state)
    }
    Pay(key:, amount_cents:, reply:) -> {
      let state =
        count(state, key, fn(c) {
          Counts(..c, pay_requests: c.pay_requests + 1)
        })
      let #(behaviour, script) = case state.script {
        [next, ..rest] -> #(next, rest)
        [] -> #(Answer, [])
      }
      let state = State(..state, script:)
      case behaviour {
        Decline(reason) -> {
          process.send(reply, Error(Declined(reason)))
          actor.continue(state)
        }
        Answer | AnswerLost -> {
          let #(receipt, state) = paid(state, key, amount_cents)
          case behaviour {
            Answer -> process.send(reply, Ok(receipt))
            _ -> Nil
          }
          actor.continue(state)
        }
      }
    }
  }
}

fn paid(state: State, key: String, amount_cents: Int) -> #(String, State) {
  case dict.get(state.paid, key) {
    Ok(#(receipt, _)) -> #(receipt, state)
    Error(Nil) -> {
      let receipt = "rcpt-" <> int.to_string(dict.size(state.paid) + 1001)
      let state =
        State(
          ..state,
          paid: dict.insert(state.paid, key, #(receipt, amount_cents)),
        )
      #(
        receipt,
        count(state, key, fn(c) { Counts(..c, payments: c.payments + 1) }),
      )
    }
  }
}

fn counted(state: State, key: String) -> Counts {
  dict.get(state.counts, key) |> result.unwrap(Counts(0, 0, 0))
}

fn count(state: State, key: String, change: fn(Counts) -> Counts) -> State {
  State(
    ..state,
    counts: dict.insert(state.counts, key, change(counted(state, key))),
  )
}
