# secure_mcp

[![CI](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

An MCP server for reports whose tools act for a signed-in user. A user signs in through
the browser with OpenID Connect against Hellhound's scripted provider on loopback HTTPS,
and `/me/token` hands them the access token to paste into an MCP client. `POST /mcp` is
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
