# warden — API card

Typed OIDC / OAuth 2.0 relying party on gose/kryptos, HTTPS through http_gun.
Scanned 2026-10-01 at `/code/gleam-dream/warden`.

## Health

- Git head: `55a493b feat: send HTTPS through HTTP Gun`.
- Gate: the repo's own fast gate, `nix develop --command scripts/check`
  (format check of `src test`, `gleam build --warnings-as-errors`,
  `WARDEN_SUITE=fast gleam test`, negative compile tests, consumer package).
  Result: **pass** — format ok, build ok, **127 passed, 0 failures** (26
  modules), **13/13 negative compile cases + positive control ok**, consumer
  `warden_reference` **8 passed**. Log noise: expected crash reports from the
  scripted test provider (e.g. `CaseClauseError ... {script, userinfo}, close`)
  and `:telemetry` local-handler info lines; neither fails the gate.
- Not run (need external services): `WARDEN_SUITE=keycloak|node|interop`
  (Keycloak 26.7.5, node-oidc-provider, Dex, Hydra containers),
  `scripts/browser-journey` (Chrome + Keycloak), `scripts/conformance` (OIDF
  RP suite). PROGRESS.md records them green on the final tree: 15, 7, 2 pass;
  browser 9/9; conformance 34 PASSED, 3 SKIPPED, 3 REVIEW, 1 suite defect.
- No `TODO`/`FIXME` in `src/`. Open items from `docs/PROGRESS.md` and
  `docs/decisions.md`:
  - D7 still listed as open (keep requiring advertised S256); conformance runs
    use the non-default `AssumeS256WhenUnadvertised`.
  - In-memory stores only (D4): no durable custody, no multi-node replay
    authority.
  - `http_gun` and `sinal` are path dependencies (D16); Warden cannot be
    published until both are.
  - No independent security review (internal W10 review only); not certified.
  - gose 2.2.0 rejects JWKs with X.509 members (Warden strips them); upstream
    issue drafted, not filed.

## Purpose and scope delivered vs design

Warden delivers the design's required baseline in one Erlang-target package:
discovery and a supervised JWKS/metadata cache, authorization-code login with
mandatory S256 PKCE, nonce, state and RFC 9207 `iss`, query and form-post
callbacks, all five client authentication methods, ID-token verification
(gose) with Warden-owned claim rules and typed identity, confirmed session
custody with absolute/idle lifetimes, custody-owned refresh with reservation,
quarantine and publication recovery, userinfo (subject-checked), client
credentials, introspection, and RP-initiated logout. Typed `sinal` HTTP
observations are emitted. Secrets, tokens and bindings are opaque and
closure-held; forging verified values is rejected by negative compile tests.

Still missing against `warden-design.md` §4.6 and §4.8:

- Durable-store port for transactions and custody (design wants an ETS/actor
  reference plus a durable port with atomic revision/status/expiry checks);
  only built-in in-memory actors exist.
- PAR, JAR, DPoP, JWT-bearer grant; dynamic registration; JARM/FAPI 2.0.
- Revocation, device grant, token exchange, back/front-channel logout.
- JWT-format userinfo responses; encrypted ID tokens (refused by policy).
- Local JWT access-token validation for a resource server (only RFC 7662
  introspection exists).
- Third-party-initiated login has a reference-RP route but no conformance
  verdict.

## Public modules

| Module               | Responsibility                                                                                                                                                                                                                                                                          |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `warden`             | Facade (46 pub fns): client lifecycle (`start`, `supervised`, `stop`), login (`begin_login`, `complete_login`, `recover_custody`), identity accessors and `decode_claims`, sessions, access tokens, refresh, userinfo, client credentials, introspection, logout, and every error type. |
| `warden/config`      | Pure `Settings` record, `new` + `with_*` helpers, opaque `Secret`/`SigningKey`, closed policy enums, `validate -> Result(Config, List(ConfigError))`. No I/O.                                                                                                                           |
| `warden/observation` | `sinal` event descriptor `http_request()` for `[warden, http, request]` with typed measurements and metadata.                                                                                                                                                                           |
| `warden/internal/*`  | Hidden (`internal_modules`): transport over http_gun, provider actor, transaction store, custody owner, callback parser, protocol decoding, redaction.                                                                                                                                  |

