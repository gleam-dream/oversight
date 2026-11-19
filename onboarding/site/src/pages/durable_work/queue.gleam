//// The Grind queue simulation: three workers claim rows from one table under
//// leases, a renewer tops the leases up, and a killed worker's lease drains
//// until the row is held as Uncertain or replayed.
////
//// It advances in ticks (220 ms each in the live widget) and draws from the
//// reference's seeded generator in the same order, so the picture matches.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import pages/durable_work/job.{type Abandonment, HoldUncertain}
import site/rng.{type Rng}

/// A lease lasts this many ticks unless renewed.
pub const lease_ticks = 15

/// The renewer runs every this many ticks.
pub const renew_every = 5

/// Seconds per tick in the live widget.
pub const tick_seconds = 0.22

pub type RowState {
  Available
  /// Claimed by a worker (by index) under a lease; `work` ticks remain of
  /// `work0`.
  Running(owner: Int, lease: Int, work: Int, work0: Int)
  /// The handler failed; the row waits out a backoff of `wait` ticks.
  RetryLater(wait: Int)
  Done
  HeldUncertain
}

pub type Row {
  Row(id: Int, state: RowState, attempts: Int)
}

pub type Life {
  Alive
  Dead
}

/// `job` is the row the worker last claimed and has not yet released.
pub type Worker {
  Worker(life: Life, job: Option(Int))
}

pub type Queue {
  Queue(
    rows: List(Row),
    workers: List(Worker),
    expiry: Abandonment,
    ticks: Int,
    renewals: Int,
    done: Int,
    uncertain: Int,
    replays: Int,
    next_id: Int,
    log: List(String),
    rng: Rng,
  )
}

pub fn new() -> Queue {
  Queue(
    rows: list.map(int_range(1, 14), fn(id) {
      Row(id:, state: Available, attempts: 0)
    }),
    workers: list.repeat(Worker(Alive, None), 3),
    expiry: HoldUncertain,
    ticks: 0,
    renewals: 0,
    done: 0,
    uncertain: 0,
    replays: 0,
    next_id: 15,
    log: ["Three workers start. Fourteen jobs are waiting in PostgreSQL."],
    rng: rng.seed(3),
  )
}

fn int_range(low: Int, high: Int) -> List(Int) {
  case low > high {
    True -> []
    False -> [low, ..int_range(low + 1, high)]
  }
}

fn say(queue: Queue, line: String) -> Queue {
  Queue(..queue, log: list.take([line, ..queue.log], 8))
}

// READER AND TOUR VERBS -------------------------------------------------------

pub fn set_expiry(queue: Queue, expiry: Abandonment) -> Queue {
  Queue(..queue, expiry:)
}

/// The table keeps to this many rows while finished rows can make room.
const kept_rows = 21

/// Six more rows. Finished rows make room, oldest first, so the table keeps
/// to 21 rows when it can; unfinished rows always stay.
pub fn add_jobs(queue: Queue) -> Queue {
  let added =
    list.map(int_range(queue.next_id, queue.next_id + 5), fn(id) {
      Row(id:, state: Available, attempts: 0)
    })
  let rows = list.append(queue.rows, added)
  let rows = prune_done(rows, list.length(rows) - kept_rows)
  Queue(..queue, rows:, next_id: queue.next_id + 6)
}

/// Drop up to `excess` finished rows, oldest first.
fn prune_done(rows: List(Row), excess: Int) -> List(Row) {
  case rows {
    _ if excess <= 0 -> rows
    [] -> []
    [Row(state: Done, ..), ..rest] -> prune_done(rest, excess - 1)
    [row, ..rest] -> [row, ..prune_done(rest, excess)]
  }
}

/// Kill a live worker, or restart a dead one empty-handed.
pub fn toggle_worker(queue: Queue, index: Int) -> Queue {
  case worker_at(queue, index) {
    Some(Worker(Alive, job)) ->
      queue
      |> put_worker(index, Worker(Dead, job))
      |> say(name(index) <> " died mid-job.")
    Some(Worker(Dead, _)) ->
      queue
      |> put_worker(index, Worker(Alive, None))
      |> say(name(index) <> " restarted, empty-handed.")
    None -> queue
  }
}

