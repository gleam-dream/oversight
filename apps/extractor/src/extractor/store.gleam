//// Extracted invoices in the application's own Postgres pool.
////
//// Grind owns a separate pool against the same database and does not accept
//// or lend a `pog.Connection`, so the result write cannot share a
//// transaction with the job's acknowledgement. The upsert on `document_id`
//// makes a replayed attempt converge on one row instead.

import extractor/invoice.{type Invoice}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/result
import json/blueprint/codec
import pog

pub type Stored {
  Stored(row_id: Int, document_id: String, provider: String, invoice: Invoice)
}

pub fn start(database_url: String) -> Result(pog.Connection, String) {
  let name = process.new_name("extractor_store")
  use config <- result.try(
    pog.url_config(name, database_url)
    |> result.replace_error("invalid DATABASE_URL"),
  )
  pog.start(config |> pog.pool_size(4))
  |> result.map(fn(started) { started.data })
  |> result.replace_error("could not start the store pool")
}

pub fn migrate(db: pog.Connection) -> Result(Nil, pog.QueryError) {
  pog.query(
    "create table if not exists extracted_invoices (
      id bigserial primary key,
      document_id text not null unique,
      provider text not null,
      vendor text not null,
      invoice_number text not null,
      currency text not null,
      total_cents bigint not null,
      payload jsonb not null,
      extracted_at timestamptz not null default now()
    )",
  )
  |> pog.execute(db)
  |> result.replace(Nil)
}

pub fn save(
  db: pog.Connection,
  document_id: String,
  provider: String,
  invoice: Invoice,
) -> Result(Int, pog.QueryError) {
  // The codec cannot fail for a value it decoded; a failure here is a bug.
  let assert Ok(payload) = codec.encode_json(invoice.codec(), invoice)
  pog.query(
    "insert into extracted_invoices
       (document_id, provider, vendor, invoice_number, currency, total_cents, payload)
     values ($1, $2, $3, $4, $5, $6, $7::jsonb)
     on conflict (document_id) do update set
       provider = excluded.provider,
       vendor = excluded.vendor,
       invoice_number = excluded.invoice_number,
       currency = excluded.currency,
       total_cents = excluded.total_cents,
       payload = excluded.payload,
       extracted_at = now()
     returning id",
  )
  |> pog.parameter(pog.text(document_id))
  |> pog.parameter(pog.text(provider))
  |> pog.parameter(pog.text(invoice.vendor))
  |> pog.parameter(pog.text(invoice.number))
  |> pog.parameter(pog.text(invoice.currency_code(invoice.currency)))
  |> pog.parameter(pog.int(invoice.total_cents))
  |> pog.parameter(pog.text(payload))
  |> pog.returning(decode.at([0], decode.int))
  |> pog.execute(db)
  |> result.try(fn(returned) {
    case returned.rows {
      [id] -> Ok(id)
      _ -> Error(pog.UnexpectedArgumentCount(1, list.length(returned.rows)))
    }
  })
}

pub fn find(
  db: pog.Connection,
  document_id: String,
) -> Result(List(Stored), pog.QueryError) {
  let row = {
    use id <- decode.field(0, decode.int)
    use document_id <- decode.field(1, decode.string)
    use provider <- decode.field(2, decode.string)
    use payload <- decode.field(3, decode.string)
    case codec.decode_json(invoice.codec(), payload) {
      Ok(invoice) -> decode.success(Stored(id, document_id, provider, invoice))
      Error(_) ->
        decode.failure(
          Stored(id, document_id, provider, placeholder()),
          "Invoice",
        )
    }
  }
  pog.query(
    "select id, document_id, provider, payload::text
       from extracted_invoices where document_id = $1",
  )
  |> pog.parameter(pog.text(document_id))
  |> pog.returning(row)
  |> pog.execute(db)
  |> result.map(fn(returned) { returned.rows })
}

pub fn count(db: pog.Connection) -> Result(Int, pog.QueryError) {
  pog.query("select count(*)::bigint from extracted_invoices")
  |> pog.returning(decode.at([0], decode.int))
  |> pog.execute(db)
  |> result.map(fn(returned) {
    case returned.rows {
      [n] -> n
      _ -> 0
    }
  })
}

fn placeholder() -> Invoice {
  invoice.Invoice("", "", "", invoice.Usd, [], 0)
}
