//// A PostgreSQL-backed `saga/storage.Storage`, written in the app with pog
//// on the application's own pool. Saga ships only memory and file adapters.
////
//// One row per execution holds revision, ownership generation, the
//// cancellation flag and the checkpoint bytes. Fencing is two-layered:
//// - within this VM, an owner registry ties each claim to the claiming
////   process and monitors it, so a dead runner releases its claim at once
////   and a stale or foreign process cannot commit with a copied token;
//// - across VMs, the row carries the owning VM's token and a lease that
////   every claim and commit renews; another VM may claim only after expiry,
////   and every write is conditional on generation and revision.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/int
import gleam/option.{type Option, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import pog
import saga/storage.{type Record, type Storage, Record}

pub opaque type SagaStore {
  SagaStore(
    conn: pog.Connection,
    owners: Subject(Message),
    vm: String,
    lease: String,
  )
}

type Owner {
  Owner(generation: Int, pid: Pid, monitor: Monitor)
}

type State {
  State(
    conn: pog.Connection,
    vm: String,
    lease: String,
    owners: Dict(String, Owner),
    on_claim: fn(String, Pid) -> Nil,
  )
}

type Message {
  Claim(id: String, pid: Pid, reply: Subject(Result(Record, storage.Error)))
  IsOwner(id: String, pid: Pid, generation: Int, reply: Subject(Bool))
  Release(
    id: String,
    pid: Pid,
    generation: Int,
    reply: Subject(Result(Nil, storage.Error)),
  )
  OwnerOf(id: String, reply: Subject(Option(Pid)))
  OwnerDown(process.Down)
}

/// `on_claim` is told which process claimed which execution; the app uses it
/// to attribute saga telemetry, which carries no execution reference.
pub fn start(
  conn: pog.Connection,
  lease_ms: Int,
  on_claim: fn(String, Pid) -> Nil,
) -> SagaStore {
  let vm = "vm-" <> int.to_string(int.random(1_000_000_000_000))
  let lease = int.to_string(lease_ms) <> " milliseconds"
  let assert Ok(started) =
    actor.new_with_initialiser(1000, fn(subject) {
      let selector =
        process.new_selector()
        |> process.select(subject)
        |> process.select_monitors(OwnerDown)
      actor.initialised(State(conn, vm, lease, dict.new(), on_claim))
      |> actor.selecting(selector)
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(handle)
    |> actor.start
  SagaStore(conn:, owners: started.data, vm:, lease:)
}

/// The process currently running `id` in this VM, if any.
pub fn owner(store: SagaStore, id: String) -> Option(Pid) {
  actor.call(store.owners, 5000, OwnerOf(id, _))
}

pub fn delete(store: SagaStore, id: String) -> Nil {
  let _ =
    pog.query("DELETE FROM saga_executions WHERE id = $1")
    |> pog.parameter(pog.text(id))
    |> pog.execute(store.conn)
  Nil
}

/// The saga `Storage` contract for one execution.
pub fn storage(store: SagaStore, id: String) -> Storage {
  storage.Storage(
    create: fn(data) { create(store, id, data) },
    load: fn() { load(store, id) },
    claim: fn() {
      actor.call(store.owners, 10_000, Claim(id, process.self(), _))
    },
    commit: fn(generation, revision, cancelled, data) {
      case
        actor.call(store.owners, 5000, IsOwner(
          id,
          process.self(),
          generation,
          _,
        ))
      {
        False -> Error(storage.StaleOwner)
        True -> commit(store, id, generation, revision, cancelled, data)
      }
    },
    release: fn(generation) {
      actor.call(store.owners, 10_000, Release(
        id,
        process.self(),
        generation,
        _,
      ))
    },
    cancel: fn() { cancel(store, id) },
  )
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Claim(id, pid, reply) -> {
      let live = case dict.get(state.owners, id) {
        Ok(o) -> process.is_alive(o.pid)
        Error(Nil) -> False
      }
      case live {
        True -> {
          process.send(reply, Error(storage.Busy))
          actor.continue(state)
        }
        False -> {
          let result = claim_row(state, id)
          process.send(reply, result)
          case result {
            Ok(record) -> {
              state.on_claim(id, pid)
              let owner = Owner(record.generation, pid, process.monitor(pid))
              actor.continue(
                State(..state, owners: dict.insert(state.owners, id, owner)),
              )
            }
            Error(_) -> actor.continue(state)
          }
        }
      }
    }
    IsOwner(id, pid, generation, reply) -> {
      process.send(reply, case dict.get(state.owners, id) {
        Ok(o) -> o.pid == pid && o.generation == generation
        Error(Nil) -> False
      })
      actor.continue(state)
    }
    Release(id, pid, generation, reply) ->
      case dict.get(state.owners, id) {
        Ok(o) if o.pid == pid && o.generation == generation -> {
          process.demonitor_process(o.monitor)
          process.send(reply, release_row(state, id, generation))
          actor.continue(State(..state, owners: dict.delete(state.owners, id)))
        }
        _ -> {
          process.send(reply, Error(storage.StaleOwner))
          actor.continue(state)
        }
      }
    OwnerOf(id, reply) -> {
      process.send(
        reply,
        dict.get(state.owners, id)
          |> result.map(fn(o) { o.pid })
          |> option.from_result,
      )
      actor.continue(state)
    }
    OwnerDown(process.ProcessDown(monitor:, ..)) -> {
      let owners = dict.filter(state.owners, fn(_, o) { o.monitor != monitor })
      actor.continue(State(..state, owners:))
    }
    OwnerDown(process.PortDown(..)) -> actor.continue(state)
  }
}

fn record_decoder() -> decode.Decoder(Record) {
  use revision <- decode.field(0, decode.int)
  use generation <- decode.field(1, decode.int)
  use cancelled <- decode.field(2, decode.bool)
  use data <- decode.field(3, decode.bit_array)
  decode.success(Record(revision, generation, cancelled, data))
}

fn create(
  store: SagaStore,
  id: String,
  data: BitArray,
) -> Result(Record, storage.Error) {
  use returned <- result.try(
    pog.query(
      "INSERT INTO saga_executions (id, revision, generation, data)
       VALUES ($1, 0, 0, $2) ON CONFLICT (id) DO NOTHING
       RETURNING revision, generation, cancelled, data",
    )
    |> pog.parameter(pog.text(id))
    |> pog.parameter(pog.bytea(data))
    |> pog.returning(record_decoder())
    |> pog.execute(store.conn)
    |> result.map_error(io),
  )
  case returned.rows {
    [record] -> Ok(record)
    _ -> Error(storage.AlreadyExists)
  }
}

fn load(store: SagaStore, id: String) -> Result(Record, storage.Error) {
  load_row(store.conn, id) |> result.map(fn(row) { row.0 })
}

fn load_row(
  conn: pog.Connection,
  id: String,
) -> Result(#(Record, Option(String)), storage.Error) {
  use returned <- result.try(
    pog.query(
      "SELECT revision, generation, cancelled, data, owner_vm
       FROM saga_executions WHERE id = $1",
    )
    |> pog.parameter(pog.text(id))
    |> pog.returning({
      use record <- decode.then(record_decoder())
      use vm <- decode.field(4, decode.optional(decode.string))
      decode.success(#(record, vm))
    })
    |> pog.execute(conn)
    |> result.map_error(io),
  )
  case returned.rows {
    [row] -> Ok(row)
    _ -> Error(storage.NotFound)
  }
}

fn claim_row(state: State, id: String) -> Result(Record, storage.Error) {
  use returned <- result.try(
    pog.query(
      "UPDATE saga_executions
       SET generation = generation + 1, owner_vm = $2,
           lease_until = now() + ($3::text)::interval
       WHERE id = $1
         AND (owner_vm IS NULL OR owner_vm = $2 OR lease_until < now())
       RETURNING revision, generation, cancelled, data",
    )
    |> pog.parameter(pog.text(id))
    |> pog.parameter(pog.text(state.vm))
    |> pog.parameter(pog.text(state.lease))
    |> pog.returning(record_decoder())
    |> pog.execute(state.conn)
    |> result.map_error(io),
  )
  case returned.rows {
    [record] -> Ok(record)
    _ ->
      case load_row(state.conn, id) {
        Ok(_) -> Error(storage.Busy)
        Error(error) -> Error(error)
      }
  }
}

fn commit(
  store: SagaStore,
  id: String,
  generation: Int,
  revision: Int,
  cancelled: Bool,
  data: BitArray,
) -> Result(Record, storage.Error) {
  use returned <- result.try(
    pog.query(
      "UPDATE saga_executions
       SET revision = revision + 1, data = $5,
           lease_until = now() + ($7::text)::interval
       WHERE id = $1 AND generation = $2 AND revision = $3
         AND cancelled = $4 AND owner_vm = $6
       RETURNING revision, generation, cancelled, data",
    )
    |> pog.parameter(pog.text(id))
    |> pog.parameter(pog.int(generation))
    |> pog.parameter(pog.int(revision))
    |> pog.parameter(pog.bool(cancelled))
    |> pog.parameter(pog.bytea(data))
    |> pog.parameter(pog.text(store.vm))
    |> pog.parameter(pog.text(store.lease))
    |> pog.returning(record_decoder())
    |> pog.execute(store.conn)
    |> result.map_error(io),
  )
  case returned.rows {
    [record] -> Ok(record)
    _ -> {
      use #(current, vm) <- result.try(load_row(store.conn, id))
      let owned = current.generation == generation && vm == Some(store.vm)
      Error(case owned, current.cancelled == cancelled {
        False, _ -> storage.StaleOwner
        True, False -> storage.CancellationChanged
        True, True -> storage.Conflict
      })
    }
  }
}

fn release_row(
  state: State,
  id: String,
  generation: Int,
) -> Result(Nil, storage.Error) {
  use returned <- result.try(
    pog.query(
      "UPDATE saga_executions SET owner_vm = NULL, lease_until = NULL
       WHERE id = $1 AND generation = $2 AND owner_vm = $3",
    )
    |> pog.parameter(pog.text(id))
    |> pog.parameter(pog.int(generation))
    |> pog.parameter(pog.text(state.vm))
    |> pog.execute(state.conn)
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
    |> pog.execute(store.conn)
    |> result.map_error(io),
  )
  case returned.count {
    1 -> Ok(Nil)
    _ -> Error(storage.NotFound)
  }
}

fn io(error: pog.QueryError) -> storage.Error {
  storage.Io(string.inspect(error))
}
