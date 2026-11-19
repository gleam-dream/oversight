//// The shopping-cart actor of the "Inside an actor" playground: a mailbox of
//// requests, private state, and a handler that takes one request at a time.

import gleam/int
import gleam/list
import site/msc

pub type Caller {
  RequestA
  RequestB
}

/// What a request asks the actor to do. Only `Total` is a call: its caller
/// waits for the reply and sends nothing else until it arrives. The others
/// are sends.
pub type Op {
  Add(name: String, price: Int)
  Remove(name: String)
  Total
}

pub type Request {
  Request(op: Op, from: Caller)
}

pub type Item {
  Item(name: String, price: Int)
}

/// What handling a request did.
pub type Outcome {
  Added(name: String)
  Removed(name: String)
  NotInCart(name: String)
  Replied(total: Int)
}

/// What the handler panel reports.
pub type Last {
  NothingYet
  BurstArrived
  Handled(Request, Outcome)
}

pub type Cart {
  Cart(
    mailbox: List(Request),
    items: List(Item),
    version: Int,
    last: Last,
    events: List(msc.Event),
  )
}

/// Reference charts keep their latest nine events.
const chart_cap = 9

const actor_lane = 2

pub fn new() -> Cart {
  let mailbox = [
    Request(Add("Book", 12), RequestA),
    Request(Add("Mug", 8), RequestA),
    Request(Total, RequestA),
    Request(Remove("Book"), RequestB),
  ]
  Cart(
    mailbox:,
    items: [],
    version: 0,
    last: NothingYet,
    events: list.map(mailbox, arrival),
  )
}

pub fn is_call(request: Request) -> Bool {
  request.op == Total
}

pub fn label(request: Request) -> String {
  case request.op {
    Add(name:, price:) -> "add " <> name <> " €" <> int.to_string(price)
    Remove(name:) -> "remove " <> name
    Total -> "get total"
  }
}

pub fn total(cart: Cart) -> Int {
  list.fold(cart.items, 0, fn(sum, item) { sum + item.price })
}

/// The actor takes the oldest request from its mailbox and handles it.
pub fn handle_next(cart: Cart) -> Cart {
  case cart.mailbox {
    [] -> cart
    [request, ..rest] -> {
      let #(items, outcome) = case request.op {
        Add(name:, price:) -> #(
          list.append(cart.items, [Item(name:, price:)]),
          Added(name),
        )
        Remove(name:) ->
          case remove_first(cart.items, name) {
            Ok(items) -> #(items, Removed(name))
            Error(Nil) -> #(cart.items, NotInCart(name))
          }
        Total -> #(cart.items, Replied(total(cart)))
      }
      let changed = case outcome {
        Added(_) | Removed(_) -> True
        NotInCart(_) | Replied(_) -> False
      }
      let handled = msc.Note(actor_lane, "handles " <> label(request), msc.Blue)
      let reply = case is_call(request) {
        True -> [
          msc.Message(
            actor_lane,
            lane(request.from),
            "reply €" <> int.to_string(total(cart)),
            msc.Green,
            msc.Dashed,
          ),
        ]
        False -> []
      }
      Cart(
        mailbox: rest,
        items:,
        version: case changed {
          True -> cart.version + 1
          False -> cart.version
        },
        last: Handled(request, outcome),
        events: cap(list.flatten([cart.events, [handled], reply])),
      )
    }
  }
}

/// Two requests arrive at the very same instant, from two callers. A caller
/// still waiting for a reply cannot send, so the burst only happens while
/// neither caller has a call in the mailbox.
pub fn burst(cart: Cart) -> Cart {
  case can_burst(cart) {
    False -> cart
    True -> {
      let arrived = [
        Request(Add("Pen", 3), RequestA),
        Request(Total, RequestB),
      ]
      Cart(
        ..cart,
        mailbox: list.append(cart.mailbox, arrived),
        events: cap(list.append(cart.events, list.map(arrived, arrival))),
        last: BurstArrived,
      )
    }
  }
}

/// Whether both callers are free to send: neither waits for a reply.
pub fn can_burst(cart: Cart) -> Bool {
  !list.any(cart.mailbox, is_call)
}

pub fn last_step(last: Last) -> String {
  case last {
    NothingYet -> "Nothing handled yet. Press the button."
    BurstArrived ->
      "Two requests arrived at the same instant. They simply queued up, one behind the other."
    Handled(request, outcome) ->
      "\"" <> label(request) <> "\" → " <> outcome_text(outcome)
  }
}

fn outcome_text(outcome: Outcome) -> String {
  case outcome {
    Added(name) -> "Added " <> name <> ". Nothing replied: it was a send."
    Removed(name) -> "Removed " <> name <> "."
    NotInCart(name) -> "No " <> name <> " in the cart, so nothing changed."
    Replied(total) ->
      "Replied \"€"
      <> int.to_string(total)
      <> "\" to the caller, who was waiting. State unchanged."
  }
}

fn arrival(request: Request) -> msc.Event {
  case request.op {
    Add(name:, ..) ->
      msc.send(lane(request.from), actor_lane, "add " <> name, msc.Ink)
    Remove(name:) ->
      msc.send(lane(request.from), actor_lane, "remove " <> name, msc.Ink)
    Total ->
      msc.send(lane(request.from), actor_lane, "get total (call)", msc.Pink)
  }
}

fn lane(caller: Caller) -> Int {
  case caller {
    RequestA -> 0
    RequestB -> 1
  }
}

fn remove_first(items: List(Item), name: String) -> Result(List(Item), Nil) {
  case items {
    [] -> Error(Nil)
    [item, ..rest] if item.name == name -> Ok(rest)
    [item, ..rest] ->
      case remove_first(rest, name) {
        Ok(rest) -> Ok([item, ..rest])
        Error(Nil) -> Error(Nil)
      }
  }
}

pub fn cap(events: List(msc.Event)) -> List(msc.Event) {
  list.drop(events, list.length(events) - chart_cap)
}
