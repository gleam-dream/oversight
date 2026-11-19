//// The "send or call" mailbox under load, as a pure simulation. Four request
//// processes talk to one actor that handles a message in 250 ms. Messages
//// and replies travel for 0.4 s. Sends go out at the reader's rate whatever
//// the actor does; a call blocks its caller until the reply is back, even
//// if the reader switches to sends meanwhile.
////
//// Time is in seconds. The arithmetic follows the reference widget step for
//// step, so the same frames give the same picture.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

pub type Mode {
  /// Fire and forget.
  Send
  /// Wait for the reply before sending again.
  Call
}

pub type TokenState {
  /// On its way to the mailbox.
  Flying(since: Float)
  /// Waiting in the mailbox. `shown_x` is where the picture last drew it, so
  /// it can slide forward smoothly as the queue moves.
  Queued(since: Float, shown_x: Option(Float))
  /// Being handled by the actor.
  Working(since: Float)
  /// A call's reply on its way back to the caller.
  Replying(since: Float)
  /// A handled send, fading out.
  Done(since: Float)
}

pub type Token {
  Token(id: Int, caller: Int, kind: Mode, state: TokenState)
}

pub type Sim {
  Sim(
    clock: Float,
    next_send: Float,
    /// Every live token, oldest first.
    tokens: List(Token),
    sent: Int,
    handled: Int,
    last_id: Int,
  )
}

pub const callers = 4

/// How long the actor takes per message.
pub const service = 0.25

/// How long a message or reply travels.
pub const travel = 0.4

/// How long a handled send stays visible.
pub const fade = 0.35

pub fn new() -> Sim {
  Sim(clock: 0.0, next_send: 0.0, tokens: [], sent: 0, handled: 0, last_id: 0)
}

/// Advance the simulation by `dt` seconds.
pub fn step(sim: Sim, dt: Float, mode: Mode, rate: Int) -> Sim {
  let clock = sim.clock +. dt
  let sim = emit(Sim(..sim, clock:), mode, rate)
  let tokens = list.filter_map(sim.tokens, arrive(_, clock))
  let #(finished, tokens) = finish(tokens, clock)
  let tokens =
    start(tokens, clock)
    |> list.filter(fn(token) {
      case token.state {
        Done(since) -> clock -. since <=. fade
        _ -> True
      }
    })
  Sim(..sim, tokens:, handled: sim.handled + finished)
}

/// One second in twenty steps, as the "Advance 1 second" button runs it.
pub fn advance_second(sim: Sim, mode: Mode, rate: Int) -> Sim {
  list.fold(list.repeat(Nil, 20), sim, fn(sim, _) {
    step(sim, 0.05, mode, rate)
  })
  |> settle
}

fn emit(sim: Sim, mode: Mode, rate: Int) -> Sim {
  case sim.clock >=. sim.next_send {
    False -> sim
    True ->
      case mode, next_free(sim, mode) {
        // Every caller waits for a reply: the launch waits too.
        _, Error(Nil) -> Sim(..sim, next_send: sim.clock)
        _, Ok(caller) -> launch(sim, caller, mode, rate)
      }
  }
}

fn launch(sim: Sim, caller: Int, kind: Mode, rate: Int) -> Sim {
  let id = sim.last_id + 1
  Sim(
    ..sim,
    tokens: list.append(sim.tokens, [
      Token(id:, caller:, kind:, state: Flying(sim.clock)),
    ]),
    sent: sim.sent + 1,
    last_id: id,
    next_send: sim.clock +. 1.0 /. int.to_float(int.max(rate, 1)),
  )
}

fn arrive(token: Token, clock: Float) -> Result(Token, Nil) {
  case token.state {
    Flying(since) if clock -. since >=. travel ->
      Ok(Token(..token, state: Queued(since: clock, shown_x: None)))
    Replying(since) if clock -. since >=. travel -> Error(Nil)
    _ -> Ok(token)
  }
}

/// The actor finishes its message once the service time is up.
fn finish(tokens: List(Token), clock: Float) -> #(Int, List(Token)) {
  list.map_fold(tokens, 0, fn(finished, token) {
    case token.state {
      Working(since) if clock -. since >=. service -> #(
        finished + 1,
        Token(..token, state: case token.kind {
          Call -> Replying(clock)
          Send -> Done(clock)
        }),
      )
      _ -> #(finished, token)
    }
  })
}

/// An idle actor takes the oldest queued message.
fn start(tokens: List(Token), clock: Float) -> List(Token) {
  case busy_in(tokens) {
    Some(_) -> tokens
    None ->
      list.map_fold(tokens, False, fn(taken, token) {
        case taken, token.state {
          False, Queued(..) -> #(True, Token(..token, state: Working(clock)))
          _, _ -> #(taken, token)
        }
      }).1
  }
}

/// Slide each visible queued message a quarter of the way to its slot.
pub fn settle(sim: Sim) -> Sim {
  let #(_, tokens) =
    list.map_fold(sim.tokens, 0, fn(index, token) {
      case token.state {
        Queued(since:, shown_x:) -> {
          let shown_x = case index > visible_slots {
            True -> shown_x
            False -> {
              let target = slot_x(index)
              case shown_x {
                None -> Some(target)
                Some(x) -> Some(x +. { target -. x } *. 0.25)
              }
            }
          }
          #(index + 1, Token(..token, state: Queued(since:, shown_x:)))
        }
        _ -> #(index, token)
      }
    })
  Sim(..sim, tokens:)
}

// QUERIES ---------------------------------------------------------------------

/// Queued messages beyond this index are not drawn.
pub const visible_slots = 10

/// Where the queued message at `index` sits; the head is nearest the actor.
pub fn slot_x(index: Int) -> Float {
  622.0 -. int.to_float(index) *. 19.0
}

/// The messages waiting in the mailbox, oldest first.
pub fn queue(sim: Sim) -> List(Token) {
  list.filter(sim.tokens, fn(token) {
    case token.state {
      Queued(..) -> True
      _ -> False
    }
  })
}

pub fn waiting(sim: Sim) -> Int {
  list.length(queue(sim))
}

/// How long the oldest waiting message has waited.
pub fn oldest_wait(sim: Sim) -> Float {
  case queue(sim) {
    [Token(state: Queued(since:, ..), ..), ..] -> sim.clock -. since
    _ -> 0.0
  }
}

/// The message the actor is handling, if any.
pub fn busy(sim: Sim) -> Option(Token) {
  busy_in(sim.tokens)
}

fn busy_in(tokens: List(Token)) -> Option(Token) {
  list.find(tokens, fn(token) {
    case token.state {
      Working(..) -> True
      _ -> False
    }
  })
  |> option.from_result
}

/// Whether each caller is blocked on an outstanding call.
pub fn blocked(sim: Sim) -> List(Bool) {
  list.map([0, 1, 2, 3], fn(caller) {
    list.any(sim.tokens, fn(token) {
      token.caller == caller && token.kind == Call
    })
  })
}

/// The caller that sends next, skipping callers blocked on a call. Calls
/// go from the first free caller; sends take turns, starting from the
/// caller whose turn it is.
fn next_free(sim: Sim, mode: Mode) -> Result(Int, Nil) {
  let first = case mode {
    Call -> 0
    Send -> sim.sent % callers
  }
  let blocked = blocked(sim)
  list.map([0, 1, 2, 3], fn(turn) { { first + turn } % callers })
  |> list.find(fn(caller) {
    list.drop(blocked, caller) |> list.first != Ok(True)
  })
}
