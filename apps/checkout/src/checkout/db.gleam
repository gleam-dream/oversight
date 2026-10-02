//// The application's own Postgres tables and queries, on the app's pog pool.
//// The same pool also backs the saga storage (`checkout/saga_store`).

import checkout/domain.{
  type CheckoutError, type OrderRequest, type OrderStatus, OutOfStock,
  StockStoreFailed,
}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import pog

pub fn start_pool(
  database_url: String,
  size: Int,
) -> Result(#(process.Pid, pog.Connection), String) {
  let name = process.new_name("checkout_pool")
  use config <- result.try(
    pog.url_config(name, database_url)
    |> result.replace_error("invalid DATABASE_URL"),
  )
  pog.start(pog.pool_size(config, size))
  |> result.map(fn(started) { #(started.pid, started.data) })
  |> result.map_error(string.inspect)
}

const schema = [
  "CREATE TABLE IF NOT EXISTS stock (
     sku text PRIMARY KEY,
     available integer NOT NULL CHECK (available >= 0))",
  "CREATE TABLE IF NOT EXISTS reservations (
     order_id text PRIMARY KEY,
     sku text NOT NULL,
     quantity integer NOT NULL,
     released boolean NOT NULL DEFAULT false)",
  "CREATE TABLE IF NOT EXISTS orders (
     order_id text PRIMARY KEY,
     status text NOT NULL,
     detail text NOT NULL DEFAULT '',
     updated_at timestamptz NOT NULL DEFAULT now())",
  "CREATE TABLE IF NOT EXISTS receipt_outbox (
     order_id text PRIMARY KEY,
     email text NOT NULL,
     amount_cents integer NOT NULL,
     submitted boolean NOT NULL DEFAULT false)",
  "CREATE TABLE IF NOT EXISTS receipts_sent (
     order_id text PRIMARY KEY,
     message_id text NOT NULL)",
  "CREATE TABLE IF NOT EXISTS saga_executions (
     id text PRIMARY KEY,
     revision bigint NOT NULL,
     generation bigint NOT NULL,
     cancelled boolean NOT NULL DEFAULT false,
     data bytea NOT NULL,
     owner_vm text,
     lease_until timestamptz)",
]

pub fn migrate(conn: pog.Connection) -> Result(Nil, pog.QueryError) {
  list.try_each(schema, fn(sql) {
    pog.query(sql) |> pog.execute(conn) |> result.replace(Nil)
  })
}

pub fn set_stock(
  conn: pog.Connection,
  sku: String,
  available: Int,
) -> Result(Nil, pog.QueryError) {
  pog.query(
    "INSERT INTO stock (sku, available) VALUES ($1, $2)
     ON CONFLICT (sku) DO UPDATE SET available = EXCLUDED.available",
  )
  |> pog.parameter(pog.text(sku))
  |> pog.parameter(pog.int(available))
  |> pog.execute(conn)
  |> result.replace(Nil)
}

pub fn stock_level(conn: pog.Connection, sku: String) -> Result(Int, Nil) {
  pog.query("SELECT available FROM stock WHERE sku = $1")
  |> pog.parameter(pog.text(sku))
  |> pog.returning(decode.at([0], decode.int))
  |> pog.execute(conn)
  |> result.replace_error(Nil)
  |> result.try(fn(r) { list.first(r.rows) })
}

