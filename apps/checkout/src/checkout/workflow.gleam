//// The checkout saga: reserve stock (pog), charge the card (payments API),
//// book the shipment (shipping API). One definition serves both the local
//// run behind `POST /orders` and the durable run driven by a grind job.
////
//// Provider idempotency keys are derived from the order id, not from saga's
//// effect keys: saga gives every retry a distinct attempt key, and in local
//// runs the key embeds a per-run integer, so it cannot dedupe a retried
//// charge at the provider.

import checkout/codecs
import checkout/db
import checkout/domain.{
  type Booked, type Charged, type CheckoutError, type OrderRequest,
  type Reserved, type UndoError, Booked, Charged, Interrupted, Reserved,
  UndoError,
}
import checkout/gateway.{type Gateway}
import gleam/result
import http_gun
import pog
import saga.{type Step, type Workflow}
import saga/durable

pub type Deps {
  Deps(
    pool: pog.Connection,
    gateway: Gateway,
    /// The http_gun client view to use for one order (correlated).
    client_for: fn(String) -> http_gun.Client,
    /// Total charge attempts when the payment outcome is unknown.
    charge_attempts: Int,
  )
}

pub type Checkout =
  Workflow(OrderRequest, Booked, CheckoutError, UndoError)

pub fn payment_key(order: OrderRequest) -> String {
  "pay-" <> order.order_id
}

pub fn shipment_key(order: OrderRequest) -> String {
  "ship-" <> order.order_id
}

pub fn define(deps: Deps) -> Checkout {
  let assert Ok(workflow) =
    saga.define("checkout", fn(input) {
      input
      |> saga.perform(reserve_stock(deps))
      |> saga.perform(charge_card(deps))
      |> saga.perform(book_shipment(deps))
    })
  workflow
}

pub fn persistence(
  workflow: Checkout,
) -> durable.Persistence(OrderRequest, Booked, CheckoutError, UndoError) {
  let assert Ok(persistence) =
    durable.prepare(
      workflow,
      "1",
      codecs.to_saga(codecs.order()),
      codecs.to_saga(codecs.booked()),
      codecs.to_saga(codecs.checkout_error()),
      codecs.to_saga(codecs.undo_error()),
    )
  persistence
}

fn reserve_stock(
  deps: Deps,
) -> Step(OrderRequest, Reserved, CheckoutError, UndoError) {
  saga.step("reserve_stock", fn(order: OrderRequest) {
    db.reserve(deps.pool, order) |> result.replace(Reserved(order))
  })
  |> saga.undo(fn(order, _reserved) {
    db.release(deps.pool, order.order_id)
    |> result.map_error(UndoError("reserve_stock", _))
  })
  |> saga.recoverable(
    "1",
    codecs.to_saga(codecs.order()),
    codecs.to_saga(codecs.reserved()),
    fn(order, _key) {
      case db.reservation(deps.pool, order.order_id) {
        Ok(db.Absent) -> saga.EffectAbsent
        Ok(_) -> saga.EffectCompleted(Reserved(order))
        Error(_) -> saga.EffectUnknown
      }
    },
  )
}

