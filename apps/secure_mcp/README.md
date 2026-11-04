# secure_mcp

[![CI](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

An MCP server for reports whose tools act for a signed-in user. A user signs in through
the browser with OpenID Connect against Hellhound's scripted provider on loopback HTTPS,
and `POST /me/token` hands them the access token to paste into an MCP client. `POST /mcp` is
Relay's protected endpoint, served by the same listener as the Wisp routes, and
`generate_report` and `report_status` run as Grind jobs owned by the authenticated subject.

## Run

From this directory, inside the Oversight shell:

```sh
../scripts/with-postgres.sh gleam test
../scripts/with-postgres.sh gleam run
```

`gleam run` signs in a user, calls the tools through Relay's client, shows the failure
paths (no token, another user's job, wrong audience, forged token, a revoked token that
local validation still accepts) and prints every Sinal event it collected.

The [composition contract](../../docs/design/design-layer.pdf)
describes token validation, permission and report ownership.

## Token hand-off and client secret

`/me` shows a button that POSTs to `/me/token`; `GET /me/token` answers 405. A bearer
token in a GET response lands where URLs and their responses go: browser history, proxy
and access logs, prefetches. The POST needs the signed `SameSite=Lax` session cookie, so a
cross-site form POST arrives without it and is refused, and the answer is
`Cache-Control: no-store`.

The scripted browser in `src/secure_mcp/client.gleam` verifies TLS against the scripted
provider's root certificate only.

| Variable                   | Value                                                                     |
| -------------------------- | ------------------------------------------------------------------------- |
| `SECURE_MCP_CLIENT_SECRET` | The OAuth client secret registered with the scripted provider (optional). |

When it is unset, the app generates 32 random bytes at boot, registers them with the
provider it starts and says so on standard error. No secret appears in source.
