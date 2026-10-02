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

### RA-11 Small frictions

- **Two pools on one database** (grind, minor; grind card): Grind opens its own
  pool from a URL (app.gleam:149-164). The app opens a second one for
  `fabric_postgres`, the saga checkpoints and the research index
  (app.gleam:92-105). The research row's state is written outside Grind's
  acknowledgement, so it can say `published` while the job is still
  `executing` after a crash. Replay is idempotent here because Saga
  reconnects to its finished outcome.
- **Lifecycle** (grind, gleam_otp, nit): `queue.start` links to its caller and
  only that process may stop it. The crash test's peer node therefore needs a
  long-lived owner process (node.gleam:46-58). `static_supervisor` has no
  stop, so `app.stop` calls `exit(Pid, shutdown)` from FFI
  (app.gleam:217-228).
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
