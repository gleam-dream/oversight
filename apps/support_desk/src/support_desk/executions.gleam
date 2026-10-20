//// Retains ownership of Saga invocations until their terminal report arrives.
//// Fabric can stop a tool body before its independent Saga receiver settles.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/result

pub opaque type Executions {
  Executions(subject: Subject(Message))
}

pub opaque type Invocation {
  Invocation(executions: Executions, id: Int)
}

type Message {
  Started(reply: Subject(Int))
  Finished(Int)
  AwaitIdle(reply: Subject(Nil))
  StopWaiting(reply: Subject(Nil))
  Stop
}

type State {
  State(next: Int, pending: List(Int), waiters: List(Subject(Nil)))
}

pub fn start() -> Result(Executions, String) {
  actor.new(State(1, [], []))
  |> actor.on_message(fn(state, message) {
    case message {
      Started(reply) -> {
        process.send(reply, state.next)
        actor.continue(
          State(..state, next: state.next + 1, pending: [
            state.next,
            ..state.pending
          ]),
        )
      }
      Finished(id) -> {
        let pending = list.filter(state.pending, fn(pending) { pending != id })
        case pending {
          [] -> {
            list.each(state.waiters, fn(reply) { process.send(reply, Nil) })
            actor.continue(State(..state, pending: [], waiters: []))
          }
          _ -> actor.continue(State(..state, pending:))
        }
      }
      AwaitIdle(reply) ->
        case state.pending {
          [] -> {
            process.send(reply, Nil)
            actor.continue(state)
          }
          _ -> actor.continue(State(..state, waiters: [reply, ..state.waiters]))
        }
      StopWaiting(reply) ->
        actor.continue(
          State(
            ..state,
            waiters: list.filter(state.waiters, fn(waiter) { waiter != reply }),
          ),
        )
      Stop -> actor.stop()
    }
  })
  |> actor.start
  |> result.map(fn(started) { Executions(started.data) })
  |> result.replace_error("could not start refund execution ownership")
}

pub fn retain(executions: Executions) -> Invocation {
  Invocation(executions, process.call(executions.subject, 1000, Started))
}

/// Duplicate delivery of a terminal report is harmless.
pub fn release(invocation: Invocation) -> Nil {
  process.send(invocation.executions.subject, Finished(invocation.id))
}

/// Called only after Fabric has stopped every tool body. A missing report
/// or tracker exit remains an explicit failure. Observe cleanup for at most
/// twenty seconds and keep borrowed resources alive if it is unconfirmed.
pub fn await_idle(executions: Executions) -> Result(Nil, String) {
  let assert Ok(pid) = process.subject_owner(executions.subject)
  let monitor = process.monitor(pid)
  let reply = process.new_subject()
  process.send(executions.subject, AwaitIdle(reply))
  let stopped =
    process.new_selector()
    |> process.select_map(reply, fn(_) { Ok(Nil) })
    |> process.select_specific_monitor(monitor, fn(_) {
      Error("refund execution ownership is unavailable")
    })
    |> process.selector_receive(20_000)
    |> result.unwrap(Error("refund execution cleanup is still unconfirmed"))
  process.send(executions.subject, StopWaiting(reply))
  process.demonitor_process(monitor)
  stopped
}

/// Only stop after `await_idle` or before execution has been admitted.
pub fn stop(executions: Executions) -> Nil {
  let assert Ok(pid) = process.subject_owner(executions.subject)
  let monitor = process.monitor(pid)
  process.send(executions.subject, Stop)
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_) { Nil })
  |> process.selector_receive_forever
}
