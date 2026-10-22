# sso_portal

A web portal that signs users in with OpenID Connect, stores sessions in PostgreSQL and
calls a billing API with their access tokens. Warden refreshes tokens near expiry, and the
application retries a billing request once after a refusal. Warden's sessions and pending
logins live in PostgreSQL through the adapter in `src/sso_portal/warden_records.gleam`.

Everything external runs on loopback: `warden/testing` provides the OpenID provider over
TLS, `src/sso_portal/billing_api.gleam` validates bearer tokens locally, and
`src/sso_portal/browser.gleam` is an HTTP Gun browser with a cookie jar.

## Run

From this directory, inside the Oversight shell:

```sh
../scripts/with-postgres.sh gleam test
../scripts/with-postgres.sh gleam run
```

The [composition contract](../../docs/design/design-layer.pdf) describes
custody, refresh and listener ownership. [ADR 0018](../../docs/adr/0018-isolate-sso-listener-startup-and-shutdown.md)
records the listener decision.
