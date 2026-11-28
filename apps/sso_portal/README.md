# sso_portal

[![CI](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

A web portal that signs users in with OpenID Connect, stores sessions in PostgreSQL and
calls a billing API with their access tokens. Hellhound refreshes tokens near expiry, and the
application retries a billing request once after a refusal. Hellhound's token custody lives in
PostgreSQL through the adapter in `src/sso_portal/hellhound_records.gleam`; a pending login
travels in a sealed browser cookie.

Everything external runs on loopback: `hellhound/testing` provides the OpenID provider over
TLS, `src/sso_portal/billing_api.gleam` validates bearer tokens locally, and
`src/sso_portal/browser.gleam` is an HTTP Gun browser with a cookie jar.

A browser session lasts one hour on the server as well as in the cookie: each row in
`portal_sessions` stores `expires_at`, and an expired row is refused and deleted. The
post-logout redirect is built from the portal's configured origin, the one its OpenID
`redirect_uri` uses, never from the request's `Host` header.

## Keys

The portal reads two keys from the environment when it starts, and refuses to start when
either is missing or invalid:

- `SSO_PORTAL_SEALING_KEY` seals Hellhound's records in PostgreSQL. It is 32 bytes, written
  as 64 hex digits or as base64, and not all zero (`openssl rand -hex 32`).
- `SSO_PORTAL_SECRET_KEY_BASE` signs the session cookie. It has at least 64 characters.

Every node that serves the portal needs the same two values, and a restart keeps them, so
sessions and stored tokens survive both. Changing a key is not a rotation. Records sealed
under the old sealing key no longer open: Hellhound reports them as unreadable and keeps
them for an operator, every signed-in person must sign in again, and the refresh tokens in
those records are neither used nor revoked at the provider. Cookies signed with the old
secret are refused, which signs everyone out. The tests set fixed test keys.

## Run

From this directory, inside the Oversight shell:

```sh
../scripts/with-postgres.sh gleam test
SSO_PORTAL_SEALING_KEY=$(openssl rand -hex 32) \
SSO_PORTAL_SECRET_KEY_BASE=$(openssl rand -hex 32) \
  ../scripts/with-postgres.sh gleam run
```

The [composition contract](../../docs/design/design-layer.pdf) describes
custody, refresh and listener ownership. [ADR 0018](../../docs/adr/0018-isolate-sso-listener-startup-and-shutdown.md)
records the listener decision.