## Common path

```gleam
let assert Ok(cfg) =
  config.new(
    issuer: "https://login.example.com",
    client_id: "app",
    redirect_uri: "https://app.example.com/auth/callback",
    authentication: config.ClientSecretBasic(config.secret(client_secret)),
  )
  |> config.with_scopes(["email", "profile"])
  |> config.validate
let assert Ok(client) = warden.start(cfg)  // discovery + JWKS + processes

// GET /login: redirect, set cookie = warden.browser_binding_value(r.browser_binding)
let binding = option.from_result(warden.parse_browser_binding(cookie))
let assert Ok(r) = warden.begin_login(client, binding, warden.default_login())

// GET /auth/callback?...: raw query string and the binding cookie
case warden.complete_login(client, warden.QueryCallback(query), binding) {
  Ok(warden.LoginCompleted(session)) -> {
    let key = warden.identity_key(warden.session_identity(session))  // (iss, sub)
    store_cookie(warden.session_reference(session))
  }
  Ok(warden.LoginRecoveryRequired(rec)) -> warden.recover_custody(client, rec)
  Error(e) -> render_login_error(e)                       // warden.LoginError
}

// Later request: restore, use the token, refresh
let assert Ok(session) = warden.restore_session(client, reference)
let assert Ok(#(token, _expires_at)) = warden.session_access_token(client, session)
let header = warden.authorization_header(token)  // #("authorization", "Bearer ...")
case warden.refresh_session(client, session) {
  Ok(warden.RefreshCompleted(next)) -> next
  Ok(other) -> reauthenticate(other)  // DidNotSend, Rejected, Quarantined, ...
  Error(e) -> handle(e)               // warden.RefreshError
}
```

ID-token verification is not a separate call: `complete_login` verifies the
signature (gose), issuer, single audience, `azp`, nonce, `at_hash`, time
claims and transaction binding before a `Session` can exist.

## Configuration and advanced paths

- **Provider config**: `config.new(issuer:, client_id:, redirect_uri:,
authentication:)` (`config.gleam:272`) returns a public `Settings` record;
  defaults are `openid` only, RS256/PS256/ES256/EdDSA, query mode, 10-min
  pending logins, 100 000 pending cap, 15 s startup, 5 s store calls, 12 h/1 h
  sessions, 5 s clock tolerance. `with_*` helpers exist for scopes, response
  mode, signing algorithms, transport, trust, destinations, login lifetime,
  PKCE policy, `iss` policy, session lifetime and clock tolerance; other
  fields (`allowed_hosts`, timeouts, `max_pending_logins`) use record update.
  `validate` returns every problem at once.
- **Client auth**: closed `ClientAuthentication` — `PublicClient`,
  `ClientSecretBasic`, `ClientSecretPost`, `ClientSecretJwt` (secret ≥ 32
  bytes), `PrivateKeyJwt(SigningKey)` from `signing_key_from_jwk` (RSA ≥ 2048,
  EC P-256/384/521, Ed25519). Exactly that method is used; no fallback.
- **PKCE**: always S256. `PkceAdvertisementPolicy` decides acceptance only:
  `RequireAdvertisedS256` (default) or `AssumeS256WhenUnadvertised`
  (confidential clients only; validation refuses it for `PublicClient`).
- **Transport**: `Transport(trust, destinations, allowed_hosts,
request_timeout_ms, max_response_bytes)`; `SystemTrust` or
  `TrustAnchorsPem`; `PublicInternetOnly`, `AllowPrivateNetwork`,
  `AllowLoopbackForTesting`. Mapped to an internal http_gun destination
  policy.
- **Storage/custody**: **not pluggable.** The transaction store and custody
  owner are internal OTP actors (`warden/internal/transaction_store`,
  `custody_store`) started under Warden's supervisor; `Client` holds them
  opaquely. No public port, behaviour or record of functions exists, so a
  custom store has nothing to implement and a Postgres store via `pog` would
  require changing Warden. The application owns only the browser-binding
  cookie and the session-reference cookie.
