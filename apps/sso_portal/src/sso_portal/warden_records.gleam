//// Warden's `warden/store` port on PostgreSQL (pog): one table of sealed
//// records, three statements.
////
//// Warden seals every record (AES-256-GCM, bound to its key and version)
//// before it reaches this module, so the table holds no token, no session
//// reference and nothing a database reader or writer can use. The adapter
//// only has to be a compare-and-set on one row.

import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import pog
import warden/store.{type Record, type Store, type StoreError, Record}

/// The columns Warden's records need.
pub fn migrate(
  db: pog.Connection,
  table: String,
) -> Result(Nil, pog.QueryError) {
  pog.query("create table if not exists " <> identifier(table) <> " (
       key text primary key,
       version bigint not null,
       expires_at timestamptz not null,
       sealed bytea not null
     )")
  |> pog.execute(db)
  |> result.replace(Nil)
}

/// A `warden/store` over `table`. Pass it to `config.with_custody_store` and
/// `config.with_transaction_store`.
pub fn new(db: pog.Connection, table: String) -> Store {
  let table = identifier(table)
  store.new(
    get: fn(key) { get(db, table, key) },
    put: fn(record, expected) { put(db, table, record, expected) },
    delete_expired: fn(now) {
      pog.query(
        "delete from " <> table <> " where expires_at <= " <> instant("$1"),
      )
      |> pog.parameter(pog.int(microseconds(now)))
      |> pog.execute(db)
      |> result.map(fn(returned) { returned.count })
      |> result.map_error(write_error)
    },
  )
}

fn get(
  db: pog.Connection,
  table: String,
  key: String,
) -> Result(Option(Record), StoreError) {
  pog.query(
    "select version, (extract(epoch from expires_at) * 1000000)::bigint, sealed from "
    <> table
    <> " where key = $1",
  )
  |> pog.parameter(pog.text(key))
  |> pog.returning({
    use version <- decode.field(0, decode.int)
    use expires_at <- decode.field(1, pog.timestamp_decoder())
    use sealed <- decode.field(2, decode.bit_array)
    decode.success(Record(key:, version:, expires_at:, sealed:))
  })
  |> pog.execute(db)
  |> result.map(fn(returned) {
    case returned.rows {
      [record] -> Some(record)
      _ -> None
    }
  })
  |> result.map_error(fn(_) { store.StoreUnavailable })
}

fn put(
  db: pog.Connection,
  table: String,
  record: Record,
  expected: Option(Int),
) -> Result(Bool, StoreError) {
  let query = case expected {
    None ->
      pog.query("insert into " <> table <> " (key, version, expires_at, sealed)
           values ($1, $2, " <> instant("$3") <> ", $4) on conflict (key) do nothing")
      |> pog.parameter(pog.text(record.key))
      |> pog.parameter(pog.int(record.version))
      |> pog.parameter(pog.int(microseconds(record.expires_at)))
      |> pog.parameter(pog.bytea(record.sealed))
    Some(version) ->
      pog.query(
        "update "
        <> table
        <> " set version = $2, expires_at = "
        <> instant("$3")
        <> ", sealed = $4 where key = $1 and version = $5",
      )
      |> pog.parameter(pog.text(record.key))
      |> pog.parameter(pog.int(record.version))
      |> pog.parameter(pog.int(microseconds(record.expires_at)))
      |> pog.parameter(pog.bytea(record.sealed))
      |> pog.parameter(pog.int(version))
  }
  query
  |> pog.execute(db)
  |> result.map(fn(returned) { returned.count == 1 })
  |> result.map_error(write_error)
}

/// Instants cross the driver as integer microseconds since the epoch:
/// pog's `timestamp_decoder` does not read a `timestamptz` column here, and
/// whole microseconds round-trip exactly.
fn microseconds(at: Timestamp) -> Int {
  let #(seconds, nanoseconds) = timestamp.to_unix_seconds_and_nanoseconds(at)
  seconds * 1_000_000 + nanoseconds / 1000
}

fn instant(parameter: String) -> String {
  "to_timestamp(" <> parameter <> "::bigint / 1000000.0)"
}

/// A timeout or a lost connection may have followed the write; anything else
/// was refused before it.
fn write_error(error: pog.QueryError) -> StoreError {
  case error {
    pog.QueryTimeout -> store.StoreOutcomeUnknown
    pog.ConnectionUnavailable -> store.StoreUnavailable
    _ -> store.StoreUnavailable
  }
}

/// Table names are code, never input; refuse anything that is not a plain
/// identifier rather than splice it into SQL.
fn identifier(name: String) -> String {
  let plain =
    name != ""
    && string.to_graphemes(name)
    |> list.all(string.contains("abcdefghijklmnopqrstuvwxyz_0123456789", _))
  case plain {
    True -> name
    False -> panic as { "not a table name: " <> name }
  }
}