/// Kill a worker if it is alive.
pub fn kill_worker(queue: Queue, index: Int) -> Queue {
  case worker_at(queue, index) {
    Some(Worker(Alive, _)) -> toggle_worker(queue, index)
    _ -> queue
  }
}

pub fn name(index: Int) -> String {
  "W" <> int.to_string(index + 1)
}

pub fn worker_at(queue: Queue, index: Int) -> Option(Worker) {
  case list.drop(queue.workers, index) {
    [worker, ..] -> Some(worker)
    [] -> None
  }
}

fn put_worker(queue: Queue, index: Int, worker: Worker) -> Queue {
  Queue(
    ..queue,
    workers: list.index_map(queue.workers, fn(w, i) {
      case i == index {
        True -> worker
        False -> w
      }
    }),
  )
}

/// Whether the worker is alive and its current claim is this row. A worker
/// restarted empty-handed no longer holds the rows it claimed before.
fn holds(queue: Queue, index: Int, id: Int) -> Bool {
  worker_at(queue, index) == Some(Worker(Alive, Some(id)))
}

/// The row finished or its lease expired: its owner lets go of it, unless
/// the owner has claimed another row since.
fn release(queue: Queue, index: Int, id: Int) -> Queue {
  case worker_at(queue, index) {
    Some(Worker(life, Some(job))) if job == id ->
      put_worker(queue, index, Worker(life, None))
    _ -> queue
  }
}

// TIME ------------------------------------------------------------------------

pub fn advance(queue: Queue, ticks: Int) -> Queue {
  case ticks <= 0 {
    True -> queue
    False -> advance(tick(queue), ticks - 1)
  }
}

/// Let time pass until no lease is draining: every lease nobody renews has
/// expired. A draining lease only shrinks, so this takes at most a full lease.
pub fn advance_until_expired(queue: Queue) -> Queue {
  wait_for_expiry(queue, lease_ticks)
}

fn wait_for_expiry(queue: Queue, budget: Int) -> Queue {
  case budget > 0 && list.any(queue.rows, draining(queue, _)) {
    True -> wait_for_expiry(tick(queue), budget - 1)
    False -> queue
  }
}

/// One tick: renew, claim, then work or drain every row, in that order.
pub fn tick(queue: Queue) -> Queue {
  let queue = Queue(..queue, ticks: queue.ticks + 1)
  queue
  |> renew
  |> claim_all
  |> work_rows
}

fn renew(queue: Queue) -> Queue {
  case queue.ticks % renew_every == 0 {
    False -> queue
    True -> {
      let #(renewed, rows) =
        list.map_fold(queue.rows, 0, fn(renewed, row) {
          case row.state {
            Running(owner:, ..) as running ->
              case holds(queue, owner, row.id) {
                True -> #(
                  renewed + 1,
                  Row(..row, state: Running(..running, lease: lease_ticks)),
                )
                False -> #(renewed, row)
              }
            _ -> #(renewed, row)
          }
        })
      Queue(..queue, rows:, renewals: queue.renewals + renewed)
    }
  }
}

fn claim_all(queue: Queue) -> Queue {
  list.fold(int_range(0, list.length(queue.workers) - 1), queue, claim)
}

/// An idle live worker takes the first available row, skipping rows other
/// workers hold.
fn claim(queue: Queue, index: Int) -> Queue {
  case worker_at(queue, index) {
    Some(Worker(Alive, None)) ->
      case first_available(queue.rows, 0) {
        Error(Nil) -> queue
        Ok(#(id, skipped)) -> {
          let #(draw, rng) = rng.next(queue.rng)
          let work = 6 + float_floor(draw *. 9.0)
          let rows =
            list.map(queue.rows, fn(row) {
              case row.id == id {
                True ->
                  Row(
                    ..row,
                    state: Running(
                      owner: index,
                      lease: lease_ticks,
                      work:,
                      work0: work,
                    ),
                    attempts: row.attempts + 1,
                  )
                False -> row
              }
            })
          let queue =
            Queue(..queue, rows:, rng:)
            |> put_worker(index, Worker(Alive, Some(id)))
          case skipped {
            0 -> queue
            _ ->
              say(
                queue,
                name(index)
                  <> " claimed job "
                  <> int.to_string(id)
                  <> ", skipping "
                  <> int.to_string(skipped)
                  <> " row"
                  <> case skipped > 1 {
                  True -> "s"
                  False -> ""
                }
                  <> " locked by other workers",
              )
          }
        }
      }
    _ -> queue
  }
}