- **Clock tolerance**: `with_clock_tolerance(settings, seconds)` for
  `iat`/`nbf`/`auth_time` (≤ 300 s; none for `exp`). Wall clock for tokens,
  monotonic clock for login and session lifetimes; clock injection
  (`start_with_clock(s)`) is `@internal`.
- **Per-login options**: `LoginOptions` record (`scopes`, `prompt`,
  `max_age`, `login_hint`, `acr_values`, `ui_locales`, `extra_parameters`
  with reserved names rejected); `default_login()` plus record update.
- **Claims**: `decode_claims(identity, decoder)` and
  `decode_userinfo(info, decoder)` decode into caller-owned types.

## Lifecycle and supervision

- `warden.start(config)` performs one discovery + JWKS load (one-shot http_gun
  client, bounded by `startup_timeout_ms`), checks compatibility, then starts a
  one-for-one static supervisor (linked to the caller) with four children: a
  shared http_gun client, the provider cache actor (metadata/JWKS refresh,
  throttled unknown-`kid` refetch), the transaction store and the custody
  owner. Children are found by names allocated once per `start`.
- `warden.supervised(config) -> ChildSpecification(Client)`
  (`warden.gleam:173`) wraps `start` as a supervisor child.
- `warden.stop(client)` unlinks, kills the supervisor and erases the pool's
  `persistent_term` key. Cleanup is caller-owned; sessions and pending logins
  die with the supervisor.

## Failure model

- Startup: `StartError` (`DiscoveryFailed(ProviderFailure)`,
  `ProviderIncompatible(List(Incompatibility))`, `StartupTimedOut`,
  `ProcessStartFailed`); config: `List(ConfigError)`.
- Shared provider detail: `ProviderFailure` (`ProviderNotReady`,
  `TransportFailure(sent: Bool, reason: TransportReason)`,
  `ProviderStatus(status, OAuthError)`, `MalformedProviderResponse`,
  `IssuerMismatch`, `UnclassifiedBackendFailure`). `sent: False` proves
  non-transmission, which drives retry safety.
- Login: `BeginLoginError`; `LoginError` separates malformed callback,
  binding rejection, expiry, replay, changed, store unavailable, provider
  denial (`Denial`), pre-exchange unavailability, definite rejection
  (`OAuthError`), unknown exchange outcome, and `IdentityRejected
(IdentityProblem)` with ~20 named token problems. An unknown custody
  install is a success variant, `LoginRecoveryRequired`.
- Sessions: `SessionError`; refresh: `RefreshResult` (outcomes, including
  not-sent, rejected, quarantined, unresolved) plus `RefreshError`
  (preconditions); per-operation `UserinfoError`, `ClientCredentialsError`
  (with `OutcomeUnknown`), `IntrospectionError`, `LogoutError`,
  `CustodyRecoveryError`. All closed enums; no diagnostic strings to parse
  except `InvalidScope(String)`-style offending values.

## Composition seams

- **Web frameworks (wisp/mist)**: framework-neutral but **not** gleam_http
  typed. Inputs are raw strings (`QueryCallback(query)`,
  `FormPostCallback(body)`, binding cookie value, session reference); outputs
  are a URL string, a cookie value and `#(String, String)` header. The
  reference RP (`consumer/src/warden_reference/web.gleam:42-69`) mounts
  `GET /login`, `GET|POST /auth/callback`, refresh, userinfo and logout in a
  wisp router on mist; cookies, CSRF checks and session signing stay in the
  app (`docs/APPLICATION-RESPONSIBILITIES.md`). Any framework that exposes
  the query string, body and cookies can mount it with a few lines.
- **http_gun**: hard dependency, internal. Each Warden client owns its own
  supervised http_gun client (`internal/transport.gleam:158-180`, found via
  `persistent_term`); callers cannot pass one in. Sharing with llm_wire is not
  possible and is not desirable: Warden's client carries OIDC-specific trust
  anchors and destination policy. `TransportReason` is Warden's own closed
  mapping of http_gun failures (D17 coarsened four classes).
