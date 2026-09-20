// THROWAWAY: Can a standalone job supply dependencies without a workflow stack?
import lab/blueprint
import lab/grind
import lab/value

pub type AccountId {
  AccountId(Int)
}

pub type JobError {
  AccountUnavailable
}

pub fn worker(
  load: fn(AccountId) -> Result(String, JobError),
) -> grind.Worker(AccountId, String, JobError) {
  let assert Ok(id) = grind.worker_id("refresh-account")
  let assert Ok(version) = grind.worker_version(1)
  let input =
    blueprint.imap(blueprint.int(), AccountId, fn(id) {
      let AccountId(value) = id
      value
    })
  let error =
    blueprint.new(fn(_) { Ok(value.Text("unavailable")) }, fn(raw) {
      case raw {
        value.Text("unavailable") -> Ok(AccountUnavailable)
        _ -> Error(blueprint.CannotDecode("Expected account error"))
      }
    })
  grind.worker(id, version, input, blueprint.text(), error, load)
}

// Only IDs are persisted. The deployed worker supplies its current dependencies.
pub fn submit(
  queue: grind.Queue,
  load: fn(AccountId) -> Result(String, JobError),
  id: AccountId,
) -> Result(grind.JobHandle(String, JobError), grind.SubmitError) {
  grind.submit(queue, worker(load), id)
}

pub fn probe() -> Nil {
  let job =
    worker(fn(id) {
      case id {
        AccountId(1) -> Ok("loaded with injected dependency")
        _ -> Error(AccountUnavailable)
      }
    })
  let assert Ok("loaded with injected dependency") =
    grind.invoke(job, AccountId(1))
  let assert Error(AccountUnavailable) = grind.invoke(job, AccountId(2))
  Nil
}
