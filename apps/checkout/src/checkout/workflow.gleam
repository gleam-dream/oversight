//// The checkout saga: reserve stock (pog), charge the card (payments API),
//// book the shipment (shipping API). One definition serves both the local
//// run behind `POST /orders` and the durable run driven by a grind job.
////
//// Provider idempotency keys are derived from the order id, not from
//// `saga.idempotency_key(key)`. Saga's key is stable across retries and across
//// restarts of one durable execution, but a local run derives it from its
//// run id, so a second `POST /orders` for the same order would charge again.
//// The order id is the business key across runs.
////
//// Each step correlates its own provider calls from the run:
//// `saga.correlation_of(key)` is the order's correlation, set on the local
//// run (`execution.with_correlation`) or on the durable handle.
////
//// Both provider steps mark a `MaybeSent` transport failure with
//// `saga.unknown_when`, so saga names the attempt in `unknown_effects`
//// while the decider still receives the typed error.

import checkout/codecs
import checkout/db
import checkout/domain.{
  type Booked, type Charged, type CheckoutError, type OrderRequest,
  type Reserved, type UndoError, Booked, Charged, Interrupted, Reserved,
  UndoError,
}
import checkout/gateway.{type Gateway}
import gleam/option.{None, Some}
import gleam/result
import http_gun
import pog
import saga.{type EffectKey, type Step, type Workflow}
import saga/durable
import saga/execution

pub type Deps {
  Deps(
    pool: pog.Connection,
    gateway: Gateway,
    /// Total charge attempts when the payment outcome is unknown.
    charge_attempts: Int,
  )
}

pub type Checkout =
  Workflow(OrderRequest, Booked, CheckoutError, UndoError)

pub type Persistence =
  durable.Persistence(OrderRequest, Booked, CheckoutError, UndoError)

pub fn payment_key(order: OrderRequest) -> String {
  "pay-" <> order.order_id
}

pub fn shipment_key(order: OrderRequest) -> String {
  "ship-" <> order.order_id
}

/// The gateway's client, correlated like the run that calls it.
fn client_for(deps: Deps, key: EffectKey) -> http_gun.Client {
  http_gun.with_correlation(deps.gateway.client, saga.correlation_of(key))
}

pub fn define(deps: Deps) -> Checkout {
  saga.define("checkout", fn(input) {
    input
    |> saga.perform(reserve_stock(deps))
    |> saga.perform(charge_card(deps))
    |> saga.perform(book_shipment(deps))
  })
}

pub fn persistence(
  workflow: Checkout,
  config: execution.Config,
) -> Persistence {
  durable.new(
    workflow,
    input: codecs.to_saga(codecs.order()),
    output: codecs.to_saga(codecs.booked()),
    error: codecs.to_saga(codecs.checkout_error()),
    undo_error: codecs.to_saga(codecs.undo_error()),
  )
  |> durable.with_config(config)
}

fn reserve_stock(
  deps: Deps,
) -> Step(OrderRequest, Reserved, CheckoutError, UndoError) {
  saga.step("reserve_stock", fn(order: OrderRequest) {
    db.reserve(deps.pool, order) |> result.replace(Reserved(order))
  })
  |> saga.undo(fn(undo) {
    db.release(deps.pool, undo.input.order_id)
    |> result.map_error(UndoError("reserve_stock", _))
  })
  |> durable.recoverable(
    version: "1",
    input: codecs.to_saga(codecs.order()),
    output: codecs.to_saga(codecs.reserved()),
    resolve: fn(order, _key) {
      case db.reservation(deps.pool, order.order_id) {
        Ok(db.Absent) -> durable.NotSent
        Ok(_) -> durable.Completed(Reserved(order))
        Error(_) -> durable.MaybeSent
      }
    },
  )
}

