# secure_mcp

An MCP server for reports whose tools act for a signed-in user.

- A user signs in through the browser with OpenID Connect: Warden's
  relying-party flow (`/login`, `/auth/callback`) in a wisp app, against a
  scripted OpenID provider on loopback HTTPS. The login asks for the RFC 8707
  `resource` of the MCP endpoint, so the access token's audience is `/mcp`.
- `/me/token` hands the signed-in user that access token to paste into an
  MCP client.
- `POST /mcp` is a Relay server mounted in the same wisp/mist listener. Each
  request must carry `Authorization: Bearer`. The token is checked by Warden
  introspection and admitted by Relay's `authorization.admit` (audience and
  the `reports` scope). Failures answer `401`/`403` with an RFC 6750
  `WWW-Authenticate` challenge that points at the RFC 9728 metadata at
  `/.well-known/oauth-protected-resource/mcp`.
- `generate_report(title, period)` enqueues a Grind job owned by the
  authenticated subject and returns its job id. `report_status(job_id)`
  returns the state and the report. Another user's job id answers exactly like
  a missing one.

## Run

Inside the oversight dev shell, from this directory:

```sh
../scripts/with-postgres.sh gleam test   # 10 tests
../scripts/with-postgres.sh gleam run    # narrated session + telemetry
```

`gleam run` signs in alice, calls the tools, shows the failure paths (no
token, wrong audience, another user's job, revoked token) and prints every
Sinal event it collected.

## Layout

| Module                    | Role                                                                                                        |
| ------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `secure_mcp/app`          | Starts and stops provider, Warden, Grind, Relay server and the listener                                     |
| `secure_mcp/web`          | wisp routes: Warden login/callback, `/me/token`, RFC 9728 metadata, `/mcp`                                  |
| `secure_mcp/auth`         | Bearer extraction, Relay verifier backed by `warden.introspect`, challenges                                 |
| `secure_mcp/mcp_mount`    | Glue: Relay's custom-transport runtime driven from a wisp handler                                           |
| `secure_mcp/tools`        | `generate_report` / `report_status` (`relay/tool.handle_advanced`) over Grind                               |
| `secure_mcp/reports`      | Domain types with one Blueprint codec each; Grind codecs derive from them                                   |
| `secure_mcp/telemetry`    | Sinal subscriptions for relay, warden, grind and sinal, plus two bridge events keyed by `sinal/correlation` |
| `secure_mcp/client`       | Scripted browser and a raw JSON-RPC MCP client that can send a bearer token                                 |
| `secure_mcp/dev_provider` | Scripted OpenID provider (discovery, JWKS, authorize, token, introspection) on mist                         |

## Packages and seams exercised

- relay: tool definitions from Blueprint codecs, `handle_advanced` for the
  per-request principal, `runtime` as a custom transport inside wisp,
  `authorization.verifier`/`admit`/`protection_config`.
- warden: `config` with `TrustAnchorsPem` and `AllowLoopbackForTesting`,
  `begin_login` with an RFC 8707 extension parameter, `complete_login`,
  `restore_session`, `session_access_token`, `introspect`.
- grind: worker definition with an error codec, `submit`, `bind_handle`,
  `arguments` (owner check), `outcome`, a polling consumer and a manual one.
- json_blueprint: tool input/output contracts with the `use`-based record
  builder; the same codecs serve Grind through `codec.to_json` and
  `codec.decoder`.
- sinal: one collector attached to every package's descriptors; the app's own
  events carry a `sinal/correlation` id taken from a valid `x-request-id`
  header or generated.
- wisp, mist: one listener for browser routes and MCP; mist with TLS for the
  provider. pog: only through Grind, which owns the pool.

See [FEEDBACK.md](FEEDBACK.md) for what composed and what needed glue.