fn charge_card(
  deps: Deps,
) -> Step(Reserved, Charged, CheckoutError, UndoError) {
  let void = fn(reserved: Reserved, charged: Charged) {
    gateway.void(
      deps.gateway,
      deps.client_for(reserved.order.order_id),
      charged.charge_id,
    )
    |> result.map_error(UndoError("charge_card", _))
  }
  let lookup = fn(reserved: Reserved) {
    gateway.find_charge(
      deps.gateway,
      deps.client_for(reserved.order.order_id),
      payment_key(reserved.order),
    )
  }
  saga.step("charge_card", fn(reserved: Reserved) {
    let order = reserved.order
    gateway.charge(
      deps.gateway,
      deps.client_for(order.order_id),
      order,
      payment_key(order),
    )
    |> result.map(Charged(reserved, _))
  })
  |> saga.undo(void)
  // An unknown payment outcome is a typed error to saga, so saga's
  // `unknown_effects` never sees it. The decider retries under the same
  // provider idempotency key, and holds (no rollback) when attempts run out.
  |> saga.compensate(
    max_attempts: deps.charge_attempts,
    with: fn(_reserved, failure, attempt) {
      case failure {
        saga.Returned(error) ->
          case domain.effect_uncertain(error), attempt.remaining > 0 {
            True, True -> saga.Retry
            True, False -> saga.Hold(error)
            False, _ -> saga.Abort(error)
          }
        saga.Crashed(_) | saga.TimedOut ->
          case attempt.remaining > 0 {
            True -> saga.Retry
            False -> saga.Hold(Interrupted("charge_card"))
          }
      }
    },
  )
  |> saga.restore_undo(fn(reserved, charged, _key) {
    saga.UndoWith(fn() { void(reserved, charged) })
  })
  |> saga.reconcile_compensation(fn(reserved, _attempt, _key) {
    case lookup(reserved) {
      Ok(gateway.ChargeFound(id, False)) -> {
        let charged = Charged(reserved, id)
        saga.CompensationResolved(saga.Continue(
          charged,
          saga.UndoWith(fn() { void(reserved, charged) }),
        ))
      }
      Ok(_) -> saga.CompensationResolved(saga.Retry)
      Error(_) -> saga.CompensationUnknown
    }
  })
  |> saga.recoverable(
    "1",
    codecs.to_saga(codecs.reserved()),
    codecs.to_saga(codecs.charged()),
    fn(reserved, _key) {
      case lookup(reserved) {
        Ok(gateway.ChargeFound(id, _)) ->
          saga.EffectCompleted(Charged(reserved, id))
        Ok(gateway.NoCharge) -> saga.EffectAbsent
        Error(_) -> saga.EffectUnknown
      }
    },
  )
}

fn book_shipment(
  deps: Deps,
) -> Step(Charged, Booked, CheckoutError, UndoError) {
  let client = fn(charged: Charged) {
    deps.client_for(charged.reserved.order.order_id)
  }
  let cancel = fn(charged: Charged) {
    gateway.cancel_shipment(
      deps.gateway,
      client(charged),
      shipment_key(charged.reserved.order),
    )
  }
  saga.step("book_shipment", fn(charged: Charged) {
    let order = charged.reserved.order
    gateway.book(deps.gateway, client(charged), order, shipment_key(order))
    |> result.map(Booked(charged, _))
  })
  // A shipment request that timed out may still have been booked. Saga only
  // undoes steps that succeeded, so cancelling a possibly-booked shipment
  // is this step's own compensation cleanup.
  |> saga.compensate(max_attempts: 1, with: fn(charged, failure, _attempt) {
    let error = case failure {
      saga.Returned(error) -> error
      saga.Crashed(_) | saga.TimedOut -> Interrupted("book_shipment")
    }
    case
      domain.effect_uncertain(error) || error == Interrupted("book_shipment")
    {
      False -> saga.Abort(error)
      True ->
        case cancel(charged) {
          Ok(Nil) -> saga.Abort(error)
          Error(cleanup) ->
            saga.AbortAfterCleanupFailure(
              error,
              UndoError("book_shipment", cleanup),
            )
        }
    }
  })
  |> saga.restore_undo(fn(_, _, _) { saga.NoUndo })
  |> saga.reconcile_compensation(fn(charged, _attempt, _key) {
    case cancel(charged) {
      Ok(Nil) ->
        saga.CompensationResolved(saga.Abort(Interrupted("book_shipment")))
      Error(_) -> saga.CompensationUnknown
    }
  })
  |> saga.recoverable(
    "1",
    codecs.to_saga(codecs.charged()),
    codecs.to_saga(codecs.booked()),
    fn(charged, _key) {
      let order = charged.reserved.order
      case
        gateway.find_shipment(
          deps.gateway,
          client(charged),
          shipment_key(order),
        )
      {
        Ok(gateway.ShipmentFound(id, False)) ->
          saga.EffectCompleted(Booked(charged, id))
        Ok(_) -> saga.EffectAbsent
        Error(_) -> saga.EffectUnknown
      }
    },
  )
}
