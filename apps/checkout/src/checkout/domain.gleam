//// The order domain: what a customer asks for, what each saga step proves,
//// and the typed reasons a checkout can fail. Nothing here knows about
//// saga, grind or HTTP transport apart from carrying http_gun's own typed
//// `Failure` inside the provider errors.

import gleam/int
import gleam/string
import http_gun/error

/// What a customer sends to `POST /orders`: what to buy, where to ship it,
/// and the opaque token the payment provider issued for their card. It
/// carries no price and no card number.
pub type CheckoutRequest {
  CheckoutRequest(
    order_id: String,
    sku: String,
    quantity: Int,
    payment_token: String,
    address: String,
    email: String,
  )
}

/// The most units of one SKU a single order may ask for.
pub const max_quantity = 100

/// An order the server has priced for an authenticated customer: the
/// saga's input and the durable job's payload. `customer_id` comes from the
/// caller's credential and `amount_cents` from the catalog, never from the
/// body, and the only payment credential is the provider's token.
pub type Order {
  Order(
    order_id: String,
    customer_id: String,
    sku: String,
    quantity: Int,
    amount_cents: Int,
    payment_token: String,
    address: String,
    email: String,
  )
}

/// The key that names one customer's order inside the app and towards its
/// providers: saga executions, grind jobs, provider idempotency keys and
/// telemetry. Order ids are scoped to the customer, so two customers may
/// use the same id; the length prefix keeps the pair unambiguous whatever
/// either part contains.
pub fn order_key(customer_id: String, order_id: String) -> String {
  int.to_string(string.byte_size(customer_id))
  <> ":"
  <> customer_id
  <> ":"
  <> order_id
}

/// The order's `order_key`.
pub fn key(order: Order) -> String {
  order_key(order.customer_id, order.order_id)
}

/// Prices a customer's request at the catalog's unit price.
pub fn price(
  request: CheckoutRequest,
  customer_id customer_id: String,
  unit_price_cents unit_price_cents: Int,
) -> Order {
  Order(
    order_id: request.order_id,
    customer_id:,
    sku: request.sku,
    quantity: request.quantity,
    amount_cents: unit_price_cents * request.quantity,
    payment_token: request.payment_token,
    address: request.address,
    email: request.email,
  )
}

/// Stock is held under the customer's order.
pub type Reserved {
  Reserved(order: Order)
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
    ProviderUnreachable(failure:, ..) ->
      error.evidence(failure) == error.MaybeSent
    _ -> False
  }
}

pub fn provider_name(provider: Provider) -> String {
  case provider {
    Payments -> "payments"
    Shipping -> "shipping"
  }
}

/// A stable, client-facing message for an error. It names only order facts
/// (SKU, quantity, provider, step); driver and transport detail stays in
/// the error value and goes to the log through `log_detail`.
pub fn describe_error(error: CheckoutError) -> String {
  case error {
    OutOfStock(sku, requested) ->
      "out of stock: " <> sku <> " x" <> int.to_string(requested)
    StockStoreFailed(_) -> "stock store unavailable"
    Declined(reason) -> "card declined: " <> reason
    ProviderRejected(provider, status) ->
      provider_name(provider) <> " answered HTTP " <> int.to_string(status)
    ProviderUnreachable(provider, failure) ->
      case error.kind(failure) {
        error.TimedOut -> provider_name(provider) <> " timed out"
        _ -> provider_name(provider) <> " unreachable"
      }
    Interrupted(step) -> step <> " was interrupted"
  }
}

/// A stable machine-readable code for an error, for API bodies.
pub fn error_code(error: CheckoutError) -> String {
  case error {
    OutOfStock(..) -> "out_of_stock"
    StockStoreFailed(_) -> "store_unavailable"
    Declined(_) -> "payment_declined"
    ProviderRejected(..) -> "provider_rejected"
    ProviderUnreachable(failure:, ..) ->
      case error.kind(failure) {
        error.TimedOut -> "provider_timeout"
        _ -> "provider_unreachable"
      }
    Interrupted(_) -> "interrupted"
  }
}

/// The operator-facing detail of an error, for the log only.
pub fn log_detail(error: CheckoutError) -> String {
  case error {
    StockStoreFailed(detail) -> "stock store failed: " <> detail
    ProviderUnreachable(provider, failure) ->
      provider_name(provider) <> ": " <> error.describe(failure)
    _ -> describe_error(error)
  }
}
