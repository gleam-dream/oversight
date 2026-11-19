//// The process playground as a pure simulation: a handful of isolated
//// processes with mailboxes, a sender and a recipient, one optional link
//// between cart and payment, a log of what just happened and a trace of the
//// latest events for the sequence chart.

import gleam/int
import gleam/list
import gleam/string

// STATE -----------------------------------------------------------------------

pub type ProcessState {
  /// Alive, with the messages waiting in its mailbox, oldest first.
  Running(mailbox: List(String), handled: Int)
  /// Gone: its memory and mailbox are lost. The count it had stays on show.
  Crashed(handled: Int)
}

pub type Process {
  Process(id: Int, name: String, state: ProcessState)
}

/// The one link the playground offers, between cart and payment.
pub type Link {
  Unlinked
  Linked
}

/// What happened, as the sequence chart draws it. Ids are process ids.
pub type Trace {
  Delivered(from: Int, to: Int, message: String)
  /// Sent to a dead process: the send succeeds and the message is dropped.
  Dropped(from: Int, to: Int, message: String)
  HandledOne(at: Int, message: String)
  CrashedHere(at: Int)
  ExitSignal(from: Int, to: Int)
  DiedToo(at: Int)
  StartedAgain(at: Int)
}

pub type Processes {
  Processes(
    processes: List(Process),
    sender: Int,
    recipient: Int,
    link: Link,
    sent: Int,
    next_id: Int,
    /// Newest first, at most 12 lines.
    log: List(String),
    /// Oldest first, at most the latest 10 events.
    trace: List(Trace),
  )
}

const cart = 1

const payment = 2

const log_cap = 12

const trace_cap = 10

const process_cap = 10

pub fn new() -> Processes {
  Processes(
    processes: list.index_map(
      ["web", "cart", "payment", "mailer", "cache"],
      fn(name, id) { Process(id:, name:, state: Running([], 0)) },
    ),
    sender: 0,
    recipient: 1,
    link: Unlinked,
    sent: 0,
    next_id: 5,
    log: [
      "Five processes started. Each one has its own memory and an empty mailbox.",
    ],
    trace: [],
  )
}

// QUERIES ---------------------------------------------------------------------

/// The message the next send carries; the names cycle.
pub fn next_message(p: Processes) -> String {
  case p.sent % 6 {
    0 -> "add_item"
    1 -> "get_total"
    2 -> "charge"
    3 -> "send_receipt"
    4 -> "ping"
    _ -> "refresh"
  }
}

pub fn find(p: Processes, id: Int) -> Result(Process, Nil) {
  list.find(p.processes, fn(process) { process.id == id })
}

pub fn is_alive(process: Process) -> Bool {
  case process.state {
    Running(..) -> True
    Crashed(..) -> False
  }
}

pub fn mailbox(process: Process) -> List(String) {
  case process.state {
    Running(mailbox:, ..) -> mailbox
    Crashed(..) -> []
  }
}

pub fn handled(process: Process) -> Int {
  count(process.state)
}

fn count(state: ProcessState) -> Int {
  case state {
    Running(handled:, ..) -> handled
    Crashed(handled:) -> handled
  }
}

/// Whether this process is one end of the cart ⇄ payment link.
pub fn is_linked(p: Processes, id: Int) -> Bool {
  p.link == Linked && { id == cart || id == payment }
}

pub fn running_count(p: Processes) -> Int {
  list.count(p.processes, is_alive)
}

/// The processes a reader can send from or to: the five that start.
pub fn choices(p: Processes) -> List(Process) {
  list.take(p.processes, 5)
}

// TRANSITIONS -----------------------------------------------------------------

pub fn pick_sender(p: Processes, id: Int) -> Processes {
  Processes(..p, sender: id)
}

pub fn pick_recipient(p: Processes, id: Int) -> Processes {
  Processes(..p, recipient: id)
}

pub fn send(p: Processes) -> Processes {
  let message = next_message(p)
  case find(p, p.sender), find(p, p.recipient) {
    Ok(from), Ok(to) ->
      case is_alive(from), is_alive(to) {
        False, _ ->
          say(
            p,
            from.name <> " is not running, so it cannot send anything.",
            [],
          )
        True, _ if from.id == to.id ->
          Processes(..deliver(p, to.id, message), sent: p.sent + 1)
          |> say(
            from.name
              <> " sent \""
              <> message
              <> "\" to itself. Allowed, and sometimes useful as a timer.",
            [Delivered(from.id, to.id, message)],
          )
        True, False ->
          Processes(..p, sent: p.sent + 1)
          |> say(
            from.name
              <> " sent \""
              <> message
              <> "\" to "
              <> to.name
              <> ", which is dead. The send still \"succeeds\": the message is silently dropped. Use a monitor or a timeout to notice.",
            [Dropped(from.id, to.id, message)],
          )
        True, True ->
          Processes(..deliver(p, to.id, message), sent: p.sent + 1)
          |> say(
            from.name
              <> " copied \""
              <> message
              <> "\" into "
              <> to.name
              <> "’s mailbox and moved on without waiting.",
            [Delivered(from.id, to.id, message)],
          )
      }
    _, _ -> p
  }
}