- **sinal**: hard dependency. One event, `[warden, http, request]`
  (`observation.http_request()`), with `duration_ms` and
  `method/host/path/outcome`; no tokens, queries or bodies. No login,
  refresh, cache or store events.
- **relay (resource server)**: Warden is RP-first. The only RS-relevant
  operation is `introspect(client, token: String)` (RFC 7662), returning
  `TokenInfo` with no `aud` field (audiences must be dug out of
  `claims: Dynamic`). There is no local JWT access-token (RFC 9068)
  verification and no JWKS-only verifier. A relay `Verifier` closure could
  call `introspect`, but (a) relay's `BearerToken` is opaque with no public
  reveal (`relay/src/relay/authorization.gleam:8-33`), so the closure cannot
  read the token, and (b) a Warden client needs a full RP configuration and
  an authorization-code-capable provider to start (see concern 1). The design
  assigns MCP grants to relay and keeps introspection in Warden (§2, §4.8).
- **grind/saga/fabric**: no coupling. `client_credentials` returns a token to
  the caller (not stored), so a job or agent can use it without custody.

## Ergonomics concerns

1. **RP-only requirements gate non-login roles.** `config.new` requires
   `redirect_uri` (`config.gleam:272-277`) and `start` refuses a provider
   lacking the authorization-code grant, the configured response mode or S256
   (`warden.gleam:232-235`, checks at `:353-367`). A service that only needs
   `client_credentials` (`:1871`) or `introspect` (`:1940`) must invent a
   redirect URI and still fails against an AS that only issues machine
   tokens. Required arguments that do not change behavior for that caller
   (guideline "Ask for decisions; derive owned facts").
2. **`supervised` is not usable under a static supervisor and loses the
   error.** `warden.supervised` returns `ChildSpecification(Client)`
   (`warden.gleam:173-180`), but `gleam/otp/static_supervisor.add` maps child
   data to `Nil`, so the `Client` is unreachable; a restart of that child
   calls `start` again, which allocates fresh process names and a fresh pool
   key (`:236`, `:242`, `:277-278`), so any handle captured earlier goes
   stale. `StartError` is flattened to `InitFailed("warden failed to
start")` (`:177`). The reference RP avoids it and uses `warden.start`
   (`consumer/src/warden_reference.gleam:97`). Naming also diverges:
   warden/sinal/grind use `supervised`, http_gun/fabric use `child`.
3. **No storage port.** Stores are internal actors
   (`warden.gleam:286-306`); there is no public seam for a durable or shared
   store, so multi-node replay prevention and restart-surviving sessions
   (design §4.6 "durable-store port") cannot be added by an application, e.g.
   via `pog`. This is the largest gap for production deployments.
4. **Leaking `Dynamic` and stringly classes.** `TokenInfo.claims: Dynamic`
   is a public record field (`warden.gleam:1931`), unlike the
   `decode_claims`/`decode_userinfo` decoder pattern used elsewhere
   (`:1194`, `:1799`). `observation.Failed(sent: Bool, class: String)`
   (`observation.gleam:41`) is stringly while the facade has a closed
   `TransportReason` (`warden.gleam:126-143`) for the same fact.
5. **Refresh failures split across both channels.** `refresh_session`
   returns `Result(RefreshResult, RefreshError)` where six of seven
   `RefreshResult` variants are non-success (`warden.gleam:1438-1457`); a
   `use <- result.try` caller treats `RefreshDidNotSend` or a quarantine as
   success. `RefreshReservationRecovery` is carried by three variants but no
   public operation consumes it (only `reservation_recovery_reference`,
   `:1502`).
6. **Unmarked helper leakage in `warden/config`.** `valid_scope`
   (`config.gleam:542`), `valid_redirect_uri` (`:584`), `algorithm_name`
   (`:642`) and `TrustAnchors` (`:407`) are public without `@internal`, while
   neighbouring accessors are `@internal`; `session_lifetime` (`:872`) returns
   an unnamed `#(Int, Int)`. Minor: `LogoutOptions` has no default
   constructor, unlike `default_login()`; the consumer writes its own
   (`consumer/src/warden_reference/web.gleam:392`).
