//// A PostgreSQL `saga/storage.Storage`, written in the app because Saga
//// ships only memory and file adapters. One row per execution holds the
//// revision, the ownership generation, the cancellation flag, the
//// checkpoint bytes, and an owner with a lease. Every write is one
//// conditional statement: a claim takes a free or expired row and bumps the
//// generation, so an older runner of the same execution fails its next
//// commit with `StaleOwner`; a commit renews the lease. Saga's contract ties
//// ownership to the claiming process ("a token alone grants no ownership"),
//// so the owner column holds this incarnation's token plus the claimer's
//// pid. Without a monitor, a claim of a runner that crashed in this VM is
//// held until its lease expires. Checked by `saga/storage/conformance` in
//// the tests.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import pog
import saga/storage.{type Record, type Storage, Record}

pub type SagaStore {
  SagaStore(db: pog.Connection, owner: String, lease_ms: Int)
}

pub fn new(db: pog.Connection, owner: String, lease_ms: Int) -> SagaStore {
  SagaStore(db:, owner:, lease_ms:)
}

/// The storage of one execution.
pub fn storage(store: SagaStore, id: String) -> Storage {
  storage.Storage(
    create: fn(data) { create(store, id, data) },
    load: fn() { load(store.db, id) |> result.map(fn(row) { row.0 }) },
    claim: fn() { claim(store, id) },
    commit: fn(generation, revision, cancelled, data) {
      commit(store, id, generation, revision, cancelled, data)
    },
    release: fn(generation) { release(store, id, generation) },
    cancel: fn() { cancel(store, id) },
  )
}

const columns = "revision, generation, cancelled, data"

fn record_decoder() -> decode.Decoder(Record) {
  use revision <- decode.field(0, decode.int)
  use generation <- decode.field(1, decode.int)
  use cancelled <- decode.field(2, decode.bool)
  use data <- decode.field(3, decode.bit_array)
  decode.success(Record(revision:, generation:, cancelled:, data:))
}

fn one(
  query: pog.Query(Nil),
  db: pog.Connection,
) -> Result(Option(Record), storage.Error) {
  pog.execute(query |> pog.returning(record_decoder()), db)
  |> result.map(fn(returned) {
    case returned.rows {
      [record] -> Some(record)
      _ -> None
    }
  })
  |> result.map_error(io)
}

