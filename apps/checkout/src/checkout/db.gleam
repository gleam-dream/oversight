//// The application's own Postgres tables and queries. They run on the one
//// pog pool that grind builds from the app's `pog.Config`; saga_postgres
//// and grind keep their own tables on the same pool.

import checkout/domain.{
  type CheckoutError, type Order, type OrderStatus, OutOfStock, StockStoreFailed,
}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import pog

const schema = [
  // The catalog: each SKU's price and the units on hand. Orders are priced
  // from here; the request carries no amount.
  "CREATE TABLE IF NOT EXISTS stock (
     sku text PRIMARY KEY,
     unit_price_cents integer NOT NULL CHECK (unit_price_cents > 0),
     available integer NOT NULL CHECK (available >= 0))",
  "CREATE TABLE IF NOT EXISTS reservations (
     customer_id text NOT NULL,
     order_id text NOT NULL,
     sku text NOT NULL,
     quantity integer NOT NULL,
     released boolean NOT NULL DEFAULT false,
     PRIMARY KEY (customer_id, order_id))",
  // An order belongs to the customer who placed it; its id is that
  // customer's idempotency key for the placement. Ids are scoped to the
  // customer: another customer's use of the same id is a different order.
  "CREATE TABLE IF NOT EXISTS orders (
     customer_id text NOT NULL,
     order_id text NOT NULL,
     sku text NOT NULL,
     quantity integer NOT NULL,
     amount_cents integer NOT NULL,
     status text NOT NULL,
     detail text NOT NULL DEFAULT '',
     updated_at timestamptz NOT NULL DEFAULT now(),
     PRIMARY KEY (customer_id, order_id))",
  "CREATE TABLE IF NOT EXISTS receipts_sent (
     customer_id text NOT NULL,
     order_id text NOT NULL,
     message_id text NOT NULL,
     PRIMARY KEY (customer_id, order_id))",
]

pub fn migrate(conn: pog.Connection) -> Result(Nil, pog.QueryError) {
  list.try_each(schema, fn(sql) {
    pog.query(sql) |> pog.execute(conn) |> result.replace(Nil)
  })
}

/// Lists a SKU in the catalog at a price with a stock level, or updates both.
pub fn set_product(
  conn: pog.Connection,
  sku: String,
  unit_price_cents unit_price_cents: Int,
  available available: Int,
) -> Result(Nil, pog.QueryError) {
  pog.query(
    "INSERT INTO stock (sku, unit_price_cents, available) VALUES ($1, $2, $3)
     ON CONFLICT (sku) DO UPDATE
       SET unit_price_cents = EXCLUDED.unit_price_cents,
           available = EXCLUDED.available",
  )
  |> pog.parameter(pog.text(sku))
  |> pog.parameter(pog.int(unit_price_cents))
  |> pog.parameter(pog.int(available))
  |> pog.execute(conn)
  |> result.replace(Nil)
}

/// The catalog price of a SKU; `None` when the SKU is not sold.
pub fn unit_price(
  conn: pog.Connection,
  sku: String,
) -> Result(Option(Int), pog.QueryError) {
  pog.query("SELECT unit_price_cents FROM stock WHERE sku = $1")
  |> pog.parameter(pog.text(sku))
  |> pog.returning(decode.at([0], decode.int))
  |> pog.execute(conn)
  |> result.map(fn(r) { list.first(r.rows) |> option.from_result })
}

pub fn stock_level(conn: pog.Connection, sku: String) -> Result(Int, Nil) {
  pog.query("SELECT available FROM stock WHERE sku = $1")
  |> pog.parameter(pog.text(sku))
  |> pog.returning(decode.at([0], decode.int))
  |> pog.execute(conn)
  |> result.replace_error(Nil)
  |> result.try(fn(r) { list.first(r.rows) })
}