fn first_available(rows: List(Row), skipped: Int) -> Result(#(Int, Int), Nil) {
  case rows {
    [] -> Error(Nil)
    [Row(id:, state: Available, ..), ..] -> Ok(#(id, skipped))
    [Row(state: Running(..), ..), ..rest] -> first_available(rest, skipped + 1)
    [_, ..rest] -> first_available(rest, skipped)
  }
}

fn float_floor(x: Float) -> Int {
  float.truncate(float.floor(x))
}

/// Rows are visited in order; each may change the workers and the counters,
/// so the fold carries the whole queue.
fn work_rows(queue: Queue) -> Queue {
  let ids = list.map(queue.rows, fn(row) { row.id })
  list.fold(ids, queue, work_row)
}

fn work_row(queue: Queue, id: Int) -> Queue {
  case list.find(queue.rows, fn(row) { row.id == id }) {
    Error(Nil) -> queue
    Ok(row) ->
      case row.state {
        RetryLater(wait:) ->
          case wait - 1 <= 0 {
            True -> put_row(queue, Row(..row, state: Available))
            False -> put_row(queue, Row(..row, state: RetryLater(wait - 1)))
          }
        Running(owner:, lease:, work:, work0:) ->
          case holds(queue, owner, row.id) {
            True ->
              case work - 1 <= 0 {
                False ->
                  put_row(
                    queue,
                    Row(
                      ..row,
                      state: Running(owner:, lease:, work: work - 1, work0:),
                    ),
                  )
                True -> finish(release(queue, owner, row.id), row)
              }
            False ->
              case lease - 1 <= 0 {
                False ->
                  put_row(
                    queue,
                    Row(
                      ..row,
                      state: Running(owner:, lease: lease - 1, work:, work0:),
                    ),
                  )
                True -> expire(release(queue, owner, row.id), row)
              }
          }
        Available | Done | HeldUncertain -> queue
      }
  }
}

/// The handler returned: usually Ok, sometimes an error that retries.
fn finish(queue: Queue, row: Row) -> Queue {
  let #(draw, rng) = rng.next(queue.rng)
  let queue = Queue(..queue, rng:)
  case draw <. 0.08 {
    True ->
      queue
      |> put_row(Row(..row, state: RetryLater(10)))
      |> say(
        "job "
        <> int.to_string(row.id)
        <> ": handler returned an error → retry with backoff",
      )
    False ->
      Queue(..put_row(queue, Row(..row, state: Done)), done: queue.done + 1)
  }
}

/// The lease ran out with no result from the dead owner.
fn expire(queue: Queue, row: Row) -> Queue {
  case queue.expiry {
    HoldUncertain ->
      Queue(
        ..put_row(queue, Row(..row, state: HeldUncertain)),
        uncertain: queue.uncertain + 1,
      )
      |> say(
        "job "
        <> int.to_string(row.id)
        <> ": lease expired with no result → held as Uncertain (did the email go out?)",
      )
    job.ReplayAfterLeaseExpiry ->
      Queue(
        ..put_row(queue, Row(..row, state: Available)),
        replays: queue.replays + 1,
      )
      |> say(
        "job "
        <> int.to_string(row.id)
        <> ": lease expired → replayed, because you declared it safe to repeat",
      )
  }
}

fn put_row(queue: Queue, row: Row) -> Queue {
  Queue(
    ..queue,
    rows: list.map(queue.rows, fn(r) {
      case r.id == row.id {
        True -> row
        False -> r
      }
    }),
  )
}

// READING ---------------------------------------------------------------------

/// Whether a running row's owner no longer holds it, because it died or was
/// restarted, so nobody renews the lease and it drains.
pub fn draining(queue: Queue, row: Row) -> Bool {
  case row.state {
    Running(owner:, ..) -> !holds(queue, owner, row.id)
    _ -> False
  }
}

pub fn row(queue: Queue, id: Int) -> Option(Row) {
  case list.find(queue.rows, fn(r) { r.id == id }) {
    Ok(r) -> Some(r)
    Error(Nil) -> None
  }
}

pub fn count(queue: Queue, keep: fn(RowState) -> Bool) -> Int {
  list.count(queue.rows, fn(r) { keep(r.state) })
}
