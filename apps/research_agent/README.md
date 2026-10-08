# research_agent

A research agent that resumes after a crash and publishes through a
compensating workflow.

`start_research(topic)` records the request and enqueues a Grind job in the same
transaction (`grind.submit_in`). The job runs a Fabric agent with two tools, `search(query)`
and `read(url)`, against scripted HTTP APIs. Fabric checkpoints every model turn
and tool result in PostgreSQL (`fabric_postgres`), so a job replayed after its VM
died resumes the run from the last commit instead of starting over. When the agent
answers, a durable Saga publishes the article (create draft, upload body,
publish). A definite failure deletes the draft. An unconfirmed mutation holds
its effects. Unconfirmed mutations and failed cleanup leave both the Grind job
and application state `uncertain` and stop automatic mutation replay.
Cancelling the job through Grind reaches the handler, which cancels the run
and so closes the LLM stream. Grind, Fabric, Saga and the app share one pog
pool, which Grind builds from the app's `pog.Config`.

Every external service runs on one loopback mist server
(`src/research_agent/services.gleam`): a search API that can fail, the pages, a
publisher whose publish step can fail, and an OpenAI Responses SSE provider that
follows a per-topic script. A `Stall` step keeps the stream open and reports when
the client closes it.

## Running

Inside the oversight dev shell, from this directory:

```sh
../scripts/with-postgres.sh gleam test
../scripts/with-postgres.sh gleam run
```

The crash tests start a second BEAM VM with OTP's `peer` module, using the same
code paths. They run a node there and kill that VM with `SIGKILL` while it is
mid-model call, mid-tool, or after a publisher mutation before its reply. Then a node in the test VM runs the job again once
its lease expires (Grind's `ReplayAfterLeaseExpiry`).

## Library responsibilities

| Integration                        | Where                                                     | What it exercises                                                                                                                                |
| ---------------------------------- | --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| grind job → fabric run             | `jobs.gleam` (`drive_agent`, `follow`)                    | Starting or recovering a run from a job, waiting on it, mapping its end to a `worker.Response`                                                   |
| fabric ↔ PostgreSQL                | `app.gleam` (`fabric_postgres.store`, `store.supervised`) | A leased store on the pool Grind runs: the conversation persisted between turns                                                                  |
| fabric ↔ llm_wire ↔ http_gun       | `researcher.gleam` (`llm.model`)                          | The provider adapter on a caller-owned loopback client                                                                                           |
| fabric tools ↔ http_gun, Blueprint | `researcher.gleam`, `domain.gleam`                        | Typed tools whose output codec also decodes the HTTP payload; a policy gate on `read`                                                            |
| crash → grind → fabric             | `jobs.worker`, `researcher.build`                         | Abandoned jobs replayed by Grind's abandonment policy; interrupted read-only tools replayed by Fabric (`tool.with_replay`)                       |
| cancellation API → grind → fabric  | `app.cancel_research`, `jobs.follow`                      | `grind.cancel`; the handler's `worker.cancellation` cancels the run, the model task dies and the stream closes                                   |
| fabric answer → saga               | `jobs.handle`, `publish.gleam`                            | A durable, compensating workflow over http_gun, checkpointed in PostgreSQL                                                                       |
| saga ↔ PostgreSQL                  | `app.gleam` (`saga_postgres`)                             | Saga's PostgreSQL storage on the shared pool, checked there by `saga/storage/conformance`                                                        |
| one codec for grind and saga       | `domain.gleam`, `wire.gleam`                              | One Blueprint codec per value, adapted to Grind's `worker.codec` and Saga's `codec.json`                                                         |
| telemetry                          | `telemetry.gleam`, `events.gleam`                         | Sinal events of grind, fabric, saga, llm_wire, http_gun and sinal, joined per request where possible; the app's own events carry a `Correlation` |

Packages: fabric, fabric_postgres, grind, saga, saga_postgres, llm_wire,
http_gun, json_blueprint and sinal, plus pog and mist. The [ecosystem design](../../docs/design/design-layer.pdf) records the composition contract.

## Publication evidence and checkpoint compatibility

The scripted publisher guarantees that HTTP 409 rejects before mutation. Other
unexpected responses, malformed success bodies, and HTTP failures marked
`MaybeSent` retain uncertainty through Saga's `unknown_when` and
`outcome.classify` into Grind. A transport `NotSent` is a definite failure.
Creating and uploading each own an idempotent draft deletion undo; repeated
DELETE accepts 204 or 404. A rejected publication is definite only when these
undos succeed. Failed cleanup remains uncertain.

On interruption, creation looks up its idempotency key. Upload and publication
read the draft's committed state; `uploaded` or `live` proves upload, and `live`
with its URL proves publication. Missing, malformed, or unavailable readback
cannot exclude a late commit, so it never authorizes another mutation. The
consumer requires this readback contract from its publisher; idempotence alone
is not evidence that the earlier operation was never sent.

Publication uses step version `2` and error codec `publish-error-2`. Existing
version 1 checkpoints deliberately fail closed as incompatible, including
finished failures: the old error lost effect evidence, which cannot be recovered
from its text. The compatibility test creates such a checkpoint with the frozen
v1 consumer and verifies that reconnect leaves its bytes and revision unchanged
and makes no further publisher request. Reconcile these records using provider
evidence before an explicit operational migration; do not delete or relabel them
as safely retryable. Existing Grind records already discarded by v1 are not
retroactively repaired by this change.

The tests use real local HTTP, temporary PostgreSQL, and peer VM termination.
They cover accepted mutations with lost replies, malformed success bodies,
definite rejection, failed cleanup, confirmed recovery without duplicate
mutations, unavailable recovery evidence, and v1 checkpoint refusal. They make
no live-provider conformance claim.
