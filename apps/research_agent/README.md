# research_agent

A long-running research agent. `start_research(topic)` records the request and
enqueues a Grind job. The job runs a Fabric agent with two tools, `search(query)`
and `read(url)`, against scripted HTTP APIs. Fabric checkpoints every model turn
and tool result in PostgreSQL (`fabric_postgres`), so a job replayed after its VM
died resumes the run from the last commit instead of starting over. When the agent
answers, a durable Saga publishes the article (create draft, upload body,
publish). If a step fails after the draft exists, the saga deletes the draft.
Cancelling through the API cancels the job and the run, which closes the LLM
stream.

Every external service runs on one loopback mist server
(`src/research_agent/services.gleam`): a search API that can fail, the pages, a
publisher whose publish step can fail, and an OpenAI Responses SSE provider that
follows a per-topic script. A `Stall` step keeps the stream open and reports when
the client closes it.

## Running

Inside the oversight dev shell, from this directory:

```sh
../scripts/with-postgres.sh gleam test   # 9 tests
../scripts/with-postgres.sh gleam run    # the four-scenario narrative
```

The crash tests start a second BEAM VM with OTP's `peer` module, using the same
code paths. They run a node there and kill that VM with `SIGKILL` while it is
mid-model call or mid-tool. Then they recover on a node in the test VM.

## Packages and seams

| Seam                               | Where                                                     | What it exercises                                                                                                                                |
| ---------------------------------- | --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| grind job → fabric run             | `jobs.gleam` (`drive_agent`, `follow`)                    | Starting or recovering a run from a job, waiting on it, mapping its end to a `WorkerResponse`                                                    |
| fabric ↔ PostgreSQL                | `app.gleam` (`fabric_postgres.store`, `store.supervised`) | A leased store on the app's pog pool: the conversation persisted between turns                                                                   |
| fabric ↔ llm_wire ↔ http_gun       | `researcher.gleam` (`llm.model`)                          | The provider adapter on a caller-owned loopback client                                                                                           |
| fabric tools ↔ http_gun, Blueprint | `researcher.gleam`, `domain.gleam`                        | Typed tools whose output codec also decodes the HTTP payload; a policy gate on `read`                                                            |
| crash → grind → fabric             | `jobs.recover_abandoned`, `researcher.replay_read_only`   | Quarantined jobs replayed by the app; uncertain read-only tools reconciled by the app                                                            |
| cancellation API → grind → fabric  | `app.cancel_research`                                     | `postgres.cancel` plus `fabric.cancel_stored`; the model task dies and the stream closes                                                         |
| fabric answer → saga               | `jobs.handle`, `publish.gleam`                            | A durable, compensating workflow over http_gun, checkpointed in PostgreSQL                                                                       |
| saga ↔ PostgreSQL                  | `saga_store.gleam`                                        | An app-written `saga/storage.Storage`, checked by `saga/storage/conformance`                                                                     |
| one codec for grind and saga       | `domain.gleam`, `wire.gleam`                              | One Blueprint codec per value, adapted to Grind's `worker.codec` and Saga's `codec.new`                                                          |
| telemetry                          | `telemetry.gleam`, `events.gleam`                         | Sinal events of grind, fabric, saga, llm_wire, http_gun and sinal, joined per request where possible; the app's own events carry a `Correlation` |

Packages: fabric, fabric_postgres, grind, saga, llm_wire, http_gun,
json_blueprint and sinal, plus pog and mist. The findings are in
[FEEDBACK.md](FEEDBACK.md).
