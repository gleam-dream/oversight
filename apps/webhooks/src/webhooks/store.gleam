//// The application's own tables, on the pool grind runs on. That pool's
//// `search_path` is grind's schema, so every table here is qualified with
//// `public`.

import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import pog
import webhooks/subscription.{type Subscription, Subscription}

pub type StoreError {
  NotFound
  QueryFailed(pog.QueryError)
}

pub fn migrate(db: pog.Connection) -> Result(Nil, StoreError) {
  [
    "CREATE TABLE IF NOT EXISTS webhook_subscriptions (
       id text PRIMARY KEY,
       tenant text NOT NULL,
       url text NOT NULL,
       secret text NOT NULL,
       disabled_reason text,
       created_at timestamptz NOT NULL DEFAULT now())",
    "CREATE TABLE IF NOT EXISTS webhook_deliveries (
       id text PRIMARY KEY,
       event_id text NOT NULL,
       subscription_id text NOT NULL,
       job_id bigint NOT NULL,
       attempts int NOT NULL DEFAULT 0,
       last_status int,
       last_note text,
       created_at timestamptz NOT NULL DEFAULT now())",
  ]
  |> list.try_each(fn(sql) {
    pog.query(sql) |> pog.execute(db) |> result.map_error(QueryFailed)
  })
}

pub fn insert_subscription(
  db: pog.Connection,
  sub: Subscription,
) -> Result(Nil, StoreError) {
  pog.query(
    "INSERT INTO webhook_subscriptions (id, tenant, url, secret) VALUES ($1, $2, $3, $4)",
  )
  |> pog.parameter(pog.text(sub.id))
  |> pog.parameter(pog.text(sub.tenant))
  |> pog.parameter(pog.text(sub.url))
  |> pog.parameter(pog.text(sub.secret))
  |> pog.execute(db)
  |> result.replace(Nil)
  |> result.map_error(QueryFailed)
}

fn subscription_decoder() -> decode.Decoder(Subscription) {
  use id <- decode.field(0, decode.string)
  use tenant <- decode.field(1, decode.string)
  use url <- decode.field(2, decode.string)
  use secret <- decode.field(3, decode.string)
  use disabled <- decode.field(4, decode.optional(decode.string))
  let status = case disabled {
    None -> subscription.Active
    Some(reason) -> subscription.Disabled(reason)
  }
  decode.success(Subscription(id:, tenant:, url:, secret:, status:))
}

const subscription_columns = "id, tenant, url, secret, disabled_reason"

pub fn get_subscription(
  db: pog.Connection,
  id: String,
) -> Result(Subscription, StoreError) {
  pog.query(
    "SELECT "
    <> subscription_columns
    <> " FROM webhook_subscriptions WHERE id = $1",
  )
  |> pog.parameter(pog.text(id))
  |> pog.returning(subscription_decoder())
  |> pog.execute(db)
  |> result.map_error(QueryFailed)
  |> result.try(fn(returned) {
    case returned.rows {
      [sub, ..] -> Ok(sub)
      [] -> Error(NotFound)
    }
  })
}

pub fn active_for_tenant(
  db: pog.Connection,
  tenant: String,
) -> Result(List(Subscription), StoreError) {
  pog.query(
    "SELECT "
    <> subscription_columns
    <> " FROM webhook_subscriptions WHERE tenant = $1 AND disabled_reason IS NULL ORDER BY created_at, id",
  )
  |> pog.parameter(pog.text(tenant))
  |> pog.returning(subscription_decoder())
  |> pog.execute(db)
  |> result.map(fn(returned) { returned.rows })
  |> result.map_error(QueryFailed)
}

pub fn disable(
  db: pog.Connection,
  id: String,
  reason: String,
) -> Result(Nil, StoreError) {
  pog.query(
    "UPDATE webhook_subscriptions SET disabled_reason = $2 WHERE id = $1 AND disabled_reason IS NULL",
  )
  |> pog.parameter(pog.text(id))
  |> pog.parameter(pog.text(reason))
  |> pog.execute(db)
  |> result.replace(Nil)
  |> result.map_error(QueryFailed)
}

pub fn record_delivery(
  db: pog.Connection,
  id: String,
  event_id: String,
  subscription_id: String,
  job_id: Int,
) -> Result(Nil, StoreError) {
  pog.query(
    "INSERT INTO webhook_deliveries (id, event_id, subscription_id, job_id) VALUES ($1, $2, $3, $4) ON CONFLICT (id) DO NOTHING",
  )
  |> pog.parameter(pog.text(id))
  |> pog.parameter(pog.text(event_id))
  |> pog.parameter(pog.text(subscription_id))
  |> pog.parameter(pog.int(job_id))
  |> pog.execute(db)
  |> result.replace(Nil)
  |> result.map_error(QueryFailed)
}

pub fn record_attempt(
  db: pog.Connection,
  id: String,
  status: Option(Int),
  note: String,
) -> Result(Nil, StoreError) {
  pog.query(
    "UPDATE webhook_deliveries SET attempts = attempts + 1, last_status = $2, last_note = $3 WHERE id = $1",
  )
  |> pog.parameter(pog.text(id))
  |> pog.parameter(pog.nullable(pog.int, status))
  |> pog.parameter(pog.text(note))
  |> pog.execute(db)
  |> result.replace(Nil)
  |> result.map_error(QueryFailed)
}

pub type DeliveryRow {
  DeliveryRow(
    id: String,
    job_id: Int,
    attempts: Int,
    last_status: Option(Int),
    last_note: Option(String),
  )
}

pub fn get_delivery(
  db: pog.Connection,
  id: String,
) -> Result(DeliveryRow, StoreError) {
  pog.query(
    "SELECT id, job_id, attempts, last_status, last_note FROM webhook_deliveries WHERE id = $1",
  )
  |> pog.parameter(pog.text(id))
  |> pog.returning({
    use id <- decode.field(0, decode.string)
    use job_id <- decode.field(1, decode.int)
    use attempts <- decode.field(2, decode.int)
    use last_status <- decode.field(3, decode.optional(decode.int))
    use last_note <- decode.field(4, decode.optional(decode.string))
    decode.success(DeliveryRow(
      id:,
      job_id:,
      attempts:,
      last_status:,
      last_note:,
    ))
  })
  |> pog.execute(db)
  |> result.map_error(QueryFailed)
  |> result.try(fn(returned) {
    case returned.rows {
      [row, ..] -> Ok(row)
      [] -> Error(NotFound)
    }
  })
}
