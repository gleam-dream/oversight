//// The refund saga: refund through the payment provider, write a ledger
//// entry, notify the customer. A failure after the payment rolls back
//// the ledger entry and voids the refund. A payment whose outcome is
//// unknown is marked with `saga.unknown_when`: saga names it in
//// `unknown_effects`, and saga_tool reports an uncertain effect instead
//// of a clean failure for a refund that may exist.

import gleam/int
import saga
import saga/execution
import support_desk/domain.{
  type RefundReceipt, type RefundRequest, RefundReceipt,
}
import support_desk/ledger.{type Ledger}
import support_desk/shop.{
  type RefundError, type Shop, type UndoError, LedgerEntryMissing,
  NotificationFailed, PaymentDeclined, PaymentOutcomeUnknown, PaymentUnavailable,
}

pub type Workflow =
  saga.Workflow(RefundRequest, RefundReceipt, RefundError, UndoError)

/// The workflow takes the tool's own input. Each step reads the run's
/// correlation from its `EffectKey` and tags the shop's HTTP calls with it
/// (`shop.correlated`), so the refund, notify and void requests join the
/// ticket without a per-ticket shop in the input.
pub fn workflow(shop: Shop, ledger: Ledger) -> Workflow {
  saga.define("refund", fn(input) {
    let payment =
      input
      |> saga.perform(
        saga.effect("refund_payment", fn(request: RefundRequest, key) {
          shop.refund(correlated(shop, key), request)
        })
        |> saga.undo(fn(undo) {
          shop.void(correlated(shop, undo.key), undo.output)
        })
        // A payment that "may have been sent" may exist: saga names it an
        // unknown effect and holds the run (`Unresolved`, no rollback), and
        // saga_tool hands the model an uncertain one.
        |> saga.unknown_when(fn(error) {
          case error {
            PaymentOutcomeUnknown(_) -> True
            _ -> False
          }
        }),
      )
    let entry =
      saga.both(input, payment)
      |> saga.perform(
        saga.step("write_ledger", fn(paid: #(RefundRequest, String)) {
          let #(request, refund_id) = paid
          Ok(ledger.append(
            ledger,
            request.order_id,
            refund_id,
            request.amount_cents,
          ))
        })
        |> saga.undo(fn(undo) {
          case ledger.remove(ledger, undo.output) {
            True -> Ok(Nil)
            False -> Error(LedgerEntryMissing(undo.output))
          }
        }),
      )
    let notified =
      saga.both(input, entry)
      |> saga.perform(
        saga.effect("notify_customer", fn(recorded: #(RefundRequest, Int), key) {
          let #(request, _entry) = recorded
          shop.notify(
            correlated(shop, key),
            request.order_id,
            "Your refund of "
              <> int.to_string(request.amount_cents)
              <> " cents is on its way.",
          )
        }),
      )
    saga.both(saga.both(input, payment), saga.both(entry, notified))
    |> saga.map(fn(done) {
      let #(#(request, refund_id), #(entry, Nil)) = done
      RefundReceipt(refund_id, request.order_id, request.amount_cents, entry)
    })
  })
}

fn correlated(shop: Shop, key: saga.EffectKey) -> Shop {
  shop.correlated(shop, saga.correlation_of(key))
}

/// Bounds for one refund run. The payment API gets less time than a
/// person would wait; cleanup gets enough to void a refund.
pub fn config() -> execution.Config {
  execution.config() |> execution.with_max_concurrency(1)
}

/// What the model is told when the saga ended with a known failure and
/// rolled back everything it did.
pub fn explain(error: RefundError) -> String {
  case error {
    PaymentDeclined(status) ->
      "the payment provider declined the refund (HTTP "
      <> int.to_string(status)
      <> "); nothing was refunded"
    PaymentUnavailable(detail) ->
      "the payment provider was unreachable ("
      <> detail
      <> "); nothing was refunded"
    PaymentOutcomeUnknown(detail) ->
      "the payment outcome is unknown (" <> detail <> ")"
    NotificationFailed(detail) ->
      "the customer could not be notified ("
      <> detail
      <> "); the refund was voided and the ledger entry removed"
  }
}
