//// One Grind job, `mailer.send`, driven through its stored states by the
//// reader. Every transition is a row update; the history is the row's story.

import gleam/int
import gleam/list

/// The states Grind stores for a job row.
pub type Stored {
  Queued
  Scheduled
  Retryable
  Executing
  Succeeded
  BusinessFailed
  RuntimeFailed
  ContractMismatch
  Uncertain
  Discarded
  Cancelled
}

/// Before submission there is no row yet.
pub type Phase {
  NotSubmitted
  Stored(Stored)
}

/// What Grind does with an attempt whose node died mid-effect.
pub type Abandonment {
  /// The default: keep the job as Uncertain until someone resolves it.
  HoldUncertain
  /// Opt-in for handlers that are safe to repeat.
  ReplayAfterLeaseExpiry
}

pub type Job {
  Job(phase: Phase, attempts: Int, history: List(String))
}

/// What can happen to the job next.
pub type Event {
  SubmitNow
  SubmitLater
  TimeArrives
  Cancel
  Claim
  BackoffPasses
  HandlerSucceeds
  HandlerFails
  HandlerSnoozes
  HandlerDiscards
  NodeDies
  AuditSent
  AuditNotSent
  StartOver
}

pub const max_attempts = 3

const nothing_yet = "Nothing submitted yet."

pub fn new() -> Job {
  Job(phase: NotSubmitted, attempts: 0, history: [nothing_yet])
}

/// The tiles of the state machine, as the playground shows them.
pub const shown = [
  #(Scheduled, "waiting for its time"),
  #(Queued, "ready to run"),
  #(Executing, "claimed, leased"),
  #(Retryable, "failed, will retry"),
  #(Succeeded, "output stored"),
  #(BusinessFailed, "out of attempts"),
  #(Uncertain, "effect unknown"),
  #(Discarded, "handler gave up"),
  #(Cancelled, "stopped by you"),
]

pub fn is_terminal(state: Stored) -> Bool {
  case state {
    Succeeded
    | BusinessFailed
    | RuntimeFailed
    | ContractMismatch
    | Discarded
    | Cancelled -> True
    Queued | Scheduled | Retryable | Executing | Uncertain -> False
  }
}

pub fn name(state: Stored) -> String {
  case state {
    Queued -> "Queued"
    Scheduled -> "Scheduled"
    Retryable -> "Retryable"
    Executing -> "Executing"
    Succeeded -> "Succeeded"
    BusinessFailed -> "BusinessFailed"
    RuntimeFailed -> "RuntimeFailed"
    ContractMismatch -> "ContractMismatch"
    Uncertain -> "Uncertain"
    Discarded -> "Discarded"
    Cancelled -> "Cancelled"
  }
}

pub fn title(phase: Phase) -> String {
  case phase {
    NotSubmitted -> "Not submitted"
    Stored(state) -> name(state)
  }
}

pub fn why(phase: Phase) -> String {
  case phase {
    NotSubmitted -> "Submit the job. Grind writes a row before anything runs."
    Stored(Scheduled) ->
      "The row waits for its time. A snoozed job comes back here too."
    Stored(Queued) ->
      "Ready. A coordinator for the \"mailers\" queue will claim it when it has local capacity."
    Stored(Executing) ->
      "Claimed under a database lease. An attempt process runs your handler; a separate renewer keeps the lease alive on its own connection."
    Stored(Retryable) ->
      "Failed, with attempts left. It will be queued again after a backoff."
    Stored(Succeeded) ->
      "Done. The typed output is stored in the row, and anyone can await it."
    Stored(BusinessFailed) ->
      "Out of attempts. The last error is stored. Terminal."
    Stored(RuntimeFailed) ->
      "The input could not be decoded, or the handler's output or error was rejected by its codec. Terminal, with no retry."
    Stored(ContractMismatch) ->
      "The stored codec versions no longer match the registered worker. Terminal."
    Stored(Uncertain) ->
      "The attempt was abandoned mid-effect. By default Grind doesn’t guess whether the email went out: an operator resolves it with evidence, and the resolution is audited. Replay is opt-in, for handlers where repeating is safe."
    Stored(Discarded) ->
      "The handler decided this job should never run again. Terminal."
    Stored(Cancelled) -> "Stopped before it ran. Terminal."
  }
}

