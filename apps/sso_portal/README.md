# sso_portal

A small web portal that signs users in with OpenID Connect, keeps a
server-side session in Postgres, and calls a token-protected downstream
"billing API" with the user's access token, refreshing it transparently.

Packages: **warden**, **http_gun**, **sinal**, plus wisp, mist and pog.
Findings are in [FEEDBACK.md](FEEDBACK.md).

## What it does

| Route            | Behaviour                                                                                                                |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `GET /login`     | `warden.begin_login`; the browser binding goes in a cookie; redirect to the provider                                     |
| `GET /callback`  | `warden.complete_login` from the raw query string; a row in `portal_sessions` maps a signed cookie to Warden's reference |
| `GET /dashboard` | restore the session, get a usable access token (refresh near expiry), call `GET /invoices` over http_gun, refresh on 401 |
| `POST /logout`   | `warden.logout` (custody removed), delete the row, redirect to the provider's end-session endpoint                       |

Everything external is scripted on loopback:

- `src/sso_portal/fake_idp.gleam`: a minimal OpenID provider over TLS
  (discovery, JWKS, auto-approving `/authorize`, `/token` with S256 PKCE and
  rotating refresh tokens, `/userinfo`, `/logout`), ES256 ID tokens signed with
  gose. Knobs: access-token lifetime, `iat` skew, refresh delay, revocation.
- `src/sso_portal_pki_ffi.erl`: a disposable root and `localhost` leaf from
  OTP's `public_key:pkix_test_data/1`.
- `src/sso_portal/billing_api.gleam`: plain-HTTP API that accepts only live
  tokens from the provider.
- `src/sso_portal/browser.gleam`: an http_gun "browser" with a cookie jar that
  follows redirects between portal and provider.

## Run

From `apps/sso_portal`, inside the oversight dev shell:

```sh
../scripts/with-postgres.sh gleam test   # 10 tests
../scripts/with-postgres.sh gleam run    # narrative: login, 401 + refresh, billing down, logout
```

## Seams exercised

| Seam                               | Where                                                     |
| ---------------------------------- | --------------------------------------------------------- |
| Warden in an ordinary wisp app     | `src/sso_portal/web.gleam` (login, callback, logout)      |
| Durable session custody (pog)      | `src/sso_portal/session_store.gleam`, `web.gleam` current |
| Warden token → http_gun request    | `src/sso_portal/billing.gleam`, `web.gleam` invoices      |
| Refresh policy and refresh races   | `src/sso_portal/access.gleam`                             |
| Sharing (not) an http_gun client   | `src/sso_portal/app.gleam` `start_billing_client`         |
| Following one request across Sinal | `src/sso_portal/telemetry.gleam`                          |
| Test provider and TLS for Warden   | `fake_idp.gleam`, `pki.gleam`, `sso_portal_pki_ffi.erl`   |

Tests (`test/sso_portal_test.gleam`): common path; proactive refresh near
expiry (advanced policy); 401 → refresh → retry with a cross-package trace;
two concurrent requests racing one refresh (advanced); provider clock ahead
with and without `with_clock_tolerance` (advanced); tampered callback state;
revoked refresh token → forced re-login; billing API down; sessions across a
web-tier restart and a Warden restart (advanced, durability); logout with a
stale session revision.
