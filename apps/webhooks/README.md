# webhooks

[![CI](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

A multi-tenant outbound webhook service. Tenants register endpoint URLs, an application event
fans out to one Grind job per active subscription, and a worker signs each delivery and sends it
through HTTP Gun. The delivery id is the receiver's idempotency key, and the HTTP result maps back
to Grind retry, snooze, discard or failure outcomes under a per-tenant destination policy.

## Run

From this directory, inside the Oversight shell:

```sh
../scripts/with-postgres.sh gleam test
../scripts/with-postgres.sh gleam run
```

`gleam run` starts the API and a scripted receiver on loopback, registers endpoints over HTTP
(including rejected SSRF attempts and a DNS-rebinding host), publishes two events, waits for
delivery and prints each outcome, the receiver's signature checks and one delivery's telemetry trace.

The tests are in [`test/webhooks/`](test/webhooks/): core mapping, delivery and cassette replay.
The [composition contract](../../docs/design/design-layer.pdf) describes
signing, destination policy and outcome mapping.
