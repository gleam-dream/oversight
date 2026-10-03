//// The refund saga: refund through the payment provider, write a ledger
//// entry, notify the customer. A failure after the payment rolls back
//// the ledger entry and voids the refund. A payment whose outcome is
//// unknown is marked with `saga.unknown_when`: saga names it in
//// `unknown_effects`, and fabric_saga reports an uncertain effect instead
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

/// One refund: the request, and the shop whose HTTP calls carry the
/// ticket (`shop.correlated`), which the tool builds from the run context
/// and the call.
pub type Refund {
  Refund(shop: Shop, request: RefundRequest)
}

pub type Workflow =
  saga.Workflow(Refund, RefundReceipt, RefundError, UndoError)

pub fn workflow(ledger: Ledger) -> Workflow {
  saga.define("refund", fn(input) {
    let payment =
      input
      |> saga.perform(
        saga.step("refund_payment", fn(refund: Refund) {
          shop.refund(refund.shop, refund.request)
        })
        |> saga.undo(fn(undo) { shop.void(undo.input.shop, undo.output) })
        // A payment that "may have been sent" may exist: saga names it an
        // unknown effect and holds the run (`Unresolved`, no rollback), and
        // fabric_saga hands the model an uncertain one.
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
        saga.step("write_ledger", fn(paid: #(Refund, String)) {
          let #(Refund(request:, ..), refund_id) = paid
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
        saga.step("notify_customer", fn(recorded: #(Refund, Int)) {
          let #(Refund(shop:, request:), _entry) = recorded
          shop.notify(
            shop,
            request.order_id,
            "Your refund of "
              <> int.to_string(request.amount_cents)
              <> " cents is on its way.",
          )
        }),
      )
    saga.both(saga.both(input, payment), saga.both(entry, notified))
    |> saga.map(fn(done) {
      let #(#(Refund(request:, ..), refund_id), #(entry, Nil)) = done
      RefundReceipt(refund_id, request.order_id, request.amount_cents, entry)
    })
  })
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
