# webhooks

A multi-tenant outbound webhook service. Tenants register endpoint URLs
(`POST /subscriptions`). An application event (`POST /events`) fans out to
one grind job per active subscription. A worker signs each delivery
(HMAC-SHA256 over `id.timestamp.body`, Standard-Webhooks style), sends it
through http_gun, and maps the result back to grind: 2xx succeeds, 5xx,
408 and transport failures retry with exponential backoff, 410 discards and
disables the subscription, 429 snoozes for `Retry-After` (at most
`max_snoozes` times, read from the job's context, then it uses an attempt),
and a destination refused by the SSRF policy discards and disables. The `webhook-id` header is
the delivery id (`event:subscription`), so it stays the same across retries
and serves as the receiver's idempotency key.

Packages: `grind`, `http_gun`, `sinal`, plus `wisp`, `mist` and `pog`.
The [ecosystem design](../../docs/design/design-layer.pdf) records the current composition contract.

## Run

From this directory, inside the oversight dev shell:

```sh
../scripts/with-postgres.sh gleam test
../scripts/with-postgres.sh gleam run
```

`gleam run` starts the API and a scripted receiver on loopback and registers
endpoints over HTTP, including SSRF attempts rejected at registration (a
metadata address, a loopback address for a public tenant, a loopback port
outside the internal tier's `host:port` allowlist) and one DNS-rebinding
host. It then publishes two events, lets grind's consumers deliver them,
waits with `grind.await`, and prints each outcome, the receiver's signature
checks, and one delivery's telemetry trace across packages.

## Layout

| Module                  | Role                                                                                       |
| ----------------------- | ------------------------------------------------------------------------------------------ |
| `webhooks/subscription` | tenants, tiers, each tier's destination policy, registration-time `destination.check`      |
| `webhooks/egress`       | one http_gun client; each delivery narrows it to its tier with `with_destination`          |
| `webhooks/attempt`      | job values and codecs; http_gun result to disposition to grind `Response`                  |
| `webhooks/delivery`     | the grind `responding` worker: load subscription, sign, send, classify, record             |
| `webhooks/web`          | wisp API; fan-out with `grind.submit_in`, the delivery row in the same transaction         |
| `webhooks/store`        | app tables in `public`, on grind's pool                                                    |
| `webhooks/telemetry`    | attaches to every grind, http_gun, sinal and app event; keys them by the job's correlation |
| `webhooks/receiver`     | scripted loopback receiver (mist)                                                          |
| `webhooks/service`      | wiring: one pool, one egress client, the grind runtime and its worker                      |

## What the example exercises

- http_gun failure kinds and statuses mapped to grind retry, snooze, discard and
  fail outcomes (`attempt.classify`, `attempt.retry_policy`); the http_gun
  `Failure` is stored whole in the job error through `error.to_json`.
- Destination policy per tenant tier on one client: public tenants reach public
  addresses only and every DNS answer is checked; the internal tenant reaches
  allowlisted loopback `host` or `host:port` entries. Registration applies the
  same policy value with `destination.check`.
- Cassettes inside worker tests: the service's egress client is a
  `testing.playback` client that ignores the signature headers, and the
  registered worker runs the attempts through `grind/testing.drain`
  (`test/webhooks/cassette_test.gleam`).
- A response body over the read limit: the failure keeps the 200, so the
  delivery succeeds once.
- Telemetry from grind, http_gun, sinal and the app, joined by the job's
  correlation (`correlation.from_key(delivery_id)`) and ordered by the
  emitters' monotonic clock.

## Tests

[Unit tests](test/webhooks/core_test.gleam) cover status and failure mapping,
Retry-After and snooze bounds, signatures, codec roundtrips, destination policy
and telemetry fields.

[Delivery tests](test/webhooks/delivery_test.gleam) exercise transactional
admission, stable delivery identities, receiver outages, repeated throttling,
DNS rebinding and tenant-specific destination rules.

[Cassette tests](test/webhooks/cassette_test.gleam) replay 429 and 410 responses,
body-limit failures and retries without a receiver. They also check that a
request which skips the tenant's client view is refused before sending.