fn create(
  store: SagaStore,
  id: String,
  data: BitArray,
) -> Result(Record, storage.Error) {
  use created <- result.try(
    pog.query("INSERT INTO saga_executions (id, revision, generation, data)
       VALUES ($1, 0, 0, $2) ON CONFLICT (id) DO NOTHING RETURNING " <> columns)
    |> pog.parameter(pog.text(id))
    |> pog.parameter(pog.bytea(data))
    |> one(store.db),
  )
  option.to_result(created, storage.AlreadyExists)
}

fn load(
  db: pog.Connection,
  id: String,
) -> Result(#(Record, Option(String)), storage.Error) {
  use returned <- result.try(
    pog.query(
      "SELECT " <> columns <> ", owner FROM saga_executions WHERE id = $1",
    )
    |> pog.parameter(pog.text(id))
    |> pog.returning({
      use record <- decode.then(record_decoder())
      use owner <- decode.field(4, decode.optional(decode.string))
      decode.success(#(record, owner))
    })
    |> pog.execute(db)
    |> result.map_error(io),
  )
  case returned.rows {
    [row] -> Ok(row)
    _ -> Error(storage.NotFound)
  }
}

/// This process, as an owner: the incarnation token and the pid.
fn owner_of(store: SagaStore, pid: process.Pid) -> String {
  store.owner <> "/" <> pid_to_string(pid)
}

fn me(store: SagaStore) -> pog.Value {
  pog.text(owner_of(store, process.self()))
}

fn lease(store: SagaStore) -> pog.Value {
  pog.text(int.to_string(store.lease_ms) <> " milliseconds")
}

/// Takes a free or expired row, or a row whose owner was a process of this
/// incarnation that has died (saga's "reclaim after owner death").
fn claim(store: SagaStore, id: String) -> Result(Record, storage.Error) {
  use claimed <- result.try(take(store, id, None))
  case claimed {
    Some(record) -> Ok(record)
    None -> {
      use #(_, owner) <- result.try(load(store.db, id))
      case owner {
        Some(owner) ->
          case dead_local_owner(store, owner) {
            True ->
              take(store, id, Some(owner))
              |> result.try(option.to_result(_, storage.Busy))
            False -> Error(storage.Busy)
          }
        None -> Error(storage.Busy)
      }
    }
  }
}

fn take(
  store: SagaStore,
  id: String,
  dead_owner: Option(String),
) -> Result(Option(Record), storage.Error) {
  pog.query("UPDATE saga_executions
     SET generation = generation + 1, owner = $2,
         lease_until = clock_timestamp() + $3::text::interval
     WHERE id = $1
       AND (owner IS NULL OR lease_until < clock_timestamp() OR owner = $4)
     RETURNING " <> columns)
  |> pog.parameter(pog.text(id))
  |> pog.parameter(me(store))
  |> pog.parameter(lease(store))
  |> pog.parameter(pog.nullable(pog.text, dead_owner))
  |> one(store.db)
}

fn dead_local_owner(store: SagaStore, owner: String) -> Bool {
  case string.split_once(owner, store.owner <> "/") {
    Ok(#("", pid)) ->
      case string_to_pid(pid) {
        Ok(pid) -> !process.is_alive(pid)
        Error(Nil) -> False
      }
    _ -> False
  }
}

@external(erlang, "research_agent_ffi", "pid_to_string")
fn pid_to_string(pid: process.Pid) -> String

@external(erlang, "research_agent_ffi", "string_to_pid")
fn string_to_pid(text: String) -> Result(process.Pid, Nil)

fn commit(
  store: SagaStore,
  id: String,
  generation: Int,
  revision: Int,
  cancelled: Bool,
  data: BitArray,
) -> Result(Record, storage.Error) {
  use committed <- result.try(
    pog.query("UPDATE saga_executions
       SET revision = revision + 1, data = $5,
           lease_until = clock_timestamp() + $7::text::interval
       WHERE id = $1 AND generation = $2 AND revision = $3 AND cancelled = $4
         AND owner = $6
       RETURNING " <> columns)
    |> pog.parameter(pog.text(id))
    |> pog.parameter(pog.int(generation))
    |> pog.parameter(pog.int(revision))
    |> pog.parameter(pog.bool(cancelled))
    |> pog.parameter(pog.bytea(data))
    |> pog.parameter(me(store))
    |> pog.parameter(lease(store))
    |> one(store.db),
  )
  case committed {
    Some(record) -> Ok(record)
    option.None -> {
      use #(current, owner) <- result.try(load(store.db, id))
      let mine = owner_of(store, process.self())
      let owned = current.generation == generation && owner == Some(mine)
      Error(case owned, current.cancelled == cancelled {
        False, _ -> storage.StaleOwner
        True, False -> storage.CancellationChanged
        True, True -> storage.Conflict
      })
    }
  }
}

fn release(
  store: SagaStore,
  id: String,
  generation: Int,
) -> Result(Nil, storage.Error) {
  use returned <- result.try(
    pog.query(
      "UPDATE saga_executions SET owner = NULL, lease_until = NULL
       WHERE id = $1 AND generation = $2 AND owner = $3",
    )
    |> pog.parameter(pog.text(id))
    |> pog.parameter(pog.int(generation))
    |> pog.parameter(me(store))
    |> pog.execute(store.db)
    |> result.map_error(io),
  )
  case returned.count {
    1 -> Ok(Nil)
    _ -> Error(storage.StaleOwner)
  }
}

fn cancel(store: SagaStore, id: String) -> Result(Nil, storage.Error) {
  use returned <- result.try(
    pog.query("UPDATE saga_executions SET cancelled = true WHERE id = $1")
    |> pog.parameter(pog.text(id))
    |> pog.execute(store.db)
    |> result.map_error(io),
  )
  case returned.count {
    1 -> Ok(Nil)
    _ -> Error(storage.NotFound)
  }
}

/// Deletes every execution row: test isolation for the conformance suite.
pub fn delete(store: SagaStore, id: String) -> Nil {
  let _ =
    pog.query("DELETE FROM saga_executions WHERE id = $1")
    |> pog.parameter(pog.text(id))
    |> pog.execute(store.db)
  Nil
}

fn io(error: pog.QueryError) -> storage.Error {
  storage.Io(string.inspect(error))
}