/// Holds stock under the order id. Idempotent: a second call for the same
/// order is a no-op.
pub fn reserve(
  conn: pog.Connection,
  order: OrderRequest,
) -> Result(Nil, CheckoutError) {
  pog.transaction(conn, fn(tx) {
    use inserted <- result.try(
      pog.query(
        "INSERT INTO reservations (order_id, sku, quantity) VALUES ($1, $2, $3)
         ON CONFLICT (order_id) DO NOTHING",
      )
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
  order_id: String,
) -> Result(Nil, CheckoutError) {
  pog.transaction(conn, fn(tx) {
    use released <- result.try(
      pog.query(
        "UPDATE reservations SET released = true
         WHERE order_id = $1 AND NOT released
         RETURNING sku, quantity",
      )
      |> pog.parameter(pog.text(order_id))
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
  order_id: String,
) -> Result(ReservationState, CheckoutError) {
  pog.query("SELECT released FROM reservations WHERE order_id = $1")
  |> pog.parameter(pog.text(order_id))
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

pub fn insert_order(
  conn: pog.Connection,
  order_id: String,
) -> Result(Nil, pog.QueryError) {
  pog.query(
    "INSERT INTO orders (order_id, status) VALUES ($1, 'pending')
     ON CONFLICT (order_id) DO NOTHING",
  )
  |> pog.parameter(pog.text(order_id))
  |> pog.execute(conn)
  |> result.replace(Nil)
}

pub fn set_status(
  conn: pog.Connection,
  order_id: String,
  status: OrderStatus,
  detail: String,
) -> Result(Nil, pog.QueryError) {
  pog.query(
    "UPDATE orders SET status = $2, detail = $3, updated_at = now()
     WHERE order_id = $1",
  )
  |> pog.parameter(pog.text(order_id))
  |> pog.parameter(pog.text(domain.status_to_string(status)))
  |> pog.parameter(pog.text(detail))
  |> pog.execute(conn)
  |> result.replace(Nil)
}

/// Confirms the order and records the receipt in an outbox row, atomically.
/// Grind cannot join this transaction, so the job is submitted afterwards
/// from the outbox (see `checkout/receipts`).
pub fn confirm_with_receipt(
  conn: pog.Connection,
  order: OrderRequest,
  detail: String,
) -> Result(Nil, pog.TransactionError(pog.QueryError)) {
  pog.transaction(conn, fn(tx) {
    use _ <- result.try(set_status(tx, order.order_id, domain.Confirmed, detail))
    pog.query(
      "INSERT INTO receipt_outbox (order_id, email, amount_cents)
       VALUES ($1, $2, $3) ON CONFLICT (order_id) DO NOTHING",
    )
    |> pog.parameter(pog.text(order.order_id))
    |> pog.parameter(pog.text(order.email))
    |> pog.parameter(pog.int(order.amount_cents))
    |> pog.execute(tx)
    |> result.replace(Nil)
  })
}

pub type OutboxRow {
  OutboxRow(order_id: String, email: String, amount_cents: Int)
}

pub fn pending_receipts(
  conn: pog.Connection,
) -> Result(List(OutboxRow), pog.QueryError) {
  pog.query(
    "SELECT order_id, email, amount_cents FROM receipt_outbox
     WHERE NOT submitted ORDER BY order_id",
  )
  |> pog.returning({
    use order_id <- decode.field(0, decode.string)
    use email <- decode.field(1, decode.string)
    use amount <- decode.field(2, decode.int)
    decode.success(OutboxRow(order_id, email, amount))
  })
  |> pog.execute(conn)
  |> result.map(fn(r) { r.rows })
}

pub fn mark_submitted(
  conn: pog.Connection,
  order_id: String,
) -> Result(Nil, pog.QueryError) {
  pog.query("UPDATE receipt_outbox SET submitted = true WHERE order_id = $1")
  |> pog.parameter(pog.text(order_id))
  |> pog.execute(conn)
  |> result.replace(Nil)
}

pub fn record_receipt(
  conn: pog.Connection,
  order_id: String,
  message_id: String,
) -> Result(Nil, pog.QueryError) {
  pog.query(
    "INSERT INTO receipts_sent (order_id, message_id) VALUES ($1, $2)
     ON CONFLICT (order_id) DO NOTHING",
  )
  |> pog.parameter(pog.text(order_id))
  |> pog.parameter(pog.text(message_id))
  |> pog.execute(conn)
  |> result.replace(Nil)
}

pub fn receipt_sent(conn: pog.Connection, order_id: String) -> Bool {
  pog.query("SELECT 1 FROM receipts_sent WHERE order_id = $1")
  |> pog.parameter(pog.text(order_id))
  |> pog.execute(conn)
  |> result.map(fn(r) { r.count == 1 })
  |> result.unwrap(False)
}

pub fn order_status(
  conn: pog.Connection,
  order_id: String,
) -> Option(#(OrderStatus, String)) {
  pog.query("SELECT status, detail FROM orders WHERE order_id = $1")
  |> pog.parameter(pog.text(order_id))
  |> pog.returning({
    use status <- decode.field(0, decode.string)
    use detail <- decode.field(1, decode.string)
    decode.success(#(status, detail))
  })
  |> pog.execute(conn)
  |> result.map(fn(r) { r.rows })
  |> result.unwrap([])
  |> list.first
  |> result.try(fn(row) {
    domain.status_from_string(row.0) |> result.map(fn(s) { #(s, row.1) })
  })
  |> option.from_result
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
