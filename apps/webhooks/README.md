# webhooks

A multi-tenant outbound webhook service. Tenants register endpoint URLs
(`POST /subscriptions`). An application event (`POST /events`) fans out to
one grind job per active subscription. A worker signs each delivery
(HMAC-SHA256 over `id.timestamp.body`, Standard-Webhooks style), sends it
through http_gun, and maps the result back to grind: 2xx succeeds, 5xx,
408 and transport failures retry with exponential backoff, 410 discards and
disables the subscription, 429 snoozes for `Retry-After`, and a destination
refused by the SSRF policy discards and disables. The `webhook-id` header is
the delivery id (`event:subscription`), so it stays the same across retries
and serves as the receiver's idempotency key.

Packages: `grind`, `http_gun`, `sinal`, plus `wisp`, `mist` and `pog`.
[FEEDBACK.md](FEEDBACK.md) records what composed and what needed glue.

## Run

From this directory, inside the oversight dev shell:

```sh
../scripts/with-postgres.sh gleam test   # 8 tests
../scripts/with-postgres.sh gleam run    # narrative of one run
```

`gleam run` starts the API and a scripted receiver on loopback and registers
endpoints over HTTP, including one SSRF attempt rejected at registration
and one DNS-rebinding host. It then publishes two events, lets an
automatically polling consumer deliver them, and prints each outcome, the
receiver's signature checks, and one delivery's telemetry trace across
packages.

## Layout

| Module                  | Role                                                                            |
| ----------------------- | ------------------------------------------------------------------------------- |
| `webhooks/subscription` | tenants, tiers, registration-time endpoint checks                               |
| `webhooks/egress`       | one http_gun client per destination-policy tier (public, internal)              |
| `webhooks/attempt`      | job values and codecs; http_gun result to disposition to grind `WorkerResponse` |
| `webhooks/delivery`     | the grind worker: load subscription, sign, send, classify, record               |
| `webhooks/web`          | wisp API; fan-out with `postgres.submit_with_id` and deterministic ids          |
| `webhooks/store`        | app tables on the app's own pog pool                                            |
| `webhooks/telemetry`    | attaches to every grind, http_gun, sinal and app event; joins them per delivery |
| `webhooks/receiver`     | scripted loopback receiver (mist)                                               |
| `webhooks/service`      | wiring: pools, forwarder, clients, worker, consumer                             |

## Seams exercised

- http_gun failure classes and statuses mapped to grind retry, snooze, discard and
  fail outcomes (`attempt.classify`, `attempt.retry_policy`).
- Destination policy per tenant tier: public tenants reach public addresses only
  and every DNS answer is checked; the internal tenant reaches allowlisted loopback hosts.
- Cassettes inside worker tests: the worker's deps hold a `cassette.playback`
  client, and a real manual-mode grind consumer runs the attempts
  (`test/webhooks/cassette_test.gleam`).
- A response body over the collect limit, with the status kept (http_gun `Truncate` collect policy).
- Telemetry from grind, http_gun, sinal and the app, joined by delivery id.

## Tests

| Test                                                               | Covers                                                                                                                         |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------ |
| `core_test.status_and_failure_mapping_test`                        | status and http_gun failure-class mapping, Retry-After parsing                                                                 |
| `core_test.signature_round_trip_test`                              | HMAC signing and verification                                                                                                  |
| `core_test.registration_rejects_unsafe_endpoints_test`             | metadata, private, loopback, IPv4-mapped, scheme and credential checks                                                         |
| `delivery_test.common_path_signed_delivery_test`                   | API to job to signed live delivery; idempotent re-publish; cross-package trace                                                 |
| `delivery_test.receiver_down_retries_then_exhausts_test`           | connection refused, three attempts, `BudgetExhausted` with a typed error                                                       |
| `delivery_test.ssrf_rejected_at_registration_and_at_delivery_test` | DNS-rebinding answer refused; loopback refused for a public tenant, allowed for the internal tenant; subscription disabled     |
| `cassette_test.cassette_drives_snooze_discard_and_body_limit_test` | 429 snoozes for Retry-After 120, 200 with oversized body (truncated, status kept), 410, all offline from a serialized cassette |
| `cassette_test.snooze_with_error_codec_runs_again_test`            | 429 snoozes a worker with an error codec; the job stays bindable and delivers on the next claim                                |
