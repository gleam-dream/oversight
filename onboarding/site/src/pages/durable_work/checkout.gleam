//// The Saga checkout: reserve stock and run a fraud check in parallel, then
//// charge, then ship. The reader chooses how each step behaves; a run is the
//// list of events the coordinator would record, shown one at a time.

import gleam/list
import gleam/option.{type Option, None, Some}

pub type Step {
  Reserve
  Fraud
  Charge
  Ship
}

pub type StepState {
  Idle
  Running
  Done
  Failed
  Undone
  Unknown
  Held
  Skipped
}

pub type Stock {
  InStock
  OutOfStock
}

pub type Screening {
  Clear
  Flagged
}

pub type Payment {
  Paid
  Declined
  UnknownThenPaid
  StaysUnknown
}

pub type Shipping {
  Booked
  CarrierRejects
}

/// How each step behaves in this run.
pub type Plan {
  Plan(stock: Stock, screening: Screening, payment: Payment, shipping: Shipping)
}

pub const happy =
  Plan(stock: InStock, screening: Clear, payment: Paid, shipping: Booked)

pub type Crash {
  NoCrash
  CrashAfterCharge
}

pub type Durability {
  /// Checkpoints after every step; a crashed run resumes.
  Durable
  /// The run lives and dies with its caller.
  Local
}

pub type Outcome {
  Completed
  Aborted(reason: String)
  HeldForReconciliation
  Lost
}