fn deliver(p: Processes, id: Int, message: String) -> Processes {
  use state <- update_state(p, id)
  case state {
    Running(mailbox:, handled:) ->
      Running(mailbox: list.append(mailbox, [message]), handled:)
    Crashed(..) -> state
  }
}

/// The process takes its oldest message and handles it.
pub fn handle(p: Processes, id: Int) -> Processes {
  case find(p, id) {
    Ok(Process(name:, state: Running(mailbox: [message, ..rest], handled:), ..)) ->
      update_state(p, id, fn(_) { Running(mailbox: rest, handled: handled + 1) })
      |> say(
        name
          <> " took \""
          <> message
          <> "\" from its mailbox and handled it. Only "
          <> name
          <> " can touch its own state.",
        [HandledOne(id, message)],
      )
    _ -> p
  }
}

pub fn crash(p: Processes, id: Int) -> Processes {
  case find(p, id) {
    Ok(Process(name:, state: Running(mailbox:, ..), ..)) -> {
      let p = update_state(p, id, fn(state) { Crashed(count(state)) })
      let text =
        name
        <> " crashed. Its memory and "
        <> int.to_string(list.length(mailbox))
        <> " queued message(s) are gone. "
      let #(p, text, trace) = case is_linked(p, id) {
        False -> #(p, text, [CrashedHere(id)])
        True -> {
          let other = case id == cart {
            True -> payment
            False -> cart
          }
          case find(p, other) {
            Ok(Process(name: other_name, state: Running(..), ..)) -> #(
              update_state(p, other, fn(state) { Crashed(count(state)) }),
              text
                <> other_name
                <> " was linked, received an exit signal and died too. ",
              [CrashedHere(id), ExitSignal(id, other), DiedToo(other)],
            )
            _ -> #(p, text, [CrashedHere(id)])
          }
        }
      }
      let survivors =
        p.processes
        |> list.filter(is_alive)
        |> list.map(fn(process) { process.name })
      let text =
        text
        <> case survivors {
          [] -> "Nothing is left running."
          _ -> string.join(survivors, ", ") <> " kept running untouched."
        }
      say(p, text, trace)
    }
    _ -> p
  }
}

/// A crashed process starts again, fresh.
pub fn restart(p: Processes, id: Int) -> Processes {
  case find(p, id) {
    Ok(Process(name:, state: Crashed(..), ..)) ->
      update_state(p, id, fn(_) { Running([], 0) })
      |> say(
        name
          <> " started again, fresh: empty mailbox, initial state. In module 2 a supervisor does this for you.",
        [StartedAgain(id)],
      )
    _ -> p
  }
}

pub fn spawn(p: Processes) -> Processes {
  case list.length(p.processes) >= process_cap {
    True ->
      say(
        p,
        "That’s enough for this demo. A real node would happily run a million more.",
        [],
      )
    False -> {
      let id = p.next_id
      let name = "worker-" <> int.to_string(id)
      Processes(
        ..p,
        processes: list.append(p.processes, [
          Process(id:, name:, state: Running([], 0)),
        ]),
        next_id: id + 1,
      )
      |> say(
        "Started " <> name <> " in microseconds, with a few KB of memory.",
        [],
      )
    }
  }
}

pub fn toggle_link(p: Processes) -> Processes {
  case p.link {
    Linked ->
      Processes(..p, link: Unlinked)
      |> say("Unlinked cart and payment. Their fates are separate again.", [])
    Unlinked ->
      Processes(..p, link: Linked)
      |> say("Linked cart ⇄ payment. Now crash one of them.", [])
  }
}

fn update_state(
  p: Processes,
  id: Int,
  change: fn(ProcessState) -> ProcessState,
) -> Processes {
  Processes(
    ..p,
    processes: list.map(p.processes, fn(process) {
      case process.id == id {
        True -> Process(..process, state: change(process.state))
        False -> process
      }
    }),
  )
}

fn say(p: Processes, line: String, events: List(Trace)) -> Processes {
  let trace = list.append(p.trace, events)
  let extra = list.length(trace) - trace_cap
  Processes(
    ..p,
    log: list.take([line, ..p.log], log_cap),
    trace: case extra > 0 {
      True -> list.drop(trace, extra)
      False -> trace
    },
  )
}
