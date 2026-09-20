# Grind uniqueness contract

## Question and status

- The experiment asks how Grind can admit one typed job under a uniqueness policy without constructing a `JobHandle(output, error)` from an incompatible conflict.
- The current laboratory retains `Worker(input, output, error)`, versioned worker identity, encoded admission, and `JobHandle(output, error)`. It has no queue identity, uniqueness policy, conflict result, replacement result, or unknown-commit result.
- This note proposes a pure interface probe followed by a PostgreSQL oracle. It does not establish durable uniqueness, replacement, or commit reconciliation.
- The uniqueness sketch in [`grind-design.md`](../grind-design.md) names an older default state set. Oban 2.24.1 defaults to its `successful` state group, which also includes `suspended` and `completed` jobs.

## Pinned upstream sources

- The reference is Apache-2.0 [Oban 2.24.1](https://hex.pm/packages/oban/2.24.1), with the exact [tag and test tree](https://github.com/oban-bg/oban/tree/v2.24.1).
- The public contract is the [Oban 2.24.1 unique-jobs guide](https://oban.hexdocs.pm/2.24.1/unique_jobs.html).
- Option validation, defaults, named state groups, and replacement fields come from [`Oban.Job` at `v2.24.1`](https://github.com/oban-bg/oban/blob/v2.24.1/lib/oban/job.ex).
- Conflict selection, period comparison, advisory locking, and replacement execution come from the [Basic engine at `v2.24.1`](https://github.com/oban-bg/oban/blob/v2.24.1/lib/oban/engines/basic.ex).
- The sources were inspected. Their PostgreSQL tests were not run in this repository, so database behavior remains an oracle obligation.

## Upstream uniqueness behavior

- Uniqueness applies when a job is inserted. It does not limit concurrent execution of jobs that are already present.
- Basic applies per-job uniqueness to single insertion. Basic bulk insertion does not apply each changeset's uniqueness policy.
- A list-valued policy defaults to a 60-second period. `unique: true` selects an infinite period while a matching job remains stored.
- A finite period must be positive. It may use `inserted_at` or `scheduled_at`, with `inserted_at` as the default timestamp.
- Basic includes a job at the exact finite cutoff because its query uses `timestamp >= now - period`. An infinite period adds no timestamp condition.
- A future `scheduled_at` extends the effective uniqueness interval beyond the insertion time. This follows from applying the same inclusive cutoff to the selected timestamp.

## Upstream scope and states

- The selectable fields are `args`, `meta`, `queue`, and `worker`. The default is `args`, `queue`, and `worker`.
- Omitting `queue` makes otherwise matching jobs conflict across queues. Omitting `worker` makes otherwise matching jobs conflict across workers.
- `keys` narrows only `args` or `meta`. Basic stringifies the selected keys, extracts those entries, and compares the resulting JSON maps.
- Basic compares a complete `args` or `meta` map in both containment directions. It compares a nonempty selected-key map by containment, while an empty selected-key projection follows a separate reverse-containment branch.
- The named `incomplete` group contains `suspended`, `available`, `scheduled`, `executing`, and `retryable`.
- The named `scheduled` group contains only `scheduled`. The named `all` group contains every job state.
- The default `successful` group contains `suspended`, `available`, `scheduled`, `executing`, `retryable`, and `completed`. It excludes `cancelled` and `discarded`.
- A custom state list may contain any persisted state. Oban only warns when it contains none of the insertion states (`suspended`, `available`, or `scheduled`), so such a policy can miss the initial duplicate.

## Upstream conflict and replacement behavior

- A matching insertion returns `{:ok, job}` with the virtual `conflict?` field set to `true`. A non-conflicting insertion returns a persisted job with `conflict?` set to `false`.
- A Basic advisory-lock miss also returns a success-shaped job with `conflict?` set to `true`, but its `id` is `nil`. This value identifies contention rather than an existing persisted job.
- Basic acquires a transaction-scoped advisory lock before querying and inserting. Its lock key incorporates the configured database prefix, while the guide states that query-and-lock uniqueness remains susceptible to races in some circumstances.
- Replacement does not have a distinct upstream result. A retained conflict and an updated conflict both return a job with `conflict?` set to `true`.
- Replacement may target any persisted state. The replaceable fields are `args`, `max_attempts`, `meta`, `priority`, `queue`, `scheduled_at`, `tags`, and `worker`.
- A state-specific replacement applies only the fields listed for the conflicting job's current state. A flat replacement field list expands to every state.
- Basic copies only listed fields that are present in the incoming changeset. A listed field that is absent from the changeset does not alter the existing row.
- Replacing `args` for an `executing` job updates storage while the running process continues with its original arguments. Replacing `worker` can likewise change the persisted execution contract for a later attempt.

## Conservative Gleam profile

- The exact interface question is whether one prepared unique submission can retain typed key construction, worker contract identity, queue scope, and reconciliation identity while returning a typed handle only after a compatible persisted contract is known.
- The first profile always includes `WorkerId` and `WorkerVersion` in the uniqueness identity. Cross-worker uniqueness is deferred because a conflict with another worker cannot supply the submitting worker's output and error codecs safely.
- Queue scope is explicit as `WithinQueue` or `AcrossQueues`. The current callback-only `Queue` must gain one validated queue name in `Admission`, because queue scope cannot be evidenced from an unnamed callback.
- Full-input uniqueness reuses the input encoded for admission. Selected-input uniqueness uses a typed projection and its own `Codec(key)`, so callers never name raw JSON keys or cast a foreign value.
- Period origin and duration are explicit. The profile has no implicit 60-second default.
- The first state profile exposes the four named groups (`Incomplete`, `ScheduledOnly`, `NotCancelledOrDiscarded`, and `AllRetained`). Arbitrary lists remain deferred until Grind's persisted state vocabulary is reconciled with the current typed `JobState`.

```gleam
pub type QueueScope {
  WithinQueue
  AcrossQueues
}

pub type UniqueTimestamp {
  FromInsertion
  FromSchedule
}

pub type UniquePeriod {
  For(period: PositiveDuration, from: UniqueTimestamp)
  WhileRetained
}

pub type UniqueStates {
  Incomplete
  ScheduledOnly
  NotCancelledOrDiscarded
  AllRetained
}

pub opaque type Uniqueness(input)

pub fn full_input(
  scope: QueueScope,
  period: UniquePeriod,
  states: UniqueStates,
) -> Uniqueness(input)

pub fn selected_input(
  scope: QueueScope,
  period: UniquePeriod,
  states: UniqueStates,
  select: fn(input) -> key,
  key_codec: Codec(key),
) -> Uniqueness(input)
```

- `NotCancelledOrDiscarded` is the direct public name for Oban's `successful` group. The name states the actual included-state rule rather than implying that every selected job has completed successfully.
- `PositiveDuration` rejects zero and negative periods before admission. A pure cutoff function uses the same inclusive comparison intended for the database oracle.
- A selected key is encoded before the queue callback runs. Key encoding failure remains distinct from input encoding failure and storage admission failure.

## Conflict action and result

- The first conflict action is either `KeepExisting` or `RescheduleScheduled`. The latter replaces only `AvailableAt` and only when the persisted conflict is scheduled.
- A non-scheduled conflict under `RescheduleScheduled` remains unchanged and returns `Existing`. The profile does not replace input, worker, version, or queue.
- `Conflict` retains the persisted job identifier, worker identifier, worker version, queue name, and conflict state. It does not expose a constructor or any encoded output and error values.
- `Conflict` is not a `JobHandle`. A separate binding function compares the persisted worker identifier and version with the supplied `Worker(input, output, error)` before using that worker's output and error codecs.

```gleam
pub type ConflictAction {
  KeepExisting
  RescheduleScheduled
}

pub type UniqueAdmission(output, error) {
  Inserted(JobHandle(output, error))
  Existing(Conflict)
  Rescheduled(Conflict)
}

pub type UniqueSubmitError {
  UniqueInputCouldNotEncode(EncodeError)
  UniqueKeyCouldNotEncode(EncodeError)
  UniqueAdmissionFailed(AdmissionError)
  UniqueAdmissionContended
  UniqueCommitUnknown(SubmissionId)
  UniqueBackendContractViolated
}

pub fn submit_unique(
  queue: Queue,
  submission_id: SubmissionId,
  worker: Worker(input, output, error),
  input: input,
  availability: Availability,
  uniqueness: Uniqueness(input),
  on_conflict: ConflictAction,
) -> Result(UniqueAdmission(output, error), UniqueSubmitError)

pub fn bind_conflict(
  worker: Worker(input, output, error),
  conflict: Conflict,
) -> Result(JobHandle(output, error), ConflictContractError)
```

- `UniqueAdmissionContended` maps a known failure to acquire the uniqueness lock before insertion. It does not claim that a conflicting job exists.
- `UniqueCommitUnknown` means the adapter cannot establish whether admission or replacement committed. It returns no `JobHandle` and does not authorize blind resubmission.
- `SubmissionId` identifies one stable admission command independently of the uniqueness key. Reconciliation uses that command identity because a retry may occur after the selected period or state no longer matches.
- `UniqueBackendContractViolated` covers a backend response whose persisted identity or replacement fact contradicts the submitted contract. It must not be converted into a typed handle.

## Decisive pure probes

- Prepare two submissions with the same full typed input. Require equal encoded uniqueness identities without invoking either worker.
- Select one typed key from inputs that differ elsewhere. Require a conflict for equal selected keys and admission for distinct selected keys.
- Use the same worker and key in two queues. Require `WithinQueue` to admit both and `AcrossQueues` to conflict.
- Change only `WorkerVersion`. Require distinct uniqueness identities because the first profile always includes worker contract identity.
- Evaluate a finite period at an injected clock. Require a timestamp exactly at the cutoff to match and one clock unit before the cutoff not to match.
- Select `FromSchedule` with a future schedule. Require the pure comparison to retain the job until the configured period after that schedule.
- Resolve a scheduled conflict under `RescheduleScheduled` as `Rescheduled`. Resolve an executing conflict under the same action as unchanged `Existing`.
- Bind a conflict with the matching worker identifier and version. Require a typed handle with the existing job identifier.
- Bind a conflict with a different worker identifier or version. Require `ConflictContractError`, with no path to a `JobHandle`.
- Distinguish a scripted lock miss from a persisted conflict. Require `UniqueAdmissionContended` for the former and `Existing(Conflict)` for the latter.
- Return a scripted uncertain store result. Require `UniqueCommitUnknown` to retain the original `SubmissionId` and return no handle.
- Add compiler-negative consumers that reject a key codec for another projected type and reject use of `Conflict` where `JobHandle(output, error)` is required.

## Native oracle

- Run competing PostgreSQL inserts for the same uniqueness identity. Record inserted, persisted-conflict, and lock-contention outcomes without treating all three as one conflict.
- Exercise separate database prefixes and every supported queue scope. Establish whether advisory-lock hashing and query prefixing preserve the intended namespace under concurrency.
- Insert at, immediately before, and immediately after the finite cutoff. Repeat for `inserted_at`, a past `scheduled_at`, and a future `scheduled_at` to establish timestamp precision and clock sampling.
- Compare full and selected JSON maps with reordered keys, nested values, missing selected keys, and empty selected projections. Match the pinned Basic query rather than assuming language-level map equality.
- Move matching jobs through each selected state and attempt insertion at every transition. Include pruning because `WhileRetained` ceases to conflict after the row is removed.
- Replace scheduled availability concurrently with staging and cancellation. Require one committed row and an explicit stale, unavailable, or unknown result when the update cannot be established.
- Attempt replacement while a job executes. Confirm that the stored row changes while the running process retains its original arguments, then keep that behavior outside the conservative public replacement profile.
- Interrupt admission before send, during the transaction, after commit, and before reply. Reconcile by `SubmissionId` and never infer commit from a later uniqueness conflict alone.
- Confirm that Basic bulk insertion does not honor per-job uniqueness. Grind must either reject unique bulk admission or implement and test its own atomic contract.
- Run a separate oracle for SQLite if Grind retains it. PostgreSQL Basic behavior does not establish SQLite locking, JSON comparison, or time semantics.

## Acceptance boundary

- Pure probes can establish typed key construction, explicit scope selection, inclusive cutoff arithmetic, conflict classification, replacement selection, and safe handle binding.
- Pure probes cannot establish durable exclusion, clock precision, transaction isolation, advisory-lock behavior, state-transition races, pruning, replacement commits, or reconciliation after connection loss.
- Uniqueness prevents selected duplicate admission only. It does not establish execution serialization, exactly-once effects, downstream idempotency, or a typed result for an incompatible existing job.
- General field replacement, cross-worker uniqueness, arbitrary state lists, unique bulk insertion, and backend-specific optimizations remain outside the first profile.
