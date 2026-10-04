# research_agent — composition feedback

## Verdict

The combination works through public imports. A Grind job drives a Fabric agent
whose conversation is checkpointed in PostgreSQL by `fabric_postgres`. A
durable Saga publishes the result and deletes the draft when publishing fails.
Cancelling through the API stops the job, the run and the LLM stream. After a
`SIGKILL` of the VM in the middle of a model call, the replayed job resumes the
run: it repeats the lost model call only, and does not repeat the search. All 8
tests pass, and `gleam run` prints the four-scenario narrative.

The three durable runtimes compose only through app-owned glue, about 900
lines, much of it per seam (see the glue measure):

- A Postgres saga storage adapter (262 lines).
- A join table that ties the job id to the run id.
- A replay sweep for jobs that Grind abandons to an operator.
- Reconciliation of read-only tools interrupted by a crash.
- A cancellation fan-out.

Fabric, Grind and Saga each ship their own lease, recovery, retry and
cancellation machinery. None of them can hand an identity, a lease or a
cancellation to another, so the app owns the joins (RA-1).

## Answers to the brief's questions

- **Which package owns durability, and is it clear?** It is not clear from the
  packages; the app had to decide. Each package offers a complete durable
  runtime for the same request: Grind (job lease, quarantine, retry policy),
  Fabric (leased run store, `recover`, `sweeper`, model retries) and Saga
  (claimed checkpoint, resolvers, compensation). The working split is:
  - Grind owns delivery.
  - Fabric owns the conversation.
  - Saga owns the publication's effects.
  - The app owns a `research` row that joins them.

  Fabric's own automatic recovery (`fabric.sweeper`) cannot be used here. It
  would resume the run on any node, but nothing would then publish, because
  publishing lives in the job (RA-1).

- **How much glue does persisting llm_wire conversations need?** None in the
  app. Fabric stores every assistant turn with its llm_wire data in its own
  envelope (fabric/src/fabric/llm.gleam:202-324, about 120 lines). The app reads
  the checkpointed conversation from `snapshot.transcript` (6 messages after 3
  turns, test at research_agent_test.gleam:101). The envelope is private, so an
  app that persists llm_wire turns without Fabric still has to write its own,
  as the llm_wire card says.
- **Do fabric, grind and saga each reimplement leases, retries and recovery?**
  Yes. One request in this app runs under three leases, three recovery entry
  points, three retry policies, three cancellation commands and three codec
  systems:

  | Concern      | grind                                                                      | fabric                                                                      | saga                                                                              |
  | ------------ | -------------------------------------------------------------------------- | --------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
  | Lease        | `QueuePolicy.lease_duration_ms` (6 s here), renewer (queue.gleam:76)       | `fabric_postgres.with_lease` (1–3 s here), `store.leased` (store.gleam:473) | `Storage.claim`/generation (storage.gleam:18); lease is the adapter's (10 s here) |
  | Recovery     | quarantine to `uncertain`, `resolve_uncertain` (postgres.gleam:1572, :777) | `recover`, `sweeper` (fabric.gleam:263, :936)                               | `durable.drive` with `recoverable` resolvers (saga.gleam:1747)                    |
  | Retry        | `with_retry_policy` (worker.gleam:116)                                     | `Limits.model_retry_delay` (agent.gleam:70)                                 | `compensate` decider (saga.gleam:339)                                             |
  | Cancellation | `postgres.cancel` (postgres.gleam:1273)                                    | `fabric.cancel`/`cancel_stored` (fabric.gleam:682, :704)                    | `durable.cancel` (durable.gleam:138)                                              |
  | Codec        | `worker.codec` over gleam_json (worker.gleam:21)                           | json_blueprint `Codec`                                                      | `codec.new` over `String` (codec.gleam:13)                                        |

## Findings

### RA-1 Three durable runtimes, no shared identity: the app owns every join

- **Packages**: grind, fabric, saga. **Kind**: composition. **Severity**: major.
- **Evidence**:
  - Grind gives the handler only its input (grind/src/grind/worker.gleam:147-158).
    Fabric issues its own run id (fabric/src/fabric.gleam:210). Saga's
    execution id is the caller's. None of the three can store another's
    identity, so the app keeps a `research` row with `job_id` and `run_id`
    (apps/research_agent/src/research_agent/db.gleam:1-144). It writes the row
    at submission and at run start (app.gleam:233-243,
    jobs.gleam:186-203).
  - The job handler is a hand-written state machine over Fabric's status
    (jobs.gleam:152-232, 81 lines). It starts or recovers the run, awaits it,
    recovers again on `Unattended`, reconciles on `Suspended`, starts afresh
    after a "no sources" answer, and maps each end to a `WorkerResponse`.
  - Fabric's sweeper (fabric/src/fabric.gleam:936) would resume a run whose
    lease expired, but the publication step lives in the Grind job. A run
    resumed by the sweeper finishes and nothing publishes it, so the app
    leaves the sweeper unregistered. Fabric's S8 Grind integration is still
    blocked (fabric card, "Composition seams").