fn charge_card(
  deps: Deps,
) -> Step(Reserved, Charged, CheckoutError, UndoError) {
  let void = fn(charged: Charged, key) {
    gateway.void(deps.gateway, client_for(deps, key), charged.charge_id)
    |> result.map_error(UndoError("charge_card", _))
  }
  let lookup = fn(reserved: Reserved, key) {
    gateway.find_charge(
      deps.gateway,
      client_for(deps, key),
      payment_key(reserved.order),
    )
  }
  saga.effect("charge_card", fn(reserved: Reserved, key) {
    let order = reserved.order
    gateway.charge(
      deps.gateway,
      client_for(deps, key),
      order,
      payment_key(order),
    )
    |> result.map(Charged(reserved, _))
  })
  |> saga.undo(fn(undo) { void(undo.output, undo.key) })
  |> saga.unknown_when(domain.effect_uncertain)
  // Retry an unknown payment outcome under the same provider idempotency
  // key, and hold (no rollback) when attempts run out.
  |> saga.compensate(max_attempts: deps.charge_attempts, with: fn(failed) {
    case failed.failure {
      saga.Returned(error) ->
        case domain.effect_uncertain(error), failed.attempts_left > 0 {
          True, True -> saga.Retry
          True, False -> saga.Hold(error)
          False, _ -> saga.Abort(error)
        }
      saga.Crashed(_) | saga.TimedOut ->
        case failed.attempts_left > 0 {
          True -> saga.Retry
          False -> saga.Hold(Interrupted("charge_card"))
        }
    }
  })
  |> durable.restore_undo(fn(undo) {
    saga.UndoWith(fn() { void(undo.output, undo.key) })
  })
  |> durable.resolve_compensation(fn(reserved, key) {
    case lookup(reserved, key) {
      Ok(gateway.ChargeFound(id, False)) -> {
        let charged = Charged(reserved, id)
        Some(saga.Continue(charged, saga.UndoWith(fn() { void(charged, key) })))
      }
      Ok(_) -> Some(saga.Retry)
      Error(_) -> None
    }
  })
  |> durable.recoverable(
    version: "1",
    input: codecs.to_saga(codecs.reserved()),
    output: codecs.to_saga(codecs.charged()),
    resolve: fn(reserved, key) {
      case lookup(reserved, key) {
        Ok(gateway.ChargeFound(id, _)) ->
          durable.Completed(Charged(reserved, id))
        Ok(gateway.NoCharge) -> durable.NotSent
        Error(_) -> durable.MaybeSent
      }
    },
  )
}

fn book_shipment(
  deps: Deps,
) -> Step(Charged, Booked, CheckoutError, UndoError) {
  let cancel = fn(charged: Charged, key) {
    gateway.cancel_shipment(
      deps.gateway,
      client_for(deps, key),
      shipment_key(charged.reserved.order),
    )
  }
  saga.effect("book_shipment", fn(charged: Charged, key) {
    let order = charged.reserved.order
    gateway.book(
      deps.gateway,
      client_for(deps, key),
      order,
      shipment_key(order),
    )
    |> result.map(Booked(charged, _))
  })
  // A booked shipment is cancelled when a cancellation rolls the run back
  // after this last step succeeded.
  |> saga.undo(fn(undo) {
    cancel(undo.input, undo.key)
    |> result.map_error(UndoError("book_shipment", _))
  })
  |> saga.unknown_when(domain.effect_uncertain)
  // A shipment request that timed out may still have been booked. Saga only
  // undoes steps that succeeded, so cancelling a possibly-booked shipment
  // is this step's own compensation cleanup.
  |> saga.compensate(max_attempts: 1, with: fn(failed) {
    let error = case failed.failure {
      saga.Returned(error) -> error
      saga.Crashed(_) | saga.TimedOut -> Interrupted("book_shipment")
    }
    case
      domain.effect_uncertain(error) || error == Interrupted("book_shipment")
    {
      False -> saga.Abort(error)
      True ->
        case cancel(failed.input, failed.key) {
          Ok(Nil) -> saga.Abort(error)
          Error(cleanup) ->
            saga.AbortAfterCleanupFailure(
              error,
              UndoError("book_shipment", cleanup),
            )
        }
    }
  })
  |> durable.restore_undo(fn(undo) {
    saga.UndoWith(fn() {
      cancel(undo.input, undo.key)
      |> result.map_error(UndoError("book_shipment", _))
    })
  })
  |> durable.resolve_compensation(fn(charged, key) {
    case cancel(charged, key) {
      Ok(Nil) -> Some(saga.Abort(Interrupted("book_shipment")))
      Error(_) -> None
    }
  })
  |> durable.recoverable(
    version: "1",
    input: codecs.to_saga(codecs.charged()),
    output: codecs.to_saga(codecs.booked()),
    resolve: fn(charged, key) {
      let order = charged.reserved.order
      case
        gateway.find_shipment(
          deps.gateway,
          client_for(deps, key),
          shipment_key(order),
        )
      {
        Ok(gateway.ShipmentFound(id, False)) ->
          durable.Completed(Booked(charged, id))
        Ok(_) -> durable.NotSent
        Error(_) -> durable.MaybeSent
      }
    },
  )
}
