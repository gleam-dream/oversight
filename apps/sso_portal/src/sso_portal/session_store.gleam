//// The portal's browser-session table in Postgres (pog).
////
//// One row maps the browser's signed session cookie to Warden's custody
//// reference, with the facts the portal lists and revokes by (subject,
//// email, last seen). Tokens are not here: Warden keeps them, sealed, in its
//// own table (`warden_records.gleam`).

import gleam/dynamic/decode
import gleam/option.{type Option}
import gleam/result
import pog

pub type StoredSession {
  StoredSession(
    id: String,
    warden_reference: String,
    issuer: String,
    subject: String,
    email: Option(String),
  )
}

pub type StoreError {
  StoreFailed(pog.QueryError)
}

pub fn migrate(db: pog.Connection) -> Result(Nil, StoreError) {
  pog.query(
    "create table if not exists portal_sessions (
       id text primary key,
       warden_reference text not null,
       issuer text not null,
       subject text not null,
       email text,
       created_at timestamptz not null default now(),
       last_seen_at timestamptz not null default now()
     )",
  )
  |> pog.execute(db)
  |> result.replace(Nil)
  |> result.map_error(StoreFailed)
}

pub fn insert(
  db: pog.Connection,
  session: StoredSession,
) -> Result(Nil, StoreError) {
  pog.query(
    "insert into portal_sessions (id, warden_reference, issuer, subject, email)
     values ($1, $2, $3, $4, $5)",
  )
  |> pog.parameter(pog.text(session.id))
  |> pog.parameter(pog.text(session.warden_reference))
  |> pog.parameter(pog.text(session.issuer))
  |> pog.parameter(pog.text(session.subject))
  |> pog.parameter(pog.nullable(pog.text, session.email))
  |> pog.execute(db)
  |> result.replace(Nil)
  |> result.map_error(StoreFailed)
}

/// Find a session and record that it was seen.
pub fn touch(
  db: pog.Connection,
  id: String,
) -> Result(Result(StoredSession, Nil), StoreError) {
  pog.query(
    "update portal_sessions set last_seen_at = now() where id = $1
     returning id, warden_reference, issuer, subject, email",
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
  use warden_reference <- decode.field(1, decode.string)
  use issuer <- decode.field(2, decode.string)
  use subject <- decode.field(3, decode.string)
  use email <- decode.field(4, decode.optional(decode.string))
  decode.success(StoredSession(
    id:,
    warden_reference:,
    issuer:,
    subject:,
    email:,
  ))
}