/// A button the reader can press next.
pub type Choice {
  Choice(label: String, event: Event, warn: Bool)
}

/// The labels are the same whatever the abandonment setting: it only changes
/// where a dead node leads.
pub fn choices(job: Job) -> List(Choice) {
  let ok = fn(label, event) { Choice(label:, event:, warn: False) }
  let warn = fn(label, event) { Choice(label:, event:, warn: True) }
  case job.phase {
    NotSubmitted -> [
      ok("Submit now", SubmitNow),
      ok("Submit for 10 minutes from now", SubmitLater),
    ]
    Stored(Scheduled) -> [
      ok("The time arrives", TimeArrives),
      warn("Cancel it", Cancel),
    ]
    Stored(Retryable) -> [ok("Backoff passes", BackoffPasses)]
    Stored(Queued) -> [ok("A coordinator claims it", Claim)]
    Stored(Executing) -> [
      ok("Handler returns Ok", HandlerSucceeds),
      Choice(
        label: "Handler returns an error",
        event: HandlerFails,
        warn: job.attempts >= max_attempts,
      ),
      ok("Handler asks to snooze 5 min", HandlerSnoozes),
      warn("Handler discards the job", HandlerDiscards),
      warn("The node dies mid-attempt", NodeDies),
    ]
    Stored(Uncertain) -> [
      ok("Audit: the email was sent", AuditSent),
      ok("Audit: it was not sent", AuditNotSent),
    ]
    Stored(_) -> [ok("Start over with a new job", StartOver)]
  }
}

/// Apply an event. Events that make no sense in the current state leave the
/// job unchanged; starting over is always possible.
pub fn apply(job: Job, event: Event, abandonment: Abandonment) -> Job {
  let n = job.attempts
  let attempt = "attempt " <> int.to_string(n)
  let go = fn(state, line) { record(job, Stored(state), n, line) }
  case job.phase, event {
    _, StartOver -> new()
    NotSubmitted, SubmitNow -> go(Queued, "submit → Queued (row inserted)")
    NotSubmitted, SubmitLater -> go(Scheduled, "submit at +10m → Scheduled")
    Stored(Scheduled), TimeArrives ->
      go(Queued, "scheduled time reached → Queued")
    Stored(Scheduled), Cancel -> go(Cancelled, "cancelled → Cancelled")
    Stored(Retryable), BackoffPasses -> go(Queued, "backoff elapsed → Queued")
    Stored(Queued), Claim ->
      record(
        job,
        Stored(Executing),
        n + 1,
        "claimed with a lease → Executing (attempt "
          <> int.to_string(n + 1)
          <> ")",
      )
    Stored(Executing), HandlerSucceeds ->
      go(Succeeded, attempt <> ": Ok(\"msg:ada@example.com\") → Succeeded")
    Stored(Executing), HandlerFails ->
      case n < max_attempts {
        True -> go(Retryable, attempt <> ": Error(SmtpTimeout) → Retryable")
        False ->
          go(
            BusinessFailed,
            attempt <> ": Error(SmtpTimeout), no attempts left → BusinessFailed",
          )
      }
    Stored(Executing), HandlerSnoozes ->
      go(Scheduled, attempt <> ": snooze 5m → Scheduled")
    Stored(Executing), HandlerDiscards ->
      go(Discarded, attempt <> ": discard → Discarded")
    Stored(Executing), NodeDies ->
      case abandonment {
        HoldUncertain ->
          go(
            Uncertain,
            "node lost; lease expired → held as Uncertain (did the email go out?)",
          )
        ReplayAfterLeaseExpiry ->
          go(
            Queued,
            "node lost; lease expired → replayed (you declared replay safe, up to a max) → Queued",
          )
      }
    Stored(Uncertain), AuditSent ->
      go(
        Succeeded,
        "operator resolution (audited): effect happened → Succeeded",
      )
    Stored(Uncertain), AuditNotSent ->
      go(
        Queued,
        "operator resolution (audited): effect did not happen → Queued",
      )
    _, _ -> job
  }
}

/// The newest line first, at most ten, without the placeholder.
fn record(job: Job, phase: Phase, attempts: Int, line: String) -> Job {
  let history =
    [line, ..list.filter(job.history, fn(l) { l != nothing_yet })]
    |> list.take(10)
  Job(phase:, attempts:, history:)
}
