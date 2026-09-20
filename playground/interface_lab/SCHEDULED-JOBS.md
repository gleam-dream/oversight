<!-- THROWAWAY: Can typed scheduled admission and cancellation compose without running a queue? -->

# Scheduled jobs and cancellation intent

## Decision

- Immediate and scheduled submission use the same `Queue` and `Admission` representation.
- Admission retains worker identity, worker version, encoded payload, and explicit availability.
- `AvailableAt` contains absolute Unix milliseconds, with a getter for storage adapters. It is not a relative delay or a timezone policy.
- `submit_at` returns the same typed job handle as `submit`. Admission does not execute the worker.
- Scheduled job state retains its availability time.
- Cancellation of scheduled, queued, or suspended work produces terminal cancellation while inactive. This says nothing about effects from earlier attempts.
- Cancellation of running work records cooperative intent. It does not interrupt the worker or guarantee cancellation beats completion.
- Already-cancelled and already-finished results remain distinct, preserving a finished job's typed outcome.

## Evidence

- `scheduled_jobs` uses injected queue admission to check exact worker/version/payload/time and returned handle identity.
- The immediate path retains `Immediate` availability.
- A scripted worker must not run during either admission.
- Pure transitions check scheduled, queued, suspended, running, already-cancelled, and finished states.
- `scheduled_input` fails compilation when scheduled submission receives the wrong worker input type.
- This wave extends the existing queue interface rather than introducing a parallel scheduling package.

- The combined laboratory passed twenty-two isolated consumers, twenty-three intended compiler failures, and fourteen executable probe groups on Gleam 1.18.1.

## Limits and next contract

- Queue callbacks are injected fakes. No database, clock, timer, wakeup, lease, retry, supervisor, or worker process runs.
- `cancel` and `poll` remain explicit runtime boundaries. Cancellation can fail because the job is missing or storage is unavailable.
- A real adapter must atomically load and persist the cancellation transition and resolve completion races.
- Repeated intent does not grant exactly-once delivery or effect guarantees. An already performed external effect is not reversed by cancellation.
- Recurring schedules, timezone rules, missed runs, cancellation observation by running handlers, retry policy, and abandoned-job rescue remain later contracts.
- The low-level admission seam carries persisted worker identity data. Typed registration and submission remain the preferred application surface.
- Saga's durable runner still owns workflow progress and compensation; scheduled Grind admission does not implement graph recovery.
