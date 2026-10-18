# secure_mcp

An MCP server for reports whose tools act for a signed-in user. A user signs in through
the browser with OpenID Connect against Warden's scripted provider on loopback HTTPS,
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

The [composition contract](../../docs/design/applications/design.typ#protected-mcp-service)
describes token validation, permission and report ownership.