- **Proposal**: write down the ownership split in the design docs: Grind
  delivers, Fabric holds the conversation, Saga holds external effects. Then
  ship the integration it implies in `fabric` (the planned S8, as a
  `fabric_grind` package): `fabric_grind.worker(agent, context, on_end)`. It
  would derive the run id from the job (see RA-2, RA-3), drive the run, and
  return the `WorkerResponse`. RA-2, RA-3 and RA-5 are the smallest
  package-side changes that make that adapter possible.

  **Status (wave 3):** partially resolved by grind 749c0dc and saga 1d965bd /
  2ee5e0a. Three of the five joins are gone: the replay sweep (RA-2), the
  saga storage adapter (RA-6) and the cancellation fan-out (RA-5). The
  `research` row stays, but it is now written in the job's own transaction
  (`grind.submit_in`, app.gleam:217-235), so `job_id` is `NOT NULL` and
  `db.set_job` is deleted. What remains is Fabric's: the `run_id` column and
  its write after the run's first commit (RA-3), the job-to-run state machine
  (`drive_agent`, `start_run`, `follow`: jobs.gleam:187-283, 97 lines, was
  81; it now also forwards the job's cancellation) and the read-only
  reconciliation (RA-4). Fabric's sweeper stays unregistered: decision 1 says
  the job drives the run, which FABRIC-R13 (wave 5) is to encode.

  **Status (round 5):** partially resolved by fabric fd60851. The `run_id`
  column, `db.set_run` and `telemetry.bind_run` are gone, because the job
  names its run (RA-3). The `research` row stays: it maps the app's research
  id to the job id Grind issues (`app.handle`) and holds the state shown to
  callers, so the "join table" shrinks (db.gleam 137 → 110 lines) rather than
  disappears. The job-to-run state machine is the same size
  (`drive_agent`, `start_run`, `follow`, `reconcile_all`: jobs.gleam
  187-318 before, 189-318 after): the "no sources, start afresh" branch and
  the 250 ms polling went, and a bounded retry of `StartUnconfirmed` and the
  `run_id` function came. FABRIC-R13 (a Grind adapter in fabric) is still
  open.

**Status (wave 5):** the job-to-run state machine shrank again and lost its
last package-specific recovery code. `reconcile_all` (the 77-line
read-only reconciliation, RA-4) is gone, `follow` no longer carries the
correlation, and the typed answer arrives as `Completed(answer)` (RA-10), so
the machine only maps ends to a `worker.Response` (jobs.gleam 318 → 290
lines). Run ids come from `run.id_from_parts` (RA-3). Fabric's sweeper stays
unregistered for the same reason as before (the job publishes); the app keeps
`store.supervised`, which still exists for that case. FABRIC-R13 is still not
a Grind adapter.

### RA-2 Grind never redelivers a job whose node died; the app authorizes each replay

- **Packages**: grind. **Kind**: composition. **Severity**: major.
- **Evidence**:
  - After `SIGKILL`, the job stays `executing` until its lease expires. A
    quarantine scan then moves it to `uncertain` (grind/README.md:215-217),
    where only an audited `resolve_uncertain(.., AuthorizeReplay)` releases it
    (grind/src/grind/postgres.gleam:777). The design specifies Lifeline, which
    rescues orphaned executing jobs (oversight/grind-design.md:327). The
    implementation has no rescue path.
  - The research job is safe to replay, because Fabric and Saga hold its
    progress. Even so, the app runs its own sweep (jobs.gleam:263-300, 38
    lines): `quarantine_expired`, then for each unfinished research row
    `bind_handle` and `state`, then `resolve_uncertain` with a made-up
    resolver and resolution id.
  - Grind has no query for uncertain jobs. Its reads all take a handle
    (postgres.gleam:1225, :1789, :1804), so the app finds candidate jobs
    through its own table (db.gleam:119-129).
  - The tests release the job 5.9 s after the kill, at a 6 s lease
    (research_agent_test.gleam:263-301).
- **Proposal** (grind): a worker-bound abandonment policy,
  `worker.with_abandonment(worker, ReplayAfterLeaseExpiry(max_replays: Int))`,
  under which quarantine returns a replay-safe job to `available` (Lifeline).
  The default stays the conservative `uncertain`. Also add
  `postgres.list(database, queue:, state:, limit:)` for operator sweeps.

  **Status (wave 3):** resolved by grind 749c0dc.
  `worker.with_abandonment(worker.ReplayAfterLeaseExpiry(max_replays: 3))`
  (jobs.gleam:107) replaces `jobs.recover_abandoned` (38 lines),
  `db.unfinished` (11), `app.recover_abandoned` (3) and the test's
  `release_abandoned` polling loop (10): 62 lines become 1. Both OTP-peer
  crash tests now kill the peer, start a node and only await the outcome;
  the claim-time quarantine scan requeues the job once its 6 s lease
  expires, and the survivor's consumer runs it. `admin.list` shows
  `replay_count: 1` and the job never in `uncertain`; no `job.resolved`
  event is emitted. Two defects in the replay path are new (RA-12).

### RA-3 `fabric.start` issues the run id, so a job cannot start a run idempotently

- **Packages**: fabric. **Kind**: composition. **Severity**: major.
- **Evidence**:
  - `start_root` mints `"run-" <> random_id()` (fabric/src/fabric.gleam:210).
    The job can record the id only after the run's first commit
    (jobs.gleam:186-203).
  - A crash between `fabric.start` and `db.set_run` leaves an orphan run. The
    replayed job then starts a second one, repeating searches and model calls
    the store already holds.
  - The graph runtime already takes a caller id
    (`graph.start(runtime, id, initial)`, fabric/src/fabric/graph.gleam:818).
    Without a caller id here, the app also needs the `run_id` column (RA-1).
- **Proposal** (fabric): `fabric.start_with_id(store, agent, context, id: RunId, prompt)`.
  For an id that is already stored, it returns
  `Error(AlreadyStarted(Run(context)))` (or opens it). A job would then use
  `run.parse_id("research-" <> research_id)` and need no join column.

  **Status (wave 3):** unchanged; fabric-owned (FABRIC-R2, wave 5). The
  `run_id` column, `db.set_run` and `telemetry.bind_run` stay.

  **Status (round 5):** resolved by fabric fd60851 (`fabric.start(.., id:,
..)`, `AlreadyStarted`). The job starts its run as
  `research-<job id>-<attempt>` (`jobs.run_id`), where `attempt` is Grind's
  business attempt. A replay keeps both numbers (the crash tests assert
  `attempt == 1` after a replay), so `start` answers `AlreadyStarted` and the
  job `recover`s the run; a `NoSources` retry has attempt 2 and so a fresh
  run, which replaced the `await(handle, 0)` probe that looked for a finished
  "no sources" run. No orphan run is possible between `start` and a row
  write, because there is no row write. The id could not be the research id
  alone, since a retried job must not reopen the finished run. Cost: code
  outside the handler cannot know the attempt. `app.snapshot` reads it with
  `admin.list(.. |> admin.after(job_id - 1))` and checks the returned id
  (10 lines); a `grind.attempt(handle)` read would remove that. In-flight
  jobs of the previous version have a `run_id` column no code reads and would
  start a second run on replay; the app has no deployed data, so no migration
  is written.

**Status (wave 5):** resolved by fabric `run.id_from_parts`. `jobs.run_id`
is one line, `run.id_from_parts("research", [job_id, attempt])`; the
`let assert Ok(..) as "digits and dashes are a valid run id"` is gone, and
`AlreadyStarted(_)` is `AlreadyStarted(_, same_input: True)`. A replay sends
the same agent, prompt and correlation, so it is `True` and the job
`recover`s; `same_input: False` (another start reused the id) now stops the
job with the error text instead of recovering someone else's run. The attempt
lookup in `app.snapshot` (see the round 5 friction) is unchanged.

### RA-4 After a crash, even a read-only tool suspends the run until the app reconciles it

- **Packages**: fabric. **Kind**: extensibility. **Severity**: major.
- **Evidence**:
  - Recovery turns every started tool into an uncertain effect "never retried"
    (fabric/src/fabric.gleam:52-55). `tool.bind`/`bind_settling` cannot
    declare a tool safe to run again (fabric/src/fabric/tool.gleam:146-206).
    Graph operations can, with `operation.with_replay`
    (fabric/src/fabric/graph/operation.gleam:213).
  - Test `a_tool_interrupted_by_a_crash_is_reconciled_by_the_app_test`
    (research_agent_test.gleam:341) kills the VM while `read` waits for a
    page. The recovered run is `Suspended([], [UncertainAction(.., "read", ..)])`.
  - The app finds the action's arguments in the snapshot, decodes them with
    the tool's codec, runs the read again, encodes the output and calls
    `fabric.reconcile` (researcher.gleam:142-197, jobs.gleam:234-254; 77
    lines). It needs a `case` on tool names, because `UncertainAction` holds
    the tool name but not the bound tool.
- **Proposal** (fabric): `tool.with_replay(tool, max_attempts: Int)`,
  mirroring `operation.with_replay`. Recovery dispatches a started invocation
  of such a tool again instead of making it uncertain.

  **Status (wave 3):** unchanged; fabric-owned (FABRIC-R9, wave 5).
  `researcher.replay_read_only` and `jobs.reconcile_all` (77 lines) stay, and
  `a_tool_interrupted_by_a_crash_is_reconciled_by_the_app_test` still
  passes through them.

**Status (wave 5):** resolved by fabric `tool.with_replay`.
`researcher.replay_read_only`, `find_action`, `decode`, `encode` and
`jobs.reconcile_all` (77 lines in round 5) are deleted; the tools list
ends in `|> list.map(tool.with_replay(_, 3))` (3 lines with its comment). The
crash test `a_tool_interrupted_by_a_crash_is_reconciled_by_the_app_test` became
`a_read_interrupted_by_a_crash_is_replayed_by_fabric_test` and now asserts
the stronger fact: the recovered run's `read` action is `Succeeded`, with
`replays: 1` and `page_calls: 2`, instead of `Reconciled`. The job's
`Suspended([], uncertain)` arm is one `Stopped` line: with `Explain`-only
handlers an uncertain effect now means a read that exhausted its three starts.

### RA-5 Cancelling the job does not reach the agent; the app fans the cancellation out

- **Packages**: grind, fabric. **Kind**: composition. **Severity**: major
  (adds evidence to the grind card's "no cancellation signal" seam).
- **Evidence**:
  - In test `cancellation_reaches_the_run_and_closes_the_llm_stream_test`
    (research_agent_test.gleam:205-257), `postgres.cancel` returns
    `CancellationRequested`. The LLM stream then stays open for the 500 ms the
    test waits (line 227). The handler cannot learn of the request
    (grind/src/grind/worker.gleam:147-158), and `state` still reads
    `Executing`.
  - `app.cancel_research` (app.gleam:250-265) also looks up the run id in the
    app table and calls `fabric.cancel_stored`. That kills the model task, and
    the provider sees the stream close within one 50 ms keep-alive.
  - A cancellation that arrives between `fabric.start` and `db.set_run`
    reaches only Grind (RA-3).
  - Grind records `CancelledWithReason("cancelled by caller")`, not the
    handler's `WorkerCancelled` reason.
- **Proposal** (grind): `worker.with_queue_handler_context(fn(JobContext, input) -> WorkerResponse)`.
  `JobContext` exposes `job_id`, `attempt` and `cancellation: process.Selector(Nil)`,
  fired when `cancel` commits for a running job. The handler can select on it
  while it awaits the Fabric run, so the API calls only `postgres.cancel`.

  **Status (wave 3):** resolved by grind 749c0dc. The handler is
  `worker.responding` and reads `worker.cancellation(job)`; `follow` checks
  it between 250 ms waits and calls `fabric.cancel(handle)`
  (jobs.gleam:243-262). `app.cancel_research` is `grind.cancel` alone (37
  lines of fan-out → 8): no run-id lookup, no `fabric.cancel_stored`, no
  `Cancellation` record. The test now proves the correct behavior: after
  `grind.cancel` alone the provider sees the stream close (within the
  lease / 3 renewal), the job ends `Cancelled`, the run `Finished(Cancelled)`
  and the row `cancelled`. The window between `fabric.start` and
  `db.set_run` no longer loses a cancellation, because the handler, not the
  API, cancels the run it holds. Two points remain: Grind still records the
  caller's reason (`Cancelled("cancelled by caller")`), not the handler's
  `Cancelled("research cancelled")` (the test pins it), and `fabric.await`
  takes no selector, so the handler polls (see the re-run below).

### RA-6 Durable saga on PostgreSQL needs a 262-line adapter that must track processes

- **Packages**: saga. **Kind**: composition. **Severity**: major (the saga card
  lists the adapter as deferred; this adds what its contract costs).
- **Evidence**:
  - `apps/research_agent/src/research_agent/saga_store.gleam` (262 lines)
    passes `saga/storage/conformance` (test at research_agent_test.gleam:368).
  - The suite rejected the first lease-only version twice. "same owner cannot
    claim twice" and "token alone grants no ownership"
    (saga/src/saga/storage/conformance.gleam:126-139) require ownership by
    process, not by the stored generation. "reclaim after owner death"
    (:318) requires noticing a dead claimer before the lease expires.
  - SQL cannot express either rule. The adapter stores the claimer's pid in the
    owner column and checks `process.is_alive` on a competing claim
    (saga_store.gleam:107-175, plus `pid_to_string`/`string_to_pid` FFI). The
    checkout app solved the same problem with a 360-line owner-registry actor
    (apps/checkout/src/checkout/saga_store.gleam).
  - `durable.start_or_reconnect(storage, id, ..)` takes the id that the
    storage already addresses (saga/src/saga/durable.gleam:101; saga card
    concern 4).
- **Proposal** (saga): ship a `saga_postgres` package next to the memory and
  file adapters, as Fabric ships `fabric_postgres`: `settings(pog.Connection)`,
  `migrate`, `storage(settings, id)`, checked by `conformance.run`. Failing
  that, document in `saga/storage` that ownership is per process and that
  adapters must detect a dead claimer.

  **Status (wave 3):** resolved by saga 1d965bd and 2ee5e0a.
  `saga_store.gleam` (262 lines), the `pid_to_string`/`string_to_pid` FFI (6)
  and the `saga_executions` DDL in `db.migrate` (8) are deleted. The storage
  is `saga_postgres.config(database) |> with_lease(10_000) |> with_schema(..)`,
  `migrate` and `storage` (app.gleam, 10 lines), built once for every
  execution. `publish.run` uses `durable.new`, one `Run`,
  `durable.with_correlation` and `drive(run, timeout: 60_000)`. The
  conformance test now runs saga's suite against `saga_postgres` on the pool
  Grind built (Grind's `search_path`, `READ COMMITTED` and
  idle-in-transaction timeout), with a 1 s lease.

### RA-7 One request cannot be followed through the model call or the saga

- **Packages**: fabric, llm_wire, saga, http_gun. **Kind**: composition.
  **Severity**: major (new evidence for fabric and durable saga; EXT-4 and
  WHK-5 cover llm_wire and http_gun).
- **Evidence** (`common_path_publishes_and_checkpoints_the_conversation_test`,
  research_agent_test.gleam:88-134; `gleam run` step 1):
  - 22 events join the request, keyed by Grind `job_id` (bound at
    submission), Fabric `run` (bound at run start) and http_gun correlation.
    The correlation is minted per research and carried on the context's
    client (researcher.gleam:32-41).
  - The request leaves 15 llm_wire, 5 saga and 6 http_gun events
    unattributed.
  - The model's HTTP calls go through the client fixed at `llm.model(client, ..)`
    (fabric/src/fabric/llm.gleam:39-50), and `model.Request` carries no run id
    or turn (fabric/src/fabric/model.gleam:52-58). Neither the app nor the
    adapter can tag a turn's request.
  - Saga's durable runs emit `RunMetadata(workflow, run: Int)`
    (saga/src/saga/observation.gleam:23-25). That run id is per VM and never
    returned by `durable.drive`.
  - Fabric's `model.stop` carries `run` and `turn`, so the turn itself is
    attributable, but not its HTTP or llm_wire lifecycle.
- **Proposal**: fabric adds `run: RunId` and `turn: Int` to `model.Request`,
  and `fabric/llm` tags each turn with `http_gun.with_correlation`. saga adds
  the durable `reference_id` to its run and step metadata. The http_gun half
  (`telemetry.id_from_string`) is EXT-4's.

  **Status (wave 2):** partially resolved by sinal 5aef827
  (`sinal/correlation`); no package carries `Correlation` yet, so the
  package-side proposal stands. The app's own events now do: the new
  `research_agent.research.state` event (events.gleam, 72 lines) carries the
  research id as `Correlation` through the record builder, and the collector
  joins it with no binding (telemetry.gleam, 12 lines; the research id is now
  `correlation.unique()`). The common-path test asserts the four states
  arrive in order. The 22 package events still join through `bind_job`,
  `bind_run` and `bind_http`, and the 26 unattributed llm_wire, saga and
  http_gun events are unchanged. This adds a fourth source to the trace
  (26 joined events, was 22) and removes nothing: the registry
  (~110 lines) goes only when http_gun (wave 3) and the other packages accept
  the app's `Correlation`.

  **Status (follow-up):** partially resolved by http_gun c45adfe and
  sinal f9cca37 / 5e8bee3. `http_gun.with_correlation` takes the research's
  `Correlation` (remote.gleam), and `metadata.correlation` carries it, so
  http_gun events join like the app's own events. The `http_events.new_id`
  mint, the `bind_http` message, the id-to-research table, the `Http` key and
  its `Snapshot` slot are gone (telemetry.gleam 433 → 400 lines;
  `researcher.context` lost its telemetry argument). The package-side
  proposal stands for the rest: the model's HTTP calls run on the client fixed
  at `llm.model(client, ..)`, so the 6 http_gun, 15 llm_wire and 5 saga events
  per request stay unattributed, and the Grind and Fabric joins
  (`bind_job`, `bind_run`) are unchanged. The app's own event now holds the
  `Correlation` itself through `required_field()` (events.gleam 72 → 64
  lines; no `Some(..)`, no `None` arm in the collector).

  **Status (wave 3):** partially resolved by grind 749c0dc and saga
  89c1aec. Grind events carry the job's correlation, which the app sets to
  the research id (`job.with_correlation`), and saga events carry the one
  the handler passes to the durable run (`durable.with_correlation` with
  `worker.correlation(job)`). The `Job` key, the `BindJob` message, the
  job-id table and `telemetry.bind_job` are gone (telemetry.gleam 400 → 391,
  despite a new `http_prefix` route and two key helpers). `gleam run` now
  joins 30 events from research_agent, grind, fabric, http_gun and saga
  (was 26 without saga); the 5 saga events per request are attributed and
  the test asserts that none is left over. `correlation.from_key` (sinal
  c6e2d36) replaces `from_string` in `events.announce` and
  `remote.correlated`, so neither swallows an error any more. Still open,
  fabric-owned (FABRIC-R8, FABRIC-R15, wave 5): the model's 6 http_gun and
  15 llm_wire events per request stay unattributed, and Fabric events still
  join through `bind_run`.

  **Status (wave 4):** resolved for llm_wire and http_gun by llm_wire
  177ad50 / 9f35183 (the call reads `http_gun.correlation` from its view and
  puts it in `telemetry.Metadata.correlation`) and the app, not by fabric.
  Fabric's `model.Request` still carries no run or context, and the model is
  built over one client (`llm.model(client, ..)`), so the app builds the agent
  per research over that research's correlated client
  (`researcher.agent_for`, 12 lines; `Deps.agent` is now a function of the
  `Context`). `gleam run` joins 51 events (was 30) and prints
  `events no request id could claim: []`; the test asserts that no llm_wire,
  saga or http_gun event is left over (it was 15 llm_wire and 6 http_gun).
  Fabric events still join through `bind_run` (FABRIC-R8, wave 5).

  **Status (round 5):** resolved by fabric fd60851 / 409f1a7. The job passes
  `Some(worker.correlation(job))` to `fabric.start`; `model.Request` carries
  it and `fabric/llm` tags each turn, so `researcher.agent_for` and its
  `let assert` are gone and `Deps` holds one `Agent` and one `Context` built
  when the node starts. The tools read `call.correlation`
  (`http_gun.with_correlation(context.http, call.correlation)`), so
  `Context` lost its `research` field and `remote.correlated` was deleted.
  Run events carry `correlation`, so the `Run` key, the `BindRun` message,
  the run-to-research table and `telemetry.bind_run` are gone and the
  collector's snapshot returns a plain list. `gleam run` joins 51 events and
  prints `events no request id could claim: []`; the test now also asserts no
  fabric event is left over. Two joins remain by hand, both on the app's side
  of a package border: the saga's HTTP client is correlated in the job
  (`jobs.handle`, one line) because a saga step receives no `tool.Call`, and
  `replay_read_only` takes the correlation as a parameter because it runs
  outside a tool call. `fabric/observation.LeaseLost` still has no
  `correlation`, so a lease loss would be unattributed (the app keys it
  `Unkeyed`; no test triggers it).

**Status (wave 5):** resolved for the fabric and saga seams. `fabric/telemetry`
`LeaseLost` carries `correlation`, so `lease.lose` is keyed by the research
(telemetry.gleam; `Unkeyed` remains only for Sinal's `forwarder.dropped`).
Saga's `RunMetadata` and the other three observers' `correlation` is a
`Correlation`, so the saga observers use `research(..)` and not `keyed(..)`
(no `None` arm). The saga steps read the correlation from the key:
`upload_body` and `publish` became `saga.effect`, `create_draft`'s resolver and
undos call `via(key)` (`http_gun.with_correlation(client, saga.correlation_of(key))`),
so the job no longer correlates the HTTP client (`jobs.handle` lost the
`http_gun.with_correlation(..)` argument; `publish.run` keeps only
`durable.with_correlation`). Nothing is left to join by hand in the job.

### RA-8 Three codec systems for one request; 96 lines of bridges for five types

- **Packages**: grind, saga, json_blueprint. **Kind**: ergonomics.
  **Severity**: minor (SMCP-8 and EXT-5 already cover this).
- **Evidence**: `Published` and `Article` each need gleam_json functions for
  Grind (domain.gleam:92-133) and a Saga `String` codec built from those
  functions (publish.gleam:163-216, including a `json_codec` helper). Tool
  payloads use Blueprint codecs (domain.gleam:33-90). One value type therefore
  has up to three wire definitions.
- **Proposal** (saga): `codec.json(version, to_json, decoder)`, a constructor
  over gleam_json and `decode`, which would remove the helper and match
  Grind's `worker.codec` shape.

  **Status (wave 2):** partially resolved by json_blueprint f55ec09
  (`codec.to_json`, `codec.decoder`, the `use` record builder and the union
  builder). Six values (`Research`, `Published`, `Article`, the draft pair,
  `PublishError`, `ResearchError`) now have one Blueprint codec each, and no
  gleam_json encoder or decoder remains in the app. Two adapters
  (wire.gleam, 38 lines) turn a codec into Grind's `worker.codec` and into
  Saga's `codec.new`. The three tool-side codecs use the record builder.
  Bridges: 122 lines of twin encoders and decoders over three systems → 85
  lines of codecs (domain.gleam 28, publish.gleam 38, jobs.gleam 19) plus
  the 38-line adapter module, so about the same count with half the
  definitions (12 gleam_json functions and the `json_codec` helper → 6 codecs
  and 2 adapters), and the three `let assert Ok(worker.codec(..))` blocks in
  `jobs.worker` became one line each. Saga needs the adapter because
  `saga/codec` is a `String` codec and has no Blueprint bridge. The proposal
  to grind and saga stands: `worker.codec` and `saga/codec.new` could each
  accept a Blueprint codec directly, which would remove wire.gleam.

  **Status (follow-up):** partially resolved by grind c44e4be and
  json_blueprint bb4da39. `worker.codec` takes a fallible encoder, so the
  Blueprint bridge returns `codec.to_json(c, v) |> result.map_error(..)`
  instead of a four-line `case` with `panic` (wire.gleam 41 → 38 lines); a
  rejected value is now `submission.InvalidInput` at submit. The bridge itself
  stays: Grind still has no Blueprint-aware constructor, and `worker.codec`
  still returns a `Result` for an empty version, so `let assert Ok` remains.

  **Status (wave 3):** partially resolved by grind 749c0dc and saga
  1d965bd. `worker.codec` is total, so the `let assert Ok(worker.codec(..))`
  is gone, and Saga's bridge is `saga_codec.json(version, encoder,
codec.decoder(c))` instead of a `String` round trip. wire.gleam 38 → 27
  lines, with one shared encoder. The bridge itself stays: neither Grind nor
  Saga takes a Blueprint codec, so each value still needs a `wire.grind` or
  `wire.saga` call with its version.

### RA-9 The worker drops its error codec to avoid the known snooze/bind defect

- **Packages**: grind. **Kind**: defect. **Severity**: minor here (EXT-1,
  WHK-1, WHK-2 and SMCP-7 own the finding).
- **Evidence**: the app needs `bind_handle` on finished jobs (`await_outcome`,
  `cancel_job`; app.gleam:276-307), so it defines the worker without an error
  codec (jobs.gleam:62-95). A run that keeps finding no sources then reads back
  as
  `FailedOperationallyWithCause("worker returned an application error", BudgetExhausted)`.
  The typed `NoSources(reason)` is lost (research_agent_test.gleam:164-180).
  The retry policy still sees the typed error before erasure, and that part
  works well.
- **Proposal**: as EXT-1.

**Status (2 Oct 2026):** resolved by grind 7a04831. The worker is defined
with `worker.define_with_error_codec` again, with a `research-error-1` codec
for `ResearchError` (jobs.gleam:64-82, 93-114); the "erased on persistence"
caveat is gone. `bind_handle` works on the finished, cancelled and replayed
jobs of this worker, and the crash tests (replay after `SIGKILL` on an OTP
peer) pass with it. The test now asserts
`BusinessFailedWithCause(NoSources("the search service is unavailable"), BudgetExhausted)`
(research_agent_test.gleam:173-179). No lines were removed: restoring the
codec adds 26 lines of gleam_json glue (see RA-8).

### RA-10 A typed agent ends with a string; the article shape is a prompt convention

- **Packages**: fabric. **Kind**: ergonomics. **Severity**: minor (fabric card
  concern 5).
- **Evidence**: `run.Completed(text: String)` (fabric/src/fabric/run.gleam:143).
  The app asks for `TITLE: ...` or `NO SOURCES ...` in the system prompt and
  parses it back (domain.gleam:135-180, 46 lines). A business outcome ("no
  sources") travels as text inside a `Completed`.
- **Proposal** (fabric): `agent.with_output(spec, codec)` → `Completed(value)`
  validated against the codec's schema, as llm_wire's structured output does.

**Status (wave 5):** resolved by fabric `agent.with_answer` (F3).
`domain.parse_answer` (the 46-line `TITLE:` / `NO SOURCES` parser) is deleted,
and the system prompt no longer teaches a format. `domain.answer_codec` is a
union codec (about 30 lines) instead, so the domain gains 11 lines
(domain.gleam 161 → 172); the
agent is `Agent(Context, Answer)`, the job matches `Completed(answer)`, and
the test asserts `Completed(domain.Written(..))`. The business outcome "no
sources" is now a variant the model picks, not a prefix a parser guesses. A
refused answer gets a corrective turn: the new test
`a_refused_answer_gets_a_corrective_turn_and_then_publishes_test` has the
scripted provider return unparseable text once and sees the run finish with
three model calls and a published article.

### RA-11 Small frictions

- **Two pools on one database** (grind, minor; grind card): Grind opens its own
  pool from a URL (app.gleam:149-164). The app opens a second one for
  `fabric_postgres`, the saga checkpoints and the research index
  (app.gleam:92-105). The research row's state is written outside Grind's
  acknowledgement, so it can say `published` while the job is still
  `executing` after a crash. Replay is idempotent here because Saga
  reconnects to its finished outcome.

  **Status (wave 3):** resolved by grind 749c0dc. One pool:
  `grind.new(pog.pool_size(pool, 10))` builds it from the app's
  `pog.Config`, and Fabric's store, the saga storage and the `research`
  table use it (`fabric_postgres.settings` takes `grind.connection`'s
  `pog.Connection` unchanged). The Grind settings, registry, policy and
  consumer start (about 30 lines) become one `grind.new` pipeline (16 lines) and
  one supervised child. The row and the job now commit together
  (`submit_in`). The row's later states are still written outside Grind's
  acknowledgement.

- **Lifecycle** (grind, gleam_otp, nit): `queue.start` links to its caller and
  only that process may stop it. The crash test's peer node therefore needs a
  long-lived owner process (node.gleam:46-58). `static_supervisor` has no
  stop, so `app.stop` calls `exit(Pid, shutdown)` from FFI
  (app.gleam:217-228).

  **Status (wave 3):** partially resolved by grind 749c0dc. Grind runs as
  `grind.supervised(config, name)` and stops from any process, so the
  consumer no longer pins the owner. The peer still needs its long-lived
  owner and `app.stop` still calls the FFI `shutdown`, because
  `static_supervisor.start` links to its caller and has no stop (gleam_otp).

- **Model failures are strings** (fabric, minor; fabric card concern 3): a
  scripted 404 reached the job as
  `ModelFailed(ModelError("HTTP status 404 (RequestMayHaveReachedProvider)", False))`.
- **Loopback** (http_gun, nit): both clients need the same 16-line policy
  (app.gleam:71-86). The provider client needs a 120 s ceiling and the tool
  client 5 s, as in EXT-7.

  **Status (2 Oct 2026):** partially resolved by http_gun a2869b7. `loopback`
  now starts from `config.default() |> config.allow_loopback`
  (app.gleam:73-87), which removes the `allow_loopback: True` field. The
  nested `destination.Policy(..)` update stays, because the app also confines
  both clients to `allowed_hosts: Some(["127.0.0.1"])` and the helper does
  not set an allowlist; using the helper alone would admit every public
  host. One line removed.

  **Status (wave 3):** resolved by http_gun 14eacc6 and llm_wire 576482e.
  `config.with_destination(destination.loopback_only() |>
destination.only_hosts([authority]))` replaces the nested update, and it
  pins the port too. The second client is gone: llm_wire sends each model
  call through a view with its own budget, so one client with a 5 s request
  timeout serves the tools, the publisher and the 120 s provider stream.
  The `observations` argument is gone: http_gun emits through `sinal.emit`,
  and the app routes `["http_gun"]` to its forwarder. Lines: 16 + 2 starts →
  18, of which 9 parse the services URL into `host:port` for `only_hosts`.

- **Dependency resolution**: no friction. pog resolved to 4.1.0, since grind
  and fabric_postgres both pin `>= 4.1.0 < 4.2.0` (the pins must widen
  together); mist 6.0.2, gleam_stdlib 0.71.0. Depending on both `fabric` and
  `fabric/integrations/fabric_postgres` (which itself names `fabric = ../..`)
  resolved to one package.

  **Status (2 Oct 2026):** after `gleam update` on fabric db81b79, grind
  b2545a9, saga, llm_wire and http_gun a2869b7, gleam_stdlib resolves to
  1.0.5 (was 0.71.0). pog stays at 4.1.0 (fabric_postgres and grind still
  share `< 4.2.0`); mist moved to 6.0.3, gleam_crypto to 1.6.0. No app code
  changed for the new stdlib, and the app builds with `--warnings-as-errors`.

  **Status (wave 3):** no friction. `saga_postgres` pins the same
  `pog >= 4.1.0 and < 4.2.0` and `pgo` ranges as grind and fabric_postgres,
  so the shared pool resolves to pog 4.1.0; the app's own `pog` range is
  narrowed to match. `gleam_time` became a direct dependency, because
  every Grind and queue duration is a `gleam/time/duration.Duration`.

**Status (wave 5):** the "model failures are strings" item is resolved by
fabric `model.error` kinds, but this app builds no `model.ModelError` and reads
none; the job reports a failed run through `run.describe_outcome` and
`fabric.describe_error` instead of `string.inspect`.

### RA-12 A replayed abandoned attempt emits no event and uses a business attempt

- **Packages**: grind. **Kind**: defect. **Severity**: minor (the replay
  itself works; operators lose its trace and a retry).
- **Evidence**:
  - The quarantine `UPDATE` clears `attempt_id` for a replayed row and then
    returns `job.attempt_id` (grind/src/grind/internal/lease.gleam:61-70);
    `emit_quarantined` skips a row without an attempt id (:218-220). A
    replay therefore never emits `[grind, job, quarantined]` with
    `replayed: True`, the field added for it. Both crash tests pin the
    absence (research_agent_test.gleam, `crash_and_recover`); only
    `job.claimed attempt 2` shows the replay.
  - `worker.with_max_attempts` says a replayed lease does not use an attempt
    (grind/src/grind/worker.gleam:251). The claim increments
    `attempt_count` (grind/src/grind/internal/attempt.gleam:589) and the
    replay does not give it back (lease.gleam:56-70). After one replay the
    research job reads `attempt: 2, max_attempts: 2` in `admin.list`, so a
    replayed run that then finds no sources is not retried. The tests pin
    `attempt: 2`.
- **Proposal** (grind): return the expired attempt's id from the scan (a
  CTE that reads it before the update, or `RETURNING` the old value), and
  decrement `attempt_count` on replay as the release path does
  (grind/src/grind/internal/sql.gleam:496). grind's own replay test
  (test/grind/facade/behavior_test.gleam:118) checks neither.

## Glue measure

| Seam                                               | Lines       | Where                                                            |
| -------------------------------------------------- | ----------- | ---------------------------------------------------------------- |
| grind job drives fabric run                        | 81          | jobs.gleam:152-232                                               |
| join index (job id, run id, state)                 | ~115        | db.gleam (the `research` table and queries)                      |
| crash: replay abandoned jobs                       | 38          | jobs.gleam:263-300                                               |
| crash: reconcile interrupted read-only tools       | 77          | researcher.gleam:142-197, jobs.gleam:234-254                     |
| cancellation fan-out (grind + fabric)              | 37          | app.gleam:248-284                                                |
| saga ↔ PostgreSQL storage                          | 262         | saga_store.gleam (+ 6 lines FFI)                                 |
| codec bridges (grind gleam_json, saga String)      | 96          | domain.gleam:92-133, publish.gleam:163-216                       |
| fabric answer → typed article                      | 46          | domain.gleam:135-180                                             |
| http_gun loopback policy                           | 16          | app.gleam:71-86                                                  |
| telemetry: attachments / per-request join registry | ~295 / ~110 | telemetry.gleam:78-372 / 374-487, remote.gleam:33-41             |
| lifecycle (supervisor stop, peer owner process)    | ~30         | app.gleam:217-228, research_agent_ffi.erl:5-16, node.gleam:46-58 |
| llm_wire conversation persistence                  | 0           | Fabric's private envelope covers it                              |

## What worked well

- **Fabric's PostgreSQL store is a drop-in checkpoint.** About 15 lines put
  the run store on the app's pog pool (app.gleam:110-129). Every turn and tool
  result is committed before the next step. After a `SIGKILL` in the middle of
  a model call, `fabric.recover` on another node continued with exactly one
  repeated model call and no repeated search (`llm_calls: 4, search_calls: 1`,
  research_agent_test.gleam:303-339).
- **Cancellation inside Fabric is real.** `fabric.cancel_stored` kills the
  model task. llm_wire's owner closes the http_gun stream, and the scripted
  provider sees the disconnect on its next write.
- **The llm_wire adapter takes the caller's http_gun client** (fabric
  8648f6f). The loopback policy is one record update, and the model sits
  behind Fabric's model port without app code.
- **Tool failures reach the model as data.** A 503 from the search API becomes
  `tool.Explain`, and the model searches again. No app retry logic was needed
  (research_agent_test.gleam:137-162).
- **One Blueprint codec serves two roles.** `search_results_codec` both
  decodes the search API's HTTP body and declares the tool output the model
  sees (researcher.gleam:63-77).
- **The policy gate is typed.** `tool.input(read_definition(), action)` gives
  the policy the decoded URL (researcher.gleam:98-111).
- **Saga's durable compensation composes with HTTP.** The `effect` key is the
  publisher's idempotency key, and the same key lets the `recoverable`
  resolver ask whether an interrupted create happened (publish.gleam:46-79). A
  failed publish deletes the draft (research_agent_test.gleam:184-201).
- **Saga's conformance suite** caught both ownership mistakes in the app's
  adapter before any workflow ran on it.
- **Grind's retry policy sees the typed error.** "No
  sources" is retried with a fresh run, and other failures are not
  (jobs.gleam:118-129).
- **One Sinal forwarder** carries http_gun's observations and Fabric's routed
  events, so Fabric's handlers stay out of its runners (app.gleam:92-105).

## Re-run after fixes (2 Oct 2026)

Package heads: fabric db81b79, grind b2545a9 (includes 7a04831), http_gun
a2869b7, plus saga, llm_wire, json_blueprint and sinal at master. gleam_stdlib
resolved to 1.0.5.

- **Tests**: 8 passed, no failures (`../scripts/with-postgres.sh gleam test`),
  including both OTP-peer crash-recovery tests. `gleam run` prints the
  four-scenario narrative unchanged.
- **Glue measure, before → after**:

  | Seam                             | Before | After | Change                                                                 |
  | -------------------------------- | ------ | ----- | ---------------------------------------------------------------------- |
  | grind error contract (RA-9)      | 0      | 26    | codec restored; the typed error now survives (jobs.gleam:64-82, 93-99) |
  | codec bridges (RA-8)             | 96     | 122   | the error codec is one more gleam_json pair                            |
  | http_gun loopback policy (RA-11) | 16     | 15    | `config.allow_loopback`; the allowlist update remains                  |
  | telemetry: fabric model turn     | 11     | 11    | no change (the handler never read usage)                               |

  RA-9 trades a lost type for 26 lines. That is the design the brief asked
  for, but it shows RA-8 again: a third hand-written gleam_json codec for one
  job.

- **New friction**: none that needed code. Fabric's `model_turn()` is now
  `Event(Option(Usage), ModelTurn)` and `RunTotals` gained
  `unreported_replies`. The app's handlers ignore the measurements of
  `model_turn` and `run_finished` (telemetry.gleam:211-222, 253-260), so the
  breaking change compiled unchanged. The http_gun allowlist still has no
  helper to match `config.allow_loopback` (RA-11), so the loopback helper
  removes only one field from the nested update.

## Re-run after wave 2

Package heads: sinal 5aef827, json_blueprint f55ec09, fabric 7844fa7,
grind c1920e6, saga 43ae141, llm_wire bc5d626, http_gun 1dc20a1.

- **Tests**: 9 passed, no failures (`../scripts/with-postgres.sh gleam test`),
  including both OTP-peer crash-recovery tests. One test is new: every
  research state reaches an observer with its correlation (see below).
  `gleam run` prints the four-scenario narrative; the trace line now reads
  "26 events from research_agent, grind, fabric, http_gun". The build passes
  `--warnings-as-errors` and `gleam format --check`.
- **Glue measure, before → after**:

  | Seam                                     | Before         | After                           | Change                                                                                                                         |
  | ---------------------------------------- | -------------- | ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
  | codec bridges (RA-8)                     | 122, 3 systems | 85 + 38 adapters, 1 system      | one Blueprint codec per value; line count flat, 12 gleam_json functions → 6 codecs + 2 adapters                                |
  | tool codecs (domain.gleam)               | 36             | 36                              | `use` builder replaces `record2`, `required`, `imap` and two `let assert Ok`; two-field records shrank, one-field records grew |
  | telemetry: handler ids                   | 59             | 0                               | `attach` helper, id suffix and two arguments for each of 23 observers deleted; `sinal.observe(event, run)`                     |
  | `forwarder.new` and fabric prefix        | 3 + 2 atoms    | 3                               | `forwarder.new(name) \|> with_capacity(4096)`; `["fabric"]`; no `let assert`, no `atom.create`                                 |
  | app's own events and correlation (RA-7)  | 0              | +72 events.gleam, +12 collector | new; the research id is a `Correlation`; the `db` writers announce each state                                                  |
  | package events joined per request (RA-7) | ~110 registry  | ~110 registry                   | unchanged: packages do not carry `Correlation` yet                                                                             |

  Source totals: telemetry.gleam 487 → 433, domain.gleam 180 → 163,
  publish.gleam 228 → 214, jobs.gleam 335 → 325, plus wire.gleam (41) and
  events.gleam (72). `json_blueprint` and `sinal` did not change any other
  seam of this app.

- **New friction**:
  - **One-field records got longer.** The old single-property `codec.field`
    plus `imap` was two lines; the builder needs the record type annotated
    on the getter and a `success`, which `gleam format` spreads over seven:

    ```gleam
    // before
    codec.field("query", codec.string() |> codec.describe("Search terms"))
    |> codec.imap(SearchQuery, fn(q) { q.query })

    // after
    use query <- codec.field(
      "query",
      codec.string() |> codec.describe("Search terms"),
      fn(q: SearchQuery) { q.query },
    )
    codec.success(SearchQuery(query:))
    ```

    For records of two or more fields the builder reads better than
    `record2` with positional constructors (`hit_codec` is 5 lines, was 9).
    Three of the app's tool payloads are single-field wrappers, and a
    `codec.wrap(codec, Constructor, getter)` shortcut would serve them.

    **Status (follow-up):** partially resolved by json_blueprint bb4da39. The
    getter needs no annotation (`get: fn(q) { q.query }`), and 12 getter
    annotations are gone across domain.gleam and publish.gleam. The one-field
    records did not get shorter: `search_query_codec` and
    `page_request_codec` are still 7 lines, because the `describe` call
    forces `gleam format` to break the argument list. The wrapper
    shortcut remains a gap.

  - **Grind's encoder has no failure channel.** The guide's bridge,
    `codec.to_json(c, x) |> result.unwrap(json.null())`, stores `null` when a
    value cannot be encoded, and the decoder then rejects it at read time.
    wire.gleam panics with `describe_encode_error` instead. `worker.codec`
    still returns a `Result` (empty version only), so the adapter needs a
    `let assert Ok` as well. A bridge in grind that takes a Blueprint codec
    would own both decisions once.

    **Status (follow-up):** partially resolved by grind c44e4be. The panic is
    gone and a failed encode is a typed `InvalidInput` at submit or an
    operational job failure; the `let assert Ok` around `worker.codec` and the
    Blueprint-to-Grind adapter remain.

  - **`fields.enum` repeats the type.** `[Queued, Researching, ..]` and
    `state_name` list the constructors twice and the compiler checks only
    `state_name`. The guide says to test each constructor; the new test does
    (one `observe`, six emissions), 30 lines for a property the type could
    give. A missing constructor is now a logged skip and a
    `MalformedMetadata` for each handler, not a detach, so the failure is
    visible.
  - **`Correlation` re-validates at each emission.** `Research.id` is a
    `String`, so `events.announce` calls `correlation.from_string` and keeps
    `None` on an error that cannot happen for app-generated ids
    (`option.from_result`). Making `domain.Research.id` a `Correlation` would
    remove that, but it also changes the table, the saga execution id and the
    job input, which is a larger change than this wave covered.

    **Status (follow-up):** partially resolved by sinal f9cca37. The event
    holds a `Correlation` through `required_field()` and the collector has no
    `None` arm. The `String` to `Correlation` parse moved rather than
    vanished: `events.announce` and `remote.correlated` each call
    `correlation.from_string` and drop the impossible `Error` silently. See
    the re-run below.

  - **Constructor names clash.** `events.State` needs a `Published`
    constructor, which collides with `domain.Published`; the module is
    imported qualified and its doc says so.
- **Migration guides**: sufficient for the sinal side (every edit was in the
  table: no `atom.create`, no handler id, no `let assert` around definitions,
  `forwarder.new` plus `with_capacity`, `["fabric"]` prefix) and for the
  record and union builders. Gaps, all in the json_blueprint guide: (1) the
  `to_json` bridge example is for Grind's JSON encoder only and shows
  `unwrap(json.null())` without saying what a failed encode then stores;
  (2) nothing says how to bridge to a `String` codec such as Saga's
  (`encode_json`, `decode_json` and the two `describe_*` functions do it);
  (3) a union of `String`-payload variants changes the wire from
  `{"kind", "reason"}` to `{"tag", "value"}`, so a stored value needs a new
  codec version (`research-error-2` here); the union section mentions the
  wire only for unit variants. Nothing in the fabric, grind or saga changelogs
  needed an app change: the fabric v2 receipt is internal to graph runs, which
  this app does not use, and `model_turn()` handlers still ignore usage.

## Re-run after the follow-up fixes

Package heads: json_blueprint bb4da39, sinal 5e8bee3 (with f9cca37), grind
c44e4be, http_gun c45adfe.

- **Tests**: 9 passed, no failures (`../scripts/with-postgres.sh gleam test`),
  including both OTP-peer crash-recovery tests. The build passes
  `--warnings-as-errors` and `gleam format --check`. `gleam run` prints the
  same four-scenario narrative and counts: "26 events from research_agent,
  grind, fabric, http_gun" are joined and the same 6 / 15 / 5 http_gun,
  llm_wire and saga events stay unattributed.
- **Glue measure, before → after**:

  | Seam                                  | Before                                                                         | After                                             | Change                                                                                     |
  | ------------------------------------- | ------------------------------------------------------------------------------ | ------------------------------------------------- | ------------------------------------------------------------------------------------------ |
  | getter annotations (domain, publish)  | 12 `fn(x: Type)`                                                               | 0                                                 | `get: fn(x) { x.field }`; domain 163 → 161 lines, publish 214 → 206                        |
  | one-field Blueprint records           | 7 lines each (x2)                                                              | 7 lines each                                      | annotation gone, but `describe` still makes `gleam format` break the call                  |
  | Blueprint → Grind bridge (wire.gleam) | 41 (4-line `case` with `panic`)                                                | 38 (`result.map_error`)                           | panic deleted; bridge and `let assert Ok(worker.codec(..))` kept                           |
  | state event (events.gleam)            | 72, `Option(Correlation)`                                                      | 64, `required_field()` + `include`                | `Some`/`option.from_result` wrapper, `Option` import and the `fields.parameter` block gone |
  | collector arm for the state event     | `case Some/None`                                                               | direct                                            | the unreachable `None -> Nil` arm deleted                                                  |
  | http_gun join table (telemetry)       | `new_id` + `BindHttp` + `Dict` + `Http` key + 3-tuple `Snapshot` + `bind_http` | pass the research's `Correlation`; `Research` key | telemetry.gleam 433 → 400; `researcher.context` 3 → 2 args; remote.gleam 81 → 79           |

  Net: 61 source lines removed, 0 added in new modules; tests changed by 2
  lines (`Transition(state, id)`, one comment).

- **New friction**:
  - **The id is parsed twice and the failure is swallowed twice.**
    `Research.id` is a `String`, so `events.announce` and `remote.correlated`
    each call `correlation.from_string`. In `announce` an `Error` skips the
    event; in `correlated` it returns an uncorrelated client, which silently
    drops that request's http_gun events from the trace. Both are unreachable
    for ids from `correlation.unique()`, but a test or caller that passes a
    long id loses telemetry with no signal. `Research.id: Correlation`
    (with a codec that stores the string) would remove both, at the cost of
    touching the row, job input and saga execution id.
  - **`field()` still forces an `Option` on the http_gun side.** The collector
    keeps `case m.correlation { Some(id) -> .. None -> Unkeyed }` for
    http_gun events, as intended for a library, so the model's un-tagged
    calls remain `Unkeyed`.
  - **The new Grind rejection path is not exercised.** None of this app's
    codecs has a refinement, so `InvalidInput` and `ExecutedUnencodable`
    cannot happen here; the fix removes a panic that no test could reach. A
    codec with `integer_between` on `Research` would be needed to cover it.
  - **Formatting cost of `get:`.** The labelled getter after the field adds
    characters, and several calls that fit on one line before now wrap
    (`draft_id`, `research_id`); the net is still fewer lines because the
    `fn(x: Type)` annotation went.
- **Migration guides**: sufficient. The sinal and json_blueprint tables and the
  http_gun "pass the app's own correlation" example covered every edit,
  including the exact research_agent call sites. Gap: the http_gun guide
  tells apps to drop their join table but not what to do when the app's id is a
  `String` that must be parsed (the `from_string` failure case above).

## Re-run after wave 3

Package heads: grind 008b657 (facade 749c0dc), saga 2ee5e0a (with
`saga_postgres`), http_gun 1a5f5ef, sinal 44c5395 (`from_key` c6e2d36),
json_blueprint 74a9a7d, fabric d10635f, llm_wire 576482e.

- **Tests**: 9 passed, no failures (`../scripts/with-postgres.sh gleam test`),
  including both OTP-peer crash-recovery tests, which now rely on Grind's
  `ReplayAfterLeaseExpiry` instead of the app's sweep. Three tests changed
  intent because the redesign removed the gap they proved:
  - `cancelling_the_job_reaches_the_run_and_closes_the_llm_stream_test` (was
    `cancellation_reaches_the_run_..`, which asserted that `postgres.cancel`
    alone left the stream open): `grind.cancel` alone closes it.
  - `saga_postgres_on_the_shared_pool_passes_saga_conformance_test` (was the
    conformance test of the deleted adapter): saga's suite against
    `saga_postgres` on Grind's pool.
  - The common-path test now expects saga events in the request's trace and
    none unattributed.

  `gleam run` prints the four scenarios; the trace line reads "30 events from
  research_agent, grind, fabric, http_gun, saga" (was 26 without saga), and
  only `http_gun: 6, llm_wire: 15` stay unattributed. The build passes
  `--warnings-as-errors` and `gleam format --check`.

- **Glue measure, before → after**:

  | Seam                                | Before                                  | After                     | Change                                                                                               |
  | ----------------------------------- | --------------------------------------- | ------------------------- | ---------------------------------------------------------------------------------------------------- |
  | saga ↔ PostgreSQL (RA-6)            | 262 + 6 pid FFI + 8 DDL                 | 10                        | `saga_store.gleam` deleted; `saga_postgres` config, migrate and storage on the shared pool           |
  | crash: replay abandoned jobs (RA-2) | 38 + `db.unfinished` 11 + 3 (+ 10 test) | 1                         | `worker.with_abandonment(ReplayAfterLeaseExpiry(max_replays: 3))`                                    |
  | cancellation fan-out (RA-5)         | 37                                      | 8 + 9 in `follow`         | `grind.cancel`; the handler polls `worker.cancellation` and calls `fabric.cancel`                    |
  | Grind runtime and pools (RA-11)     | ~30 + a second pool                     | 16 + one supervised child | one pool from the app's `pog.Config`; registry, policy validation and consumer start gone            |
  | waiting for an outcome              | 13 (sleep and poll)                     | 6                         | `grind.await(within:)`                                                                               |
  | join index (db.gleam, RA-1)         | 158                                     | 132                       | `set_job`, `unfinished` and the saga DDL gone; the row is inserted in the `submit_in` transaction    |
  | grind job drives fabric run (RA-1)  | 81                                      | 97                        | + the cancellation arm; `Response` constructors                                                      |
  | saga drive errors → job response    | 5                                       | 13                        | `durable.error_kind`: `Busy`/`Transient` snooze, the rest `Uncertain`                                |
  | codec bridges (wire.gleam, RA-8)    | 38                                      | 27                        | total `worker.codec` + `with_codec_version`; `saga_codec.json`                                       |
  | http_gun clients (RA-11)            | 16 + two clients                        | 18, one client            | `loopback_only() \|> only_hosts([host:port])`; 9 of the 18 lines parse the URL                       |
  | telemetry joins (RA-7)              | `Job` + `Run` bindings                  | `Run` only                | grind and saga keyed by correlation; telemetry.gleam 400 → 391                                       |
  | correlation parse (events, remote)  | 2 × `from_string`, error dropped        | 2 × `from_key`            | no silent drop                                                                                       |
  | publish.gleam                       | 206                                     | 226                       | labelled `durable.recoverable` wraps over more lines; `describe` matches `StepFailed` for the detail |
  | lifecycle (FFI, peer owner)         | 16 FFI + 13 owner + 6 pid FFI           | 16 FFI + 13 owner         | pid FFI gone; `static_supervisor` still has no stop                                                  |

  Source: 755 lines removed, 377 added (3134 → 2756, −378); tests 434 → 443.

- **Glue that remains, and its owner**:
  - **RA-1 join row and state machine** (fabric, FABRIC-R2 and FABRIC-R13,
    wave 5; decision 1): the `run_id` column, `db.set_run` after the run's
    first commit, `telemetry.bind_run`, and the 97-line `drive_agent` /
    `start_run` / `follow` loop that starts or recovers the run, recovers
    again on `Unattended`, restarts after "no sources" and maps each ending.
    With caller-supplied run ids (`run_id = "research-" <> id`) the column,
    `set_run`, `bind_run` and the start-or-recover branch go. The loop stays
    until a `fabric_grind` driver exists, which decision 1 (option B: "the
    job is the driver and fabric's sweeper stays off") makes the owner's
    call.
  - **RA-3 run id issued by Fabric** (FABRIC-R2, wave 5): unchanged; an orphan
    run is still possible between `fabric.start` and `db.set_run`.
  - **RA-4 read-only tool reconciliation** (FABRIC-R9, wave 5): 77 lines
    unchanged.
  - **RA-7 model calls unattributed** (FABRIC-R8, FABRIC-R15, wave 5): 6
    http_gun and 15 llm_wire events per request; Fabric's own events join
    through `bind_run`.
  - **RA-10 typed answer** (FABRIC-R1, wave 5): the 46-line `TITLE:` parser.
  - **Model failures as strings** (FABRIC-R4, wave 5).
  - **RA-8 bridges** (grind, saga; open): `wire.grind` and `wire.saga`, 27
    lines, because neither takes a Blueprint codec.
  - **The row's later states** (grind): written outside Grind's
    acknowledgement; Grind has no acknowledgement inside the handler's
    transaction.
  - **Lifecycle** (gleam_otp): the FFI `shutdown` and the peer's owner
    process.

  Decision 1: with the wave 3 Grind and Saga APIs the app already runs the
  split option B states. Grind delivers (abandonment policy, cancellation in
  the job context), Saga runs the publication (one `Run`, its own storage),
  Fabric holds the conversation, and correlation crosses Grind, Saga and
  http_gun. Every line of join glue that is left belongs to Fabric's side of
  that split.

- **New friction**:
  - **The worker cannot use `grind.connection`.** The worker's handler needs
    the pool (Fabric's store, the saga storage, the `research` table), the
    worker must be in Grind's `Config`, and `grind.connection` panics until a
    runtime is configured. The app names the pool itself and relies on the
    documented "Grind keeps the config's pool name":

    ```gleam
    let pool_name = process.new_name("research_pool")
    use pool <- result.try(pog.url_config(pool_name, url) |> ..)
    let database = pog.named_connection(pool_name) // = grind.connection, later
    let deps = jobs.Deps(db: database, runs: .., sagas: saga_postgres.storage(..), ..)
    let config = grind.new(pool) |> grind.with_worker(jobs.worker(deps)) |> ..
    ```

    It works, but the guide's "use `grind.connection` for the app's queries
    and saga storage" cannot be followed for anything a handler captures.
    `worker.Context` carrying the connection, or a handler that receives
    the `Grind` handle, would remove the workaround.

    **Status (wave 3 fixes):** partially resolved by grind 9ccbfb5;
    `worker.connection(context)` replaces the handler's pool name, so
    `Deps.db` is gone and the handler reads and writes the `research` table
    through the context. The pool name stays in `app.start` only because
    Fabric's store and the saga storage are built over a connection before the
    runtime exists; the constructors need it, the handler does not.

  - **Consumers start before the app is ready.** `grind.supervised` starts the
    consumers with the pool, and `grind.migrate` needs the running runtime,
    so the queue polls before Grind's tables, the `research` table, Fabric's
    tables and the Fabric store exist (app.gleam:159-187). A due job claimed
    in that window fails its handler. Here only the crash test has such a
    job, and its 6 s lease keeps it out of reach. A
    `grind.without_consumers` runtime plus a later `start_consumers`, or a
    migration hook run before the consumers, would close the window.

    **Status (wave 3 fixes):** resolved by grind 9ccbfb5 for Grind's schema:
    `grind.supervised(config |> grind.with_startup_migration)` migrates before
    any consumer polls and `grind.migrate` is gone from `app.start`. The app's
    own tables (`research`, Fabric, Saga) are now migrated before Grind
    starts, on a one-connection pool that `app.migrate_app` shuts down, since
    the runtime cannot start consumers later and a job from a previous version
    can be due at once (18 lines).

  - **The handler polls for cancellation.** `fabric.await` takes a timeout,
    not a selector, so the handler cannot wait on the run and on
    `worker.cancellation` at once and checks the selector between 250 ms
    waits (jobs.gleam:243-262). The cancellation already arrives only at
    the lease renewal (≤ 2 s here), so the 250 ms costs little, but it is a
    loop the app owns. Fabric-owned: an `await` that also returns on a
    caller's selector.

    **Status (round 5):** resolved by `fabric.await_with`. `follow` waits for
    the run and `worker.cancellation` in one receive (5 s slices, only
    because the loop also re-reads the status), and the 250 ms polling and its
    `selector_receive` are gone.

  - **The handler's cancel reason is dropped**: the job ends
    `Cancelled("cancelled by caller")` though the handler returned
    `Cancelled("research cancelled")` (grind; the test pins it).
  - **RA-12**: a replay emits no `quarantined` event and uses a business
    attempt, contrary to `with_max_attempts`'s doc.

    **Status (wave 3 fixes):** resolved by grind 6bd06ec. The crash tests now
    assert one `[grind, job, quarantined]` event with `replayed: True` and
    `summary.attempt == 1` after one replay (they pinned "no event" and
    attempt 2).

  - **`execution.describe_cause` omits the step's error** ("step publish
    returned an error"), so `publish.describe` matches
    `StepFailed(_, PublishError(step, detail))` to keep "HTTP 500" in the job's
    discard reason (6 lines, saga).

    **Status (wave 3 fixes):** resolved by saga 92612fd.
    `execution.describe_cause(cause, error: ..)` renders the step's error
    ("step publish returned an error: HTTP 500"), so the `StepFailed` match in
    `publish.describe` is gone.

  - **`only_hosts` takes `host:port` strings**, and the app has a base URL, so
    pinning the port needs a 9-line `uri.parse` (http_gun, nit).
  - **Two bounds to align by hand**: `durable.drive(run, timeout: 60_000)` runs
    inside a handler whose own timeout is 15 min by default.
    `worker.deadline(context)` returns an absolute `Timestamp`, so deriving
    the saga's `timeout:` from the job's budget needs clock arithmetic; the
    app picks a constant (saga, grind; minor).
  - **`duration` everywhere**: Grind's and the queue's settings take
    `Duration`, http_gun's and saga's take `Int` milliseconds, so one
    `app.start` mixes `duration.milliseconds(1500)`,
    `http_config.Milliseconds(5000)`, `with_lease(10_000)` and
    `drive(timeout: 60_000)`, and `gleam_time` became a direct dependency
    (nit; cross-package).
- **What worked well in wave 3**: `pog.transaction` around `grind.submit_in`
  and the app's insert reads like any other write; `grind.await` replaced the
  polling helper; `ReplayAfterLeaseExpiry` is one line and both crash tests
  passed unchanged in their assertions on the scripted services;
  `saga_postgres` dropped in on Grind's pool and passed the conformance suite
  there; `durable.with_correlation` and `job.with_correlation` attributed
  every Grind and Saga event with no table; `durable.error_kind` made the
  saga-to-job mapping a four-arm `case`; llm_wire's per-call view let one
  http_gun client replace two.
- **Migration guides**: sufficient. The grind index for research_agent named
  RA-2, RA-5 and RA-11 with their replacements, and the saga index named
  every changed call site in `publish.gleam` and `wire.gleam`. Gaps: the
  grind guide does not say that the worker must exist before
  `grind.connection` can be called, nor that consumers start before
  `migrate`; the saga guide's `codec.json` example is exact.

### After the follow-up fixes

Tests: 9 passed (the common-path test gained an assertion that the
unqualified `research` table lives in the node's schema, which the app's own
`search_path` now decides, grind 9ccbfb5). `gleam run`, `--warnings-as-errors`
and `gleam format --check` pass. `saga.define` is total and `durable.new`
dropped `version:` (no `let assert Ok`, no `result.try`). The `Busy` snooze
was already 1 s and stays, because the lease is the fallback when the
runner's node is lost. No `Admission` branch or `unknown_when` step exists in
this app. Source and tests: about 55 lines removed, 105 added (`migrate_app`,
`pool_config` and the settings helpers account for most of the additions).

## Re-run after wave 4

Package heads: llm_wire 9f35183, http_gun 4a6eeb0, saga af644b0, fabric
556abc3.

- **Tests**: 9 passed, no failures (`../scripts/with-postgres.sh gleam test`),
  including both OTP-peer crash-recovery tests. `gleam run` prints the four
  scenarios; `gleam format --check` and `gleam build --warnings-as-errors`
  pass. One test changed intent: the common-path test now expects llm_wire
  events in the request's trace and none of llm_wire, saga or http_gun
  unattributed. Stored formats: the app writes no turn envelope of its own.
  The Fabric transcript is stored by fabric through llm_wire's
  `turn_replay_*` codecs, whose read compatibility with earlier
  `llm_wire.turn.v1` records is fabric's claim (fabric 556abc3 tests); this
  app has no old-format fixture of its own, so I did not prove it here.

- **Glue measure, before → after**:

  | Seam                                 | Before                                                     | After                               | Change                                                                                            |
  | ------------------------------------ | ---------------------------------------------------------- | ----------------------------------- | ------------------------------------------------------------------------------------------------- |
  | scripted OpenAI SSE (services.gleam) | 70 (`event`, `tool_call`, `answer`, `completed`)           | 24 (`reply`, `tool_call`, `answer`) | `testing.events_for(message.OpenAI, ..)` with the usage; file 671 → 604 lines                     |
  | llm_wire config (researcher.gleam)   | 3 `let assert` (key, model id, endpoint) + 2 pipes         | 4, no assert                        | `openai.new \|> openai.config \|> with_endpoint`; the endpoint is checked by `prepare`            |
  | millisecond conversions              | 6 literals and 1 wrapper (`duration.milliseconds(within)`) | 0                                   | `Duration` in `publish.run`, `await_outcome`, saga lease, step timeout, http timeout, conformance |
  | llm_wire events joined (RA-7)        | 0 of 15                                                    | 15 of 15                            | `+12` for `agent_for`; telemetry observer keys on `m.correlation`                                 |
  | agent construction                   | once at start                                              | once to validate + once per context | `Deps.agent: fn(Context) -> Agent(Context)`; `app.snapshot` builds one too                        |

  Source: 2588 lines in `src/research_agent/` (was 2624), tests unchanged in count.

- **Seams still needing glue, and owner**:
  - **Model correlation by agent rebuild** (fabric, FABRIC-R8, wave 5):
    correlation reaches llm_wire only because the app builds an agent over the
    correlated client for each context. A `model.Request` that carried the run
    or a context would remove `agent_for`, the `let assert` in it and the
    start-time validation build.
  - **Lease and wait integers** (fabric, fabric_postgres): `with_lease` takes
    `Int` milliseconds, `fabric.await(handle, 250)` takes `Int`, and the app's
    `Settings.fabric_lease_ms` mirrors it. The app's own `await_outcome` is a
    `Duration`, so the `Int` stops at fabric's border.
  - **RA-1, RA-4, RA-10**, the `Model failures as strings` item (fabric,
    wave 5) and **RA-8 bridges** (grind, saga): unchanged.

- **New friction**:
  - `researcher.agent_for` hides a `let assert` behind a start-time check, a
    pattern the app would not need if the model took per-run context.
  - `testing.events_for` yields `Events(chunks)`, and the app has to
    `let assert` that shape to join the chunks into one response body; a
    `testing.body(reply)` returning the concatenated SSE would fit a fake
    server directly.
  - `testing.tool_calls("", ..)` takes the assistant text as a required
    string; `""` reads as a magic value.
  - `saga.step` timeouts now need `execution.After(duration.seconds(5))`:
    longer than `5000`, and the wrapper only matters where `Infinity` is
    meant.

- **Migration guides**: accurate. The saga guide named all four research_agent
  sites, and the http_gun table named the `Milliseconds(5000)` site. The
  llm_wire guide named `researcher.gleam`, `telemetry.gleam`, `services.gleam`
  and the test. It did not say that correlation needs the agent built per
  research for fabric's model; that is the one step the guide left to the app.

### After round 5

Package heads: fabric fd60851 / 409f1a7 (local, not pushed).

- **Tests**: 9 passed, no failures (`../scripts/with-postgres.sh gleam test`),
  including both OTP-peer crash-recovery tests, which replay the job in
  another VM and find the run by its derived id. `gleam run` prints the four
  scenarios; `gleam format` and `gleam build --warnings-as-errors` pass. One
  assertion added: no fabric event is unattributed.
- **Lines** (`git diff --numstat`, source and test): 177 added, 205 removed,
  net 28 fewer. By file: `db.gleam` 137 → 110 (`run_id` column and field,
  `set_run`), `telemetry.gleam` 398 → 387 (`Run` key, `BindRun`, run table,
  `bind_run`), `remote.gleam` 70 → 61 (`correlated`), `researcher.gleam`
  203 → 202 (`agent_for` 12 lines out; the correlation plumbing in), `jobs.gleam`
  318 → 318 (81 lines rewritten), `app.gleam` 330 → 349 (the `snapshot`
  attempt lookup, 21 lines, and `Duration` settings). The Duration changes
  are `model_retry_delay`, `fabric_lease`, `await_with` and `with_lease`; no
  millisecond integer reaches fabric any more.
- **Unattributed events per request**: 0 of 51 on the common path (was 0 of
  51, but through `bind_run`). Remaining holes, not exercised by a test:
  fabric's `lease.lose` carries no correlation, and Sinal's
  `forwarder.dropped` is unkeyed by nature.
- **New friction**:
  - A derived run id needs Grind's attempt, which only a running handler
    reads. `app.snapshot` goes through the operator listing (`admin.list`
    with `after(job_id - 1)`, limit 1) to find it. Grind should offer the
    attempt on a handle, or fabric should open "the latest run of a family".
  - `run.parse_id` is a `Result` for a string the app built from two
    integers, so `jobs.run_id` carries a `let assert`; a constructor from a
    prefix and a number, or `run.id_from(parts)`, would not.
  - The saga step gets no `tool.Call`, so the publication's HTTP client is
    still correlated by hand. The app's saga is started by the job, not by a
    fabric tool, so `fabric_saga.tool` does not apply.
  - `StartUnconfirmed` is the caller's to retry; the app wrote a three-try
    recursion for it. Fabric could retry once itself, since the id is
    idempotent.
  - `fabric.cancel`'s non-cancelled result and a consumed `Interrupted(Nil)`
    drop a cancellation silently: when the run finished in the same moment,
    the job follows the run to its end. This was true of the polling loop
    too, and is now visible at the call.
- **Migration guide**: accurate for the three sites it names. It said the job
  could "start under `run.parse_id(job_id)`", which is only right if a retry
  may reopen a finished run; this app's `NoSources` retry needs the attempt
  in the id, which the guide does not mention.

### After wave 5

Package heads: fabric ee83046 (F6), saga 9a0b1d8, llm_wire 0e4f01a.

- **Tests**: 10 passed, no failures
  (`../scripts/with-postgres.sh gleam test`), including both OTP-peer
  crash-recovery tests. `gleam format --check`, `gleam build
--warnings-as-errors` and `gleam run` pass (51 events
  joined, none unclaimed). One test added (corrective turn), one rewritten
  (replayed read), and the common-path test checks the union schema in the
  request.
- **Lines** (`git diff --numstat`, source, test and README): 261 added, 209
  removed, net 52 more: the new test, the request log and `article`, `no_sources`
  and `GarbledOnce` in the scripted provider, the union check and the job's
  `Unavailable` ending account for the growth. By file:
  `researcher.gleam` 202 → 145 (replay glue out, answer type in), `jobs.gleam`
  318 → 290, `domain.gleam` 161 → 172 (parser 46 out, codec 57 in),
  `publish.gleam` 220 → 225 (`via`, key reads), `services.gleam` 604 → 629
  (test-only builders), `telemetry.gleam` 387 → 392 (`lease.lose` keyed, the
  saga observers lost `keyed`).
- **Unattributed events per request**: 0 of 51 on the common path; the
  test asserts none for fabric, llm_wire, saga and http_gun. `lease.lose` is
  now attributable; Sinal's `forwarder.dropped` stays unkeyed by nature.
- **Not applicable here**: `ProviderDelay` and the `llm_wire.advise`
  retry advice (the job retries a business failure, never a provider one),
  `fabric/reviewer`, approval expiry and `sweeper.supervised` (no
  approvals; the job drives the run, so no sweeper). `services` builds no
  `llm_wire.Failure` by hand: its only use of llm_wire testing was
  `events_for`, now `testing.http_response(..).body` (5 lines → 4).
  Failing the provider (`rate_limited`, `overloaded`) would be a new test
  scenario, not a deletion.
- **New friction**:
  - **A sum-type answer needed fabric F6 and llm_wire 0e4f01a.** First
    pass: `codec.union` is a `oneOf` of `{tag, value}`, and providers need an
    object root, so the answer was a record with a `found_sources` flag and
    a `text` field that meant two things (a title could accompany
    `found_sources: false`). Catch-up: fabric `ee83046` wraps a non-object
    root as `{"answer": ..}` and llm_wire `0e4f01a` takes the nested union in
    strict output, so `domain.answer_codec` is the natural
    `Written(title, body) | NoSources(reason)` union again and the flag is
    gone. The common-path test checks the scripted provider's request:
    `text.format` is `json_schema`, `strict: true`, the root requires
    `answer`, and its `anyOf` holds the `written` and `no_sources` variants.
    The scripted provider replies `{"answer": {"tag": ..}}`. Cost: the
    model sees `{"tag", "value"}` plumbing, so the fake and any hand-written
    reply carry it; the doc for F6 says the wrapper is unwrapped for the
    run, but not that a scripted provider must send it.
  - **The corrective turn is invisible to a scripted provider.** The fake
    chooses its step by counting `function_call_output` items, and the
    corrective turn adds none, so it replays the same step. `GarbledOnce`
    keys on how often a step was hit. The wave-5 doc says tests count two
    model calls on a refused answer, but not that step-counting fakes
    need a hit counter.
  - **`with_replay(3)` has no visible effect except in `ActionRecord.replays`.**
    A replayed read leaves `Succeeded` and no event the app observes, so the
    only evidence is `snapshot.actions[..].replays`. A `tool.dispatched`
    event with the attempt number would make the telemetry story match the
    record.
  - **An unreadable record on a taken id** is now the read's error, not
    `AlreadyStarted(_, False)`. `start_run` retries `StoreUnavailable` like
    `StartUnconfirmed` (three tries), then a store that stays out of reach
    snoozes the job one second (`worker.Snoozed`, a new `Unavailable` ending),
    so Grind delivers it again and the start finds its run. `CorruptRecord`,
    `UnsupportedVersion` and `AlreadyStarted(_, same_input: False)` stop the
    job (`AgentStopped`), because no retry changes them. Not covered by a
    test: no scenario here can make Fabric's store fail or hold a corrupt
    record on a job's derived id.
  - **`tool.with_replay` is applied after `bind`, to a list**, so the app maps
    it over the list. A `bind` variant (`tool.bind_replayable`) would read
    better only if more than one policy per tool were needed; as is, fine.
  - `StartUnconfirmed`'s three-try recursion (round 5) is unchanged:
    `fabric.error_kind` calls it `Unavailable`, which does not say "the
    same id may be started again", and the app needs that exact variant.
- **Migration guide**: accurate for every research_agent site it names
  (`AlreadyStarted(..)`, `with_limits`, the `TITLE:` parser, `parse_id`,
  `reconcile`, `publish.gleam:55,76`). It does not say that a union is a
  poor answer codec (see the friction above), and its `Dependents` for
  llm_wire says the `let assert testing.Events` becomes
  `http_response(..).body`, which was right.