/// Holds stock under the customer's order. Idempotent: a second call for the same
/// order is a no-op.
pub fn reserve(
  conn: pog.Connection,
  order: Order,
) -> Result(Nil, CheckoutError) {
  pog.transaction(conn, fn(tx) {
    use inserted <- result.try(
      pog.query(
        "INSERT INTO reservations (customer_id, order_id, sku, quantity)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (customer_id, order_id) DO NOTHING",
      )
      |> pog.parameter(pog.text(order.customer_id))
      |> pog.parameter(pog.text(order.order_id))
      |> pog.parameter(pog.text(order.sku))
      |> pog.parameter(pog.int(order.quantity))
      |> pog.execute(tx)
      |> result.map_error(store_failed),
    )
    case inserted.count {
      0 -> Ok(Nil)
      _ -> {
        use taken <- result.try(
          pog.query(
            "UPDATE stock SET available = available - $2
             WHERE sku = $1 AND available >= $2",
          )
          |> pog.parameter(pog.text(order.sku))
          |> pog.parameter(pog.int(order.quantity))
          |> pog.execute(tx)
          |> result.map_error(store_failed),
        )
        case taken.count {
          0 -> Error(OutOfStock(order.sku, order.quantity))
          _ -> Ok(Nil)
        }
      }
    }
  })
  |> result.map_error(transaction_error)
}

