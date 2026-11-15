//// How the model, the card and a replay reach what the agent reads.
////
//// - `live`: what the agent's read tools use. A read is captured as
////   evidence (`decisions/model.capture`) before the model sees it, and a
////   context reference resolves from the `requests` table.
//// - `content`: what the record names, as it was read: the card
////   (`decisions/view`) and the export (`decisions/learning`) resolve every
////   reference through it, whatever the world says now.
//// - `latest`: the revision the world holds now, so a card flags an input
////   that changed after the model read it.

import decisions/model.{type Sources, Sources}
import decisions/vocabulary.{type Ref}
import gleam/result
import json/blueprint/codec
import payout_desk/db
import payout_desk/domain
import pog

pub fn live(db: pog.Connection) -> Sources {
  Sources(
    resolve: fn(ref: Ref) {
      content(db)(ref)
      |> result.map_error(fn(_) {
        model.ReadFailed(ref.kind, ref.id, "not on record")
      })
    },
    read: fn(name, argument) {
      model.capture(
        db.evidence(),
        db,
        source: name,
        request: argument,
        fetch: fn() { fetch(db, name, argument) },
      )
      |> result.map_error(model.ReadFailed(name, argument, _))
    },
  )
}

/// What a read tool answers now.
pub fn fetch(
  db: pog.Connection,
  name: String,
  argument: String,
) -> Result(String, String) {
  case name {
    _ if name == domain.read_order ->
      db.order(db, argument)
      |> result.map_error(db.describe)
      |> result.try(encode(domain.order_codec(), _))
    _ if name == domain.read_dispute ->
      db.dispute(db, argument)
      |> result.map_error(db.describe)
      |> result.try(encode(domain.dispute_codec(), _))
    _ if name == domain.read_history ->
      db.history(db, argument)
      |> result.map_error(db.describe)
      |> result.try(encode(domain.history_codec(), _))
    _ -> Error("no read named " <> name)
  }
}

fn encode(codec: codec.Codec(a), value: a) -> Result(String, String) {
  codec.encode_json(codec, value)
  |> result.map_error(codec.describe_encode_error)
}

/// The content behind a reference the record names: a request, or the
/// evidence a read was captured as.
pub fn content(db: pog.Connection) -> fn(Ref) -> Result(String, model.Failure) {
  fn(ref: Ref) {
    case ref.kind {
      "request" ->
        db.request(db, ref.id)
        |> result.map(fn(found) { { db.request_document(found.0) }.1 })
        |> result.replace_error(Nil)
      _ -> db.evidence().get(db, ref) |> result.replace_error(Nil)
    }
    |> result.replace_error(model.NotRecorded(ref.kind, ref.id))
  }
}

/// The revision an input has now: a read is answered again and digested,
/// as `model.capture` names its evidence.
pub fn latest(db: pog.Connection) -> fn(Ref) -> String {
  fn(ref: Ref) {
    case ref.kind {
      "request" -> ref.revision
      kind ->
        case fetch(db, kind, ref.id) {
          Ok(body) -> model.digest(body)
          Error(_) -> ref.revision
        }
    }
  }
}