pub type Event {
  Event(set: List(#(Step, StepState)), log: String, outcome: Option(Outcome))
}

/// What the coordinator records for this plan, in order.
pub fn events(plan: Plan, crash: Crash, durability: Durability) -> List(Event) {
  let ev = fn(set, log) { Event(set:, log:, outcome: None) }
  let end = fn(set, log, outcome) { Event(set:, log:, outcome: Some(outcome)) }
  let start = [
    ev(
      [#(Reserve, Running), #(Fraud, Running)],
      "Coordinator starts both ready steps at once: they don’t depend on each other.",
    ),
    ev(
      [
        #(Reserve, case plan.stock {
          InStock -> Done
          OutOfStock -> Failed
        }),
        #(Fraud, case plan.screening {
          Clear -> Done
          Flagged -> Failed
        }),
      ],
      case plan.stock {
        InStock -> "Reserve: stock held (hold-o-1)."
        OutOfStock -> "Reserve: Error(OutOfStock)."
      }
        <> " "
        <> case plan.screening {
        Clear -> "Fraud check: clear."
        Flagged -> "Fraud check: flagged."
      },
    ),
  ]
  case plan.stock, plan.screening {
    InStock, Clear -> list.append(start, after_checks(plan, crash, durability))
    _, _ -> {
      let release = case plan.stock {
        InStock -> [
          ev(
            [#(Reserve, Undone)],
            "Undo journal: release hold-o-1. The fraud check was read-only, so it has nothing to undo.",
          ),
        ]
        OutOfStock -> []
      }
      let reason = case plan.stock {
        OutOfStock -> "OutOfStock"
        InStock -> "flagged"
      }
      list.flatten([
        start,
        release,
        [
          end(
            [#(Charge, Skipped), #(Ship, Skipped)],
            "Charge and ship never start: their inputs never arrived.",
            Aborted(reason),
          ),
        ],
      ])
    }
  }
}

fn after_checks(
  plan: Plan,
  crash: Crash,
  durability: Durability,
) -> List(Event) {
  let ev = fn(set, log) { Event(set:, log:, outcome: None) }
  let end = fn(set, log, outcome) { Event(set:, log:, outcome: Some(outcome)) }
  let charging =
    ev(
      [#(Charge, Running)],
      "Charge payment with idempotency key checkout:o-1:charge. Every attempt reuses it.",
    )
  let uncertain = [
    ev(
      [#(Charge, Unknown)],
      "Charge: connection lost. MaybeCharged is marked \"unknown\". Policy: RetryAfter 500 ms with the same key.",
    ),
    ev([#(Charge, Running)], "Attempt 2, same idempotency key."),
  ]
  case plan.payment {
    Declined -> [
      charging,
      ev(
        [#(Charge, Failed)],
        "Charge: Error(Declined). A known failure: nothing was taken.",
      ),
      end(
        [#(Reserve, Undone), #(Ship, Skipped)],
        "Undo journal, newest first: release hold-o-1.",
        Aborted("Declined"),
      ),
    ]
    StaysUnknown ->
      list.flatten([
        [charging],
        uncertain,
        [
          ev(
            [#(Charge, Unknown)],
            "Attempt 2: still unknown. Attempt 3: still unknown.",
          ),
          end(
            [#(Charge, Held), #(Ship, Skipped)],
            "Policy answers Hold(MaybeCharged). Nothing is undone: releasing stock for an order that may be paid would be wrong. Your app checks the provider by key and resolves it.",
            HeldForReconciliation,
          ),
        ],
      ])
    UnknownThenPaid ->
      list.flatten([
        [charging],
        uncertain,
        [
          ev(
            [#(Charge, Done)],
            "The provider recognised the key and returned the original result: charged exactly once.",
          ),
        ],
        after_charge(plan, crash, durability),
      ])
    Paid ->
      list.flatten([
        [
          charging,
          ev([#(Charge, Done)], "Charge: receipt-checkout:o-1:charge."),
        ],
        after_charge(plan, crash, durability),
      ])
  }
}

fn after_charge(
  plan: Plan,
  crash: Crash,
  durability: Durability,
) -> List(Event) {
  let ev = fn(set, log) { Event(set:, log:, outcome: None) }
  let end = fn(set, log, outcome) { Event(set:, log:, outcome: Some(outcome)) }
  let shipping = [
    ev([#(Ship, Running)], "Book shipment."),
    ..case plan.shipping {
      Booked -> [
        end(
          [#(Ship, Done)],
          "Shipment booked. Every step succeeded.",
          Completed,
        ),
      ]
      CarrierRejects -> [
        ev([#(Ship, Failed)], "Ship: the carrier rejected the booking."),
        ev(
          [#(Charge, Undone)],
          "Undo journal, newest first: refund the charge (with its own idempotency key).",
        ),
        end(
          [#(Reserve, Undone)],
          "Then release hold-o-1.",
          Aborted("compensated"),
        ),
      ]
    }
  ]
  case crash, durability {
    NoCrash, _ -> shipping
    CrashAfterCharge, Durable -> [
      ev(
        [#(Ship, Idle)],
        "NODE CRASHED. The checkpoint says reserve, fraud and charge are complete. On restart, if replay is enabled for the job driving this saga or an operator authorizes it, Grind redelivers that job; the saga reconnects by execution id and resumes. The charge is not repeated.",
      ),
      ..shipping
    ]
    CrashAfterCharge, Local -> [
      end(
        [#(Ship, Skipped)],
        "NODE CRASHED. A local run lives and dies with its caller: stock is held, the card is charged, nothing ships, and no record says where it stopped.",
        Lost,
      ),
    ]
  }
}

/// Where the run stands after the events up to `upto` (inclusive).
pub type Progress {
  NotStarted
  InFlight
  Finished(Outcome)
}

pub type Snapshot {
  Snapshot(
    reserve: StepState,
    fraud: StepState,
    charge: StepState,
    ship: StepState,
    progress: Progress,
    /// Newest first.
    log: List(String),
  )
}

const idle =
  Snapshot(
    reserve: Idle,
    fraud: Idle,
    charge: Idle,
    ship: Idle,
    progress: NotStarted,
    log: [],
  )

/// Replay the first `upto + 1` events; a negative `upto` shows nothing yet.
pub fn snapshot(events: List(Event), upto: Int) -> Snapshot {
  case upto < 0 {
    True -> idle
    False ->
      list.take(events, upto + 1)
      |> list.fold(Snapshot(..idle, progress: InFlight), fn(snap, event) {
        let snap =
          list.fold(event.set, snap, fn(snap, change) {
            case change {
              #(Reserve, state) -> Snapshot(..snap, reserve: state)
              #(Fraud, state) -> Snapshot(..snap, fraud: state)
              #(Charge, state) -> Snapshot(..snap, charge: state)
              #(Ship, state) -> Snapshot(..snap, ship: state)
            }
          })
        let progress = case event.outcome {
          Some(outcome) -> Finished(outcome)
          None -> snap.progress
        }
        Snapshot(..snap, progress:, log: [event.log, ..snap.log])
      })
  }
}

pub fn state_of(snapshot: Snapshot, step: Step) -> StepState {
  case step {
    Reserve -> snapshot.reserve
    Fraud -> snapshot.fraud
    Charge -> snapshot.charge
    Ship -> snapshot.ship
  }
}

pub fn outcome_text(outcome: Outcome) -> String {
  case outcome {
    Completed -> "Completed"
    Aborted(reason) -> "Aborted: " <> reason
    HeldForReconciliation -> "Held for reconciliation"
    Lost -> "Lost: use durable mode"
  }
}
