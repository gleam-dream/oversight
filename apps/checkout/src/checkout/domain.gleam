//// The order domain: what a customer asks for, what each saga step proves,
//// and the typed reasons a checkout can fail. Nothing here knows about
//// saga, grind or HTTP transport apart from carrying http_gun's own typed
//// `Failure` inside the provider errors.

import gleam/int
import http_gun/error

pub type OrderRequest {
  OrderRequest(
    order_id: String,
    sku: String,
    quantity: Int,
    card: String,
    amount_cents: Int,
    address: String,
    email: String,
  )
}

/// Stock is held under the order id.
pub type Reserved {
  Reserved(order: OrderRequest)
}

pub type Charged {
  Charged(reserved: Reserved, charge_id: String)
}

pub type Booked {
  Booked(charged: Charged, shipment_id: String)
}

pub type Provider {
  Payments
  Shipping
}

/// The workflow's single error vocabulary. Provider transport failures keep
/// http_gun's typed `Failure` (reason and submission evidence) instead of a
/// rendered string.
pub type CheckoutError {
  OutOfStock(sku: String, requested: Int)
  StockStoreFailed(detail: String)
  Declined(reason: String)
  ProviderRejected(provider: Provider, status: Int)
  ProviderUnreachable(provider: Provider, failure: error.Failure)
  /// The step's attempt crashed, timed out, or was interrupted by a restart,
  /// so saga, not the provider, is the source of the failure.
  Interrupted(step: String)
}

/// Undo and compensation-cleanup failures.
pub type UndoError {
  UndoError(step: String, cause: CheckoutError)
}

/// The order's lifecycle as the API reports it.
pub type OrderStatus {
  Pending
  Confirmed
  Rejected
  NeedsReconciliation
}

pub fn status_to_string(status: OrderStatus) -> String {
  case status {
    Pending -> "pending"
    Confirmed -> "confirmed"
    Rejected -> "rejected"
    NeedsReconciliation -> "needs_reconciliation"
  }
}

pub fn status_from_string(text: String) -> Result(OrderStatus, Nil) {
  case text {
    "pending" -> Ok(Pending)
    "confirmed" -> Ok(Confirmed)
    "rejected" -> Ok(Rejected)
    "needs_reconciliation" -> Ok(NeedsReconciliation)
    _ -> Error(Nil)
  }
}

/// True when the provider may have acted although we saw no answer.
pub fn effect_uncertain(error: CheckoutError) -> Bool {
  case error {
    ProviderUnreachable(
      failure: error.Failure(evidence: error.MayHaveBeenSent, ..),
      ..,
    ) -> True
    _ -> False
  }
}

pub fn provider_name(provider: Provider) -> String {
  case provider {
    Payments -> "payments"
    Shipping -> "shipping"
  }
}

pub fn describe_error(error: CheckoutError) -> String {
  case error {
    OutOfStock(sku, requested) ->
      "out of stock: " <> sku <> " x" <> int.to_string(requested)
    StockStoreFailed(detail) -> "stock store failed: " <> detail
    Declined(reason) -> "card declined: " <> reason
    ProviderRejected(provider, status) ->
      provider_name(provider) <> " answered HTTP " <> int.to_string(status)
    ProviderUnreachable(provider, failure) ->
      provider_name(provider) <> ": " <> error.describe(failure)
    Interrupted(step) -> step <> " was interrupted"
  }
}
