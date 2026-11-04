# webhooks

[![CI](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

A multi-tenant outbound webhook service. Tenants register endpoint URLs, an application event
fans out to one Grind job per active subscription, and a worker signs each delivery and sends it
through HTTP Gun. The HTTP result maps back to Grind retry, snooze, discard or failure outcomes
under a per-tenant destination policy.

Every API call carries the tenant's key as `Authorization: Bearer <key>`; the key, never the
request body, decides which tenant registers, publishes or reads, and a body that names a `tenant`
is refused. A publisher-chosen event id is 1 to 64 characters of `A-Z`, `a-z`, `0-9`, `_` and `-`;
without one the API generates an id and returns it.

The delivery id travels as `webhook-id` on every retry of a delivery and is the receiver's
idempotency key. The scripted receiver checks deliveries as a tenant's receiver should: it refuses
a bad signature or a `webhook-timestamp` more than five minutes (configurable) from its clock, and
answers an already processed `webhook-id` with 204 without running the endpoint again, so neither
a retry nor a captured copy of a delivery is processed twice.

## Run

From this directory, inside the Oversight shell:

```sh
../scripts/with-postgres.sh gleam test
../scripts/with-postgres.sh gleam run
```

Each tenant's key comes from `WEBHOOKS_API_KEY_ACME`, `WEBHOOKS_API_KEY_GLOBEX` or
`WEBHOOKS_API_KEY_OPS`; an unset variable gets a random key for the run, which is not printed.

`gleam run` starts the API and a scripted receiver on loopback, registers endpoints over HTTP
(including rejected SSRF attempts and a DNS-rebinding host), publishes two events, waits for
delivery and prints each outcome, the receiver's verdicts (including a replayed delivery) and one
delivery's telemetry trace.

The tests are in [`test/webhooks/`](test/webhooks/): core mapping, API authentication,
receiver verification, delivery and cassette replay.
The [composition contract](../../docs/design/design-layer.pdf) describes
signing, destination policy and outcome mapping.