/// Returns held stock. Idempotent.
pub fn release(
  conn: pog.Connection,
  order: Order,
) -> Result(Nil, CheckoutError) {
  pog.transaction(conn, fn(tx) {
    use released <- result.try(
      pog.query(
        "UPDATE reservations SET released = true
         WHERE customer_id = $1 AND order_id = $2 AND NOT released
         RETURNING sku, quantity",
      )
      |> pog.parameter(pog.text(order.customer_id))
      |> pog.parameter(pog.text(order.order_id))
      |> pog.returning({
        use sku <- decode.field(0, decode.string)
        use quantity <- decode.field(1, decode.int)
        decode.success(#(sku, quantity))
      })
      |> pog.execute(tx)
      |> result.map_error(store_failed),
    )
    case released.rows {
      [#(sku, quantity)] ->
        pog.query("UPDATE stock SET available = available + $2 WHERE sku = $1")
        |> pog.parameter(pog.text(sku))
        |> pog.parameter(pog.int(quantity))
        |> pog.execute(tx)
        |> result.replace(Nil)
        |> result.map_error(store_failed)
      _ -> Ok(Nil)
    }
  })
  |> result.map_error(transaction_error)
}

pub type ReservationState {
  Held
  Released
  Absent
}

pub fn reservation(
  conn: pog.Connection,
  order: Order,
) -> Result(ReservationState, CheckoutError) {
  pog.query(
    "SELECT released FROM reservations WHERE customer_id = $1 AND order_id = $2",
  )
  |> pog.parameter(pog.text(order.customer_id))
  |> pog.parameter(pog.text(order.order_id))
  |> pog.returning(decode.at([0], decode.bool))
  |> pog.execute(conn)
  |> result.map_error(store_failed)
  |> result.map(fn(r) {
    case r.rows {
      [False] -> Held
      [True] -> Released
      _ -> Absent
    }
  })
}

/// An order row as its owner reads it.
pub type OrderRecord {
  OrderRecord(
    order_id: String,
    customer_id: String,
    sku: String,
    quantity: Int,
    amount_cents: Int,
    status: OrderStatus,
    detail: String,
  )
}

pub type Insertion {
  /// This call created the pending order.
  Inserted
  /// This customer already has an order with this id.
  AlreadyExists(OrderRecord)
  /// Another placement of the id won but its row could not be read back.
  /// Nothing in the app deletes orders, so callers refuse it as a conflict.
  Contended
}

/// Creates the pending order, or reports the customer's existing one. The
/// primary key, the customer and the order id, decides between concurrent
/// placements of one id by one customer: exactly one inserts. Another
/// customer's order with the same id is never read or touched.
pub fn insert_order(
  conn: pog.Connection,
  order: Order,
) -> Result(Insertion, pog.QueryError) {
  use inserted <- result.try(
    pog.query(
      "INSERT INTO orders
         (order_id, customer_id, sku, quantity, amount_cents, status)
       VALUES ($1, $2, $3, $4, $5, 'pending')
       ON CONFLICT (customer_id, order_id) DO NOTHING",
    )
    |> pog.parameter(pog.text(order.order_id))
    |> pog.parameter(pog.text(order.customer_id))
    |> pog.parameter(pog.text(order.sku))
    |> pog.parameter(pog.int(order.quantity))
    |> pog.parameter(pog.int(order.amount_cents))
    |> pog.execute(conn),
  )
  case inserted.count {
    1 -> Ok(Inserted)
    _ ->
      select_orders(
        "WHERE customer_id = $1 AND order_id = $2",
        [order.customer_id, order.order_id],
        conn,
      )
      |> result.map(fn(rows) {
        case rows {
          [existing, ..] -> AlreadyExists(existing)
          [] -> Contended
        }
      })
  }
}

pub fn set_status(
  conn: pog.Connection,
  order: Order,
  status: OrderStatus,
  detail: String,
) -> Result(Nil, pog.QueryError) {
  pog.query(
    "UPDATE orders SET status = $3, detail = $4, updated_at = now()
     WHERE customer_id = $1 AND order_id = $2",
  )
  |> pog.parameter(pog.text(order.customer_id))
  |> pog.parameter(pog.text(order.order_id))
  |> pog.parameter(pog.text(domain.status_to_string(status)))
  |> pog.parameter(pog.text(detail))
  |> pog.execute(conn)
  |> result.replace(Nil)
}

pub fn record_receipt(
  conn: pog.Connection,
  customer_id: String,
  order_id: String,
  message_id: String,
) -> Result(Nil, pog.QueryError) {
  pog.query(
    "INSERT INTO receipts_sent (customer_id, order_id, message_id)
     VALUES ($1, $2, $3)
     ON CONFLICT (customer_id, order_id) DO NOTHING",
  )
  |> pog.parameter(pog.text(customer_id))
  |> pog.parameter(pog.text(order_id))
  |> pog.parameter(pog.text(message_id))
  |> pog.execute(conn)
  |> result.replace(Nil)
}

pub fn receipt_sent(
  conn: pog.Connection,
  customer_id: String,
  order_id: String,
) -> Bool {
  pog.query(
    "SELECT 1 FROM receipts_sent WHERE customer_id = $1 AND order_id = $2",
  )
  |> pog.parameter(pog.text(customer_id))
  |> pog.parameter(pog.text(order_id))
  |> pog.execute(conn)
  |> result.map(fn(r) { r.count == 1 })
  |> result.unwrap(False)
}

/// The order, if it exists and belongs to `customer_id`. Another
/// customer's order reads as absent, so the API cannot tell them apart.
pub fn order_for(
  conn: pog.Connection,
  customer_id: String,
  order_id: String,
) -> Result(Option(OrderRecord), pog.QueryError) {
  select_orders(
    "WHERE order_id = $1 AND customer_id = $2",
    [order_id, customer_id],
    conn,
  )
  |> result.map(fn(rows) { list.first(rows) |> option.from_result })
}

/// The status and detail of a customer's order. For tests and operators;
/// the API reads through `order_for`.
pub fn order_status(
  conn: pog.Connection,
  customer_id: String,
  order_id: String,
) -> Option(#(OrderStatus, String)) {
  case order_for(conn, customer_id, order_id) {
    Ok(order) -> option.map(order, fn(row) { #(row.status, row.detail) })
    Error(_) -> option.None
  }
}

fn select_orders(
  filter: String,
  parameters: List(String),
  conn: pog.Connection,
) -> Result(List(OrderRecord), pog.QueryError) {
  let query =
    pog.query(
      "SELECT order_id, customer_id, sku, quantity, amount_cents, status, detail
       FROM orders " <> filter,
    )
  list.fold(parameters, query, fn(q, p) { pog.parameter(q, pog.text(p)) })
  |> pog.returning({
    use order_id <- decode.field(0, decode.string)
    use customer_id <- decode.field(1, decode.string)
    use sku <- decode.field(2, decode.string)
    use quantity <- decode.field(3, decode.int)
    use amount_cents <- decode.field(4, decode.int)
    use status <- decode.field(5, status_decoder())
    use detail <- decode.field(6, decode.string)
    decode.success(OrderRecord(
      order_id:,
      customer_id:,
      sku:,
      quantity:,
      amount_cents:,
      status:,
      detail:,
    ))
  })
  |> pog.execute(conn)
  |> result.map(fn(r) { r.rows })
}

fn status_decoder() -> decode.Decoder(OrderStatus) {
  use text <- decode.then(decode.string)
  case domain.status_from_string(text) {
    Ok(status) -> decode.success(status)
    Error(Nil) -> decode.failure(domain.Rejected, "OrderStatus")
  }
}

fn store_failed(error: pog.QueryError) -> CheckoutError {
  StockStoreFailed(string.inspect(error))
}

fn transaction_error(
  error: pog.TransactionError(CheckoutError),
) -> CheckoutError {
  case error {
    pog.TransactionRolledBack(e) -> e
    pog.TransactionQueryError(e) -> store_failed(e)
  }
}
