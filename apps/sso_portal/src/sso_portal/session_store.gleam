//// The portal's browser-session table in Postgres (pog).
////
//// One row maps the browser's signed session cookie to Hellhound's custody
//// reference, with the facts the portal lists and revokes by (subject,
//// email, last seen). Tokens are not here: Hellhound keeps them, sealed, in its
//// own table (`hellhound_records.gleam`).
////
//// Each row carries its own `expires_at`. A cookie's `Max-Age` is only a
//// request to the browser; a copied cookie keeps working until the server
//// refuses it, so lookups ignore and delete expired rows.

import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option}
import gleam/result
import pog

pub type StoredSession {
  StoredSession(
    id: String,
    hellhound_reference: String,
    issuer: String,
    subject: String,
    email: Option(String),
  )
}

pub type StoreError {
  StoreFailed(pog.QueryError)
}

pub fn migrate(db: pog.Connection) -> Result(Nil, StoreError) {
  [
    "create table if not exists portal_sessions (
       id text primary key,
       hellhound_reference text not null,
       issuer text not null,
       subject text not null,
       email text,
       created_at timestamptz not null default now(),
       last_seen_at timestamptz not null default now(),
       expires_at timestamptz not null default now()
     )",
    // Rows from before expiry existed are expired at once.
    "alter table portal_sessions
       add column if not exists expires_at timestamptz not null default now()",
    "create index if not exists portal_sessions_expires_at
       on portal_sessions (expires_at)",
  ]
  |> list.try_each(fn(sql) { pog.query(sql) |> pog.execute(db) })
  |> result.map_error(StoreFailed)
}

/// Store a session that expires `lifetime_seconds` after now, by the
/// database clock.
pub fn insert(
  db: pog.Connection,
  session: StoredSession,
  lifetime_seconds lifetime_seconds: Int,
) -> Result(Nil, StoreError) {
  pog.query(
    "insert into portal_sessions
       (id, hellhound_reference, issuer, subject, email, expires_at)
     values ($1, $2, $3, $4, $5, now() + $6::int * interval '1 second')",
  )
  |> pog.parameter(pog.text(session.id))
  |> pog.parameter(pog.text(session.hellhound_reference))
  |> pog.parameter(pog.text(session.issuer))
  |> pog.parameter(pog.text(session.subject))
  |> pog.parameter(pog.nullable(pog.text, session.email))
  |> pog.parameter(pog.int(lifetime_seconds))
  |> pog.execute(db)
  |> result.replace(Nil)
  |> result.map_error(StoreFailed)
}

/// Find a live session and record that it was seen. An expired row is
/// absent, and is deleted in the same statement.
pub fn touch(
  db: pog.Connection,
  id: String,
) -> Result(Result(StoredSession, Nil), StoreError) {
  pog.query(
    "with expired as (
       delete from portal_sessions where id = $1 and expires_at <= now()
     )
     update portal_sessions set last_seen_at = now()
     where id = $1 and expires_at > now()
     returning id, hellhound_reference, issuer, subject, email",
  )
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder())
  |> pog.execute(db)
  |> result.map(fn(returned) {
    case returned.rows {
      [session] -> Ok(session)
      _ -> Error(Nil)
    }
  })
  |> result.map_error(StoreFailed)
}

pub fn delete(db: pog.Connection, id: String) -> Result(Nil, StoreError) {
  pog.query("delete from portal_sessions where id = $1")
  |> pog.parameter(pog.text(id))
  |> pog.execute(db)
  |> result.replace(Nil)
  |> result.map_error(StoreFailed)
}

/// Delete every expired row; returns how many went.
pub fn delete_expired(db: pog.Connection) -> Result(Int, StoreError) {
  pog.query("delete from portal_sessions where expires_at <= now()")
  |> pog.execute(db)
  |> result.map(fn(returned) { returned.count })
  |> result.map_error(StoreFailed)
}

pub fn count(db: pog.Connection, subject: String) -> Result(Int, StoreError) {
  pog.query("select count(*)::int from portal_sessions where subject = $1")
  |> pog.parameter(pog.text(subject))
  |> pog.returning(decode.at([0], decode.int))
  |> pog.execute(db)
  |> result.map(fn(returned) {
    case returned.rows {
      [n] -> n
      _ -> 0
    }
  })
  |> result.map_error(StoreFailed)
}

fn decoder() -> decode.Decoder(StoredSession) {
  use id <- decode.field(0, decode.string)
  use hellhound_reference <- decode.field(1, decode.string)
  use issuer <- decode.field(2, decode.string)
  use subject <- decode.field(3, decode.string)
  use email <- decode.field(4, decode.optional(decode.string))
  decode.success(StoredSession(
    id:,
    hellhound_reference:,
    issuer:,
    subject:,
    email:,
  ))
}
