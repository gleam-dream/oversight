# research_agent

[![CI](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

A research agent that resumes after a crash and publishes through a compensating
workflow. `start_research(topic)` records the request and enqueues a Grind job in one
transaction. The job runs a Fabric agent with `search` and `read` tools against scripted
HTTP APIs, Fabric checkpoints each turn in PostgreSQL, and a durable Saga then publishes
the article. A second recipe exercises Fabric history-aware invocation with
transactional turn admission and idempotent outcome incorporation.

Every external service runs on one loopback mist server in `src/research_agent/services.gleam`:
a search API, the pages, a publisher and a scripted OpenAI Responses provider.

## Run

From this directory, inside the Oversight shell:

```sh
../scripts/with-postgres.sh gleam test
../scripts/with-postgres.sh gleam run
```

The history recipe lives in `test/history_delivery.gleam` and runs with the same
command. The crash tests start a second BEAM VM with OTP's `peer` module and kill it
with `SIGKILL` mid-model call, mid-tool, or after a publisher mutation before its reply.
A node in the test VM then reruns the job after its lease expires.

The [composition contract](../../docs/design/design-layer.pdf)
describes the integrations and evidence. [ADR 0013](../../docs/adr/0013-demonstrate-history-invocation-with-existing-delivery.md)
and [ADR 0024](../../docs/adr/0024-fail-closed-on-earlier-publication-checkpoints.md)
record the decisions.
