# secure_mcp

An MCP server for reports whose tools act for a signed-in user.

- A user signs in through the browser with OpenID Connect: Warden's
  relying-party flow (`/login?as=<user>`, `/auth/callback`) in a wisp app,
  against `warden/testing`'s scripted provider on loopback HTTPS. The login
  asks for the RFC 8707 `resource` of the MCP endpoint, and the provider
  issues `at+jwt` access tokens whose audience is `/mcp`.
- `/me/token` hands the signed-in user that access token to paste into an
  MCP client.
- `POST /mcp` is Relay's protected endpoint (`relay/http.new_protected`),
  served by the same mist listener as the wisp routes. Each request must
  carry `Authorization: Bearer`. By default the token is validated locally
  by `warden/resource` (RFC 9068: signature, `typ`, issuer, audience,
  expiry); `app.Introspection` switches to `warden.introspect`. Relay admits
  the request (audience and the `reports` scope), answers `401`/`403` with an
  RFC 6750 challenge, and serves the RFC 9728 metadata at
  `/.well-known/oauth-protected-resource/mcp`.
- `generate_report(title, period)` enqueues a Grind job owned by the
  authenticated subject and returns its job id. `report_status(job_id)`
  returns the state and the report. Another user's job id answers exactly like
  a missing one.

## Run

Inside the oversight dev shell, from this directory:

```sh
../scripts/with-postgres.sh gleam test   # 13 tests
../scripts/with-postgres.sh gleam run    # narrated session + telemetry
```

`gleam run` signs in alice, calls the tools through Relay's client, shows the
failure paths (no token, another user's job, wrong audience, forged token,
a revoked token that local validation still accepts) and prints every Sinal
event it collected.

## Layout

| Module                 | Role                                                                                      |
| ---------------------- | ----------------------------------------------------------------------------------------- |
| `secure_mcp/app`       | Starts and stops provider, Warden clients, Grind, the Relay endpoint and the listener     |
| `secure_mcp/web`       | wisp routes: Warden login/callback and `/me/token`                                        |
| `secure_mcp/auth`      | Relay verifiers over `warden/resource` (local JWT) and `warden.introspect`                |
| `secure_mcp/tools`     | `generate_report` / `report_status` (`relay/tool.handle_call`) over Grind                 |
| `secure_mcp/reports`   | Domain types with one Blueprint codec each; Grind codecs derive from them                 |
| `secure_mcp/telemetry` | Sinal subscriptions for relay, warden, grind and sinal, joined by `sinal/correlation`     |
| `secure_mcp/client`    | Scripted browser, Relay's MCP client with a bearer header, provider-side token revocation |

## Packages and seams exercised

- relay: tool definitions from Blueprint codecs, `handle_call` for the
  per-request principal and correlation, `http.new_protected` mounted as
  `http.mist_handler` beside wisp, `authorization.verifier`, `challenge` and
  `resource_metadata` (through the endpoint), and `client.with_headers` with
  the typed `HttpStatus(401, www_authenticate)`.
- warden: `warden/testing` (provider, `config`, `trusting`, `authorize`,
  `issue_access_token` with forgeries), `begin_login` with an RFC 8707
  extension parameter, `complete_login`, `restore_session`, `access_token`,
  `warden/resource` and `introspect`.
- grind: worker definition with an error codec, `start`, `migrate`, `submit`
  with the request's correlation, `bind`, `arguments` (owner check),
  `outcome`, `await`.
- json_blueprint: tool input/output contracts with the `use`-based record
  builder; the same codecs serve Grind through `codec.to_json` and
  `codec.decoder`.
- sinal: one collector attached to every package's descriptors; Relay and
  Grind events carry the request's `sinal/correlation`, taken from a valid
  `x-request-id` header or generated.
- wisp, mist: one listener for browser routes and MCP. pog: only through
  Grind, which owns the pool.

See [FEEDBACK.md](FEEDBACK.md) for what composed and what needed glue.
