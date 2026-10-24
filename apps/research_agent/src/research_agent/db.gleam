//// The application's own table on the pool it shares with Grind, Fabric and
//// Saga: the `research` index that ties one research id to its Grind job and
//// its progress. The Fabric run needs no column: its id derives from the job
//// (`jobs.run_id`). The app's pool puts the node's schema first
//// on its `search_path`, so the unqualified table lives next to Grind's,
//// Fabric's and Saga's.

import gleam/dynamic/decode
import gleam/result
import gleam/string
import pog
import research_agent/events

pub type Row {
  Row(id: String, topic: String, job_id: Int, state: String, detail: String)
}

pub fn migrate(db: pog.Connection, schema: String) -> Result(Nil, String) {
  use Nil <- result.try(exec(
    db,
    pog.query("CREATE SCHEMA IF NOT EXISTS \"" <> schema <> "\""),
  ))
  exec(
    db,
    pog.query(
      "CREATE TABLE IF NOT EXISTS research (
         id text PRIMARY KEY,
         topic text NOT NULL,
         job_id bigint NOT NULL,
         state text NOT NULL,
         detail text NOT NULL DEFAULT '',
         updated_at timestamptz NOT NULL DEFAULT now())",
    ),
  )
}

/// Records a request and its job. Called inside the transaction that
/// submits the job (`grind.submit_in`), so the row and the job commit
/// together; the caller announces `Queued` after the commit.
pub fn insert(
  tx: pog.Connection,
  id: String,
  topic: String,
  job_id: Int,
) -> Result(Nil, String) {
  pog.query(
    "INSERT INTO research (id, topic, job_id, state) VALUES ($1, $2, $3, 'queued')",
  )
  |> pog.parameter(pog.text(id))
  |> pog.parameter(pog.text(topic))
  |> pog.parameter(pog.int(job_id))
  |> exec(tx, _)
}

pub fn set_state(
  db: pog.Connection,
  id: String,
  state: events.State,
  detail: String,
) -> Result(Nil, String) {
  pog.query(
    "UPDATE research SET state = $2, detail = $3, updated_at = now() WHERE id = $1",
  )
  |> pog.parameter(pog.text(id))
  |> pog.parameter(pog.text(events.state_name(state)))
  |> pog.parameter(pog.text(detail))
  |> exec(db, _)
  |> announced(id, state)
}

/// Announces a state the table now holds.
fn announced(
  written: Result(Nil, String),
  id: String,
  state: events.State,
) -> Result(Nil, String) {
  use Nil <- result.map(written)
  events.announce(id, state)
}

pub fn get(db: pog.Connection, id: String) -> Result(Row, String) {
  pog.query(
    "SELECT id, topic, job_id, state, detail FROM research WHERE id = $1",
  )
  |> pog.parameter(pog.text(id))
  |> pog.returning(row_decoder())
  |> pog.execute(db)
  |> result.map_error(string.inspect)
  |> result.try(fn(returned) {
    case returned.rows {
      [row] -> Ok(row)
      _ -> Error("no research " <> id)
    }
  })
}

fn row_decoder() -> decode.Decoder(Row) {
  use id <- decode.field(0, decode.string)
  use topic <- decode.field(1, decode.string)
  use job_id <- decode.field(2, decode.int)
  use state <- decode.field(3, decode.string)
  use detail <- decode.field(4, decode.string)
  decode.success(Row(id:, topic:, job_id:, state:, detail:))
}

fn exec(db: pog.Connection, query: pog.Query(a)) -> Result(Nil, String) {
  pog.execute(query, db)
  |> result.replace(Nil)
  |> result.map_error(string.inspect)
}
