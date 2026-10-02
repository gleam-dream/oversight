//// The refund saga: refund through the payment provider, write a ledger
//// entry, notify the customer. A failure after the payment rolls back
//// the ledger entry and voids the refund. A payment whose outcome is
//// unknown is held, never compensated: voiding a refund that may not
//// exist, or reporting a clean failure for one that may, would both lie.

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

/// What the payment step does with an error that says the refund may
/// exist. Only `HoldUnknown` is honest; `AbortUnknown` is what an author
/// gets by mapping every step error to `Abort` (or by writing no decider).
pub type OnUnknown {
  HoldUnknown
  AbortUnknown
}

pub fn workflow(shop: Shop, ledger: Ledger) -> Workflow {
  workflow_with(shop, ledger, HoldUnknown)
}

pub fn workflow_with(
  shop: Shop,
  ledger: Ledger,
  unknown: OnUnknown,
) -> Workflow {
  let assert Ok(workflow) =
    saga.define("refund", fn(input) {
      let payment =
        input
        |> saga.perform(
          saga.step("refund_payment", fn(request) { shop.refund(shop, request) })
          |> saga.undo(fn(_request, refund_id) { shop.void(shop, refund_id) })
          |> saga.compensate(max_attempts: 1, with: fn(_request, failure, _) {
            case failure {
              saga.Returned(PaymentOutcomeUnknown(_) as error)
                if unknown == HoldUnknown
              -> saga.Hold(error)
              saga.Returned(error) -> saga.Abort(error)
              saga.Crashed(_) | saga.TimedOut ->
                saga.Hold(PaymentOutcomeUnknown("the attempt did not return"))
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
          |> saga.undo(fn(_paid, entry) {
            case ledger.remove(ledger, entry) {
              True -> Ok(Nil)
              False -> Error(LedgerEntryMissing(entry))
            }
          }),
        )
      let notified =
        saga.both(input, entry)
        |> saga.perform(
          saga.step("notify_customer", fn(recorded: #(RefundRequest, Int)) {
            let #(request, _entry) = recorded
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
        let #(#(request, refund_id), #(entry, Nil)) = done
        RefundReceipt(refund_id, request.order_id, request.amount_cents, entry)
      })
    })
  workflow
}

/// Bounds for one refund run. The payment API gets less time than a
/// person would wait; cleanup gets enough to void a refund.
pub fn config() -> execution.Config {
  execution.Config(..execution.config(), max_concurrency: 1)
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
