//// The application's own tables on its own pog pool: the `research` index
//// that ties one research id to its Grind job, its Fabric run and its
//// result, and the saga checkpoint table (see `saga_store`).

import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import pog
import research_agent/events

pub type Row {
  Row(
    id: String,
    topic: String,
    job_id: Option(Int),
    run_id: Option(String),
    state: String,
    detail: String,
  )
}

pub fn migrate(db: pog.Connection) -> Result(Nil, String) {
  [
    "CREATE TABLE IF NOT EXISTS research (
       id text PRIMARY KEY,
       topic text NOT NULL,
       job_id bigint,
       run_id text,
       state text NOT NULL,
       detail text NOT NULL DEFAULT '',
       updated_at timestamptz NOT NULL DEFAULT now())",
    "CREATE TABLE IF NOT EXISTS saga_executions (
       id text PRIMARY KEY,
       revision bigint NOT NULL,
       generation bigint NOT NULL,
       cancelled boolean NOT NULL DEFAULT false,
       data bytea NOT NULL,
       owner text,
       lease_until timestamptz)",
  ]
  |> list.try_each(fn(sql) { exec(db, pog.query(sql)) })
}

pub fn insert(
  db: pog.Connection,
  id: String,
  topic: String,
) -> Result(Nil, String) {
  pog.query(
    "INSERT INTO research (id, topic, state) VALUES ($1, $2, 'queued')
     ON CONFLICT (id) DO NOTHING",
  )
  |> pog.parameter(pog.text(id))
  |> pog.parameter(pog.text(topic))
  |> exec(db, _)
  |> announced(id, events.Queued)
}

pub fn set_job(
  db: pog.Connection,
  id: String,
  job_id: Int,
) -> Result(Nil, String) {
  pog.query("UPDATE research SET job_id = $2 WHERE id = $1")
  |> pog.parameter(pog.text(id))
  |> pog.parameter(pog.int(job_id))
  |> exec(db, _)
}

/// Records the Fabric run id. Fabric issues the id inside `fabric.start`, so
/// this write necessarily follows the run's first commit: a crash between
/// the two leaves an orphan run (see FEEDBACK RA-2).
pub fn set_run(
  db: pog.Connection,
  id: String,
  run_id: String,
) -> Result(Nil, String) {
  pog.query(
    "UPDATE research SET run_id = $2, state = 'researching', updated_at = now()
     WHERE id = $1",
  )
  |> pog.parameter(pog.text(id))
  |> pog.parameter(pog.text(run_id))
  |> exec(db, _)
  |> announced(id, events.Researching)
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
    "SELECT id, topic, job_id, run_id, state, detail FROM research WHERE id = $1",
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

/// Research whose job has not reached a final state in this table.
pub fn unfinished(db: pog.Connection) -> Result(List(Row), String) {
  pog.query(
    "SELECT id, topic, job_id, run_id, state, detail FROM research
     WHERE state IN ('queued', 'researching', 'publishing') AND job_id IS NOT NULL",
  )
  |> pog.returning(row_decoder())
  |> pog.execute(db)
  |> result.map(fn(returned) { returned.rows })
  |> result.map_error(string.inspect)
}

fn row_decoder() -> decode.Decoder(Row) {
  use id <- decode.field(0, decode.string)
  use topic <- decode.field(1, decode.string)
  use job_id <- decode.field(2, decode.optional(decode.int))
  use run_id <- decode.field(3, decode.optional(decode.string))
  use state <- decode.field(4, decode.string)
  use detail <- decode.field(5, decode.string)
  decode.success(Row(id:, topic:, job_id:, run_id:, state:, detail:))
}

fn exec(db: pog.Connection, query: pog.Query(a)) -> Result(Nil, String) {
  pog.execute(query, db)
  |> result.replace(Nil)
  |> result.map_error(string.inspect)
}
