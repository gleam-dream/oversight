# sso_portal

A web portal that signs users in with OpenID Connect, stores sessions in
PostgreSQL and calls a billing API with their access tokens. Warden refreshes
tokens near expiry; the application retries a billing request once after a 401.

Packages: **warden**, **http_gun**, **sinal**, plus wisp, mist and pog.
The [ecosystem design](../../docs/design/design-layer.pdf) records the current composition contract.

## What it does

| Route            | Behaviour                                                                                                                       |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `GET /login`     | `warden.begin_login(request)`; `warden.login_response` sets the binding cookie and redirects to the provider's `/authorize`     |
| `GET /callback`  | `warden.complete_login(request)`; a row in `portal_sessions` maps a signed cookie to Warden's reference                         |
| `GET /dashboard` | restore the session, `warden.access_token` (refreshes near expiry), call `GET /invoices` over http_gun, `warden.refresh` on 401 |
| `POST /logout`   | `warden.logout` (custody removed, refresh token revoked), delete the row, redirect to the provider's end-session endpoint       |

Warden keeps its sessions and pending logins in Postgres
(`src/sso_portal/warden_records.gleam`, a `warden/store` adapter on pog), sealed
with a key the app holds, so a Warden restart keeps every session.
The adapter uses Warden's explicit write conditions and outcomes. Guarded writes
lock the row, check its version, then sample PostgreSQL's `clock_timestamp()`
before updating. Login validity is separate from record retention. A failed
commit acknowledgement remains an unknown outcome.

Everything external runs on loopback:

- `warden/testing`: the OpenID provider over TLS with its own test root
  (discovery, keys, PKCE token endpoint with rotating refresh tokens, revocation,
  end-session). The provider includes its test certificates.
- `src/sso_portal/billing_api.gleam`: plain-HTTP API that validates bearer
  tokens locally with `warden/resource`, plus a deny list the tests fill (local validation cannot see revocation).
- `src/sso_portal/browser.gleam`: an http_gun "browser" with a cookie jar that
  follows redirects between portal and provider.

## Run

From `apps/sso_portal`, inside the oversight dev shell:

```sh
../scripts/with-postgres.sh gleam test
../scripts/with-postgres.sh gleam run
```

## What the tests cover

| Integration                        | Where                                                       |
| ---------------------------------- | ----------------------------------------------------------- |
| Warden in an ordinary wisp app     | `src/sso_portal/web.gleam` (login, callback, logout)        |
| Durable custody (pog)              | `src/sso_portal/warden_records.gleam`, `app.gleam`          |
| Warden token → http_gun request    | `src/sso_portal/billing.gleam`, `web.gleam` invoices        |
| Refresh policy and refresh races   | `warden.access_token` and `warden.refresh`, `web.gleam`     |
| Separate HTTP client for billing   | `src/sso_portal/app.gleam` `start_billing_client`           |
| Following one request across Sinal | `warden.with_correlation`, `src/sso_portal/telemetry.gleam` |
| Test provider and TLS for Warden   | `warden/testing` (serves `/authorize`; `with_login`)        |
| Resource server                    | `src/sso_portal/billing_api.gleam` (`warden/resource`)      |

Tests (`test/sso_portal_test.gleam`): common path including RFC 7009
revocation at logout; proactive refresh near expiry; 401 →
refresh → retry with a cross-package trace; two concurrent requests racing one
refresh; provider clock ahead with and without
`config.with_clock_tolerance`; tampered callback state; revoked
refresh token → forced re-login; billing API down; sessions across a web-tier
restart and a Warden restart; Warden's rows hold nothing readable;
the Postgres store passes `testing.check_store` and refuses a guarded write
after an observed row-lock wait crosses expiry; a session ended elsewhere;
logout with a stale session revision.
