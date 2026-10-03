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
[FEEDBACK.md](FEEDBACK.md) records what composed and what needed glue.

## Run

From this directory, inside the oversight dev shell:

```sh
../scripts/with-postgres.sh gleam test   # 12 tests
../scripts/with-postgres.sh gleam run    # narrative of one run
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

## Seams exercised

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

| Test                                                               | Covers                                                                                                                       |
| ------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| `core_test.status_and_failure_mapping_test`                        | status and http_gun failure-kind mapping, Retry-After parsing, the snooze cap, a failure after a 2xx head                    |
| `core_test.error_codec_round_trips_http_failures_test`             | an http_gun `Failure` with status survives the job error codec                                                               |
| `core_test.signature_round_trip_test`                              | HMAC signing and verification                                                                                                |
| `core_test.registration_rejects_unsafe_endpoints_test`             | metadata, private, loopback, IPv4-mapped, scheme, credential and `host:port` checks                                          |
| `core_test.delivery_attempted_event_round_trip_test`               | the app event through native telemetry; a stable correlation for an over-long id                                             |
| `core_test.every_outcome_is_listed_test`                           | `fields.check` for every `Outcome`                                                                                           |
| `delivery_test.common_path_signed_delivery_test`                   | API to job and delivery row in one transaction to signed live delivery; idempotent re-publish; ordered cross-package trace   |
| `delivery_test.receiver_down_retries_then_exhausts_test`           | connection refused, three attempts, `BudgetExhausted` with the typed http_gun failure                                        |
| `delivery_test.always_throttled_receiver_stops_test`               | a receiver that always answers 429: two snoozes, three attempts, `BudgetExhausted` with `RateLimited`                        |
| `delivery_test.ssrf_rejected_at_registration_and_at_delivery_test` | DNS-rebinding answer refused; loopback refused for a public tenant, allowed for the internal tenant; subscription disabled   |
| `cassette_test.cassette_drives_snooze_discard_and_body_limit_test` | 429 snoozes for Retry-After 120, 200 with oversized body (status kept on the failure), 410, offline from a serialized script |
| `cassette_test.snooze_with_error_codec_runs_again_test`            | 429 snoozes a worker with an error codec; the job stays bindable and delivers on the next claim                              |
| `cassette_test.oversized_429_keeps_retry_after_test`               | a 429 over the body limit keeps `Retry-After` (`error.headers`) and snoozes for it                                           |
| `cassette_test.request_without_tenant_view_is_refused_test`        | a request that skips the tenant view fails `ViewDestinationRequired`, `NotSent`                                              |
