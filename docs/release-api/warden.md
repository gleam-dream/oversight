# warden — release API review

Reviewed 2 October 2026 against `/code/gleam-dream/warden` at `845b75e`, the
[warden design](../../warden-design.md), `docs/decisions.md` (D1–D18), the
[API card](../composition/scan/warden.md), the
[cross-package review](../composition/FEEDBACK.md) and the sso_portal and
secure_mcp findings. A scratch consumer compiled today's common path against
`845b75e` ("probe"). Line numbers refer to `src/warden.gleam` unless a file is
named.

## 1. Verdict

Warden is not release-ready as an API, although its security core is: login,
verification and the refresh reservation behaved correctly in both apps, and
its security defaults fail closed. The blocker is session custody, an
in-memory actor with no store port, so a restart signs every user out and no
deployment can run on two nodes (SSO-1). Next come a refresh surface with six
failures inside `Ok`, losers that must poll and a recovery type nothing
consumes; a `supervised` handle that a restart invalidates; no
`warden/testing` (the apps wrote 459 and 644 lines of fake providers); and an
introspection result unfit for authorization (`claims: Dynamic`, no
audience, no `exp` check).

## 2. First ten minutes

The main job: sign a user in, then call an API with the user's token,
refreshing it near expiry. Today's version is abridged from a 105-line probe
that compiles; it is still wrong under concurrency, because a request that
loses a refresh race gets `Error(RefreshInProgress)` and must poll
(sso_portal's `access.gleam` spends 160 lines on this).

```gleam
// TODAY (abridged probe)                      imports: warden, warden/config, option, timestamp
let assert Ok(validated) = config.new(issuer:, client_id:, redirect_uri:,
    authentication: config.ClientSecretBasic(config.secret(secret)))
  |> config.with_scopes(["email", "profile"]) |> config.validate  // List(ConfigError)
let assert Ok(client) = warden.start(validated)                   // StartError
// GET /login: parse the cookie, begin, hand the binding back; the app sets 6 cookie attributes
let binding = option.then(cookie, fn(v) { option.from_result(warden.parse_browser_binding(v)) })
use r <- result.map(warden.begin_login(client, binding, warden.default_login()))
#(r.url, warden.browser_binding_value(r.browser_binding))
// GET /auth/callback
case warden.complete_login(client, warden.QueryCallback(query), binding) {
  Ok(warden.LoginCompleted(s)) -> Ok(warden.session_reference(s))
  Ok(warden.LoginRecoveryRequired(rec)) -> recover(client, rec)  // a failure inside Ok
  Error(_) -> Error(Nil)
}
// Later request: SessionStale means restore and retry
use session <- result.try(warden.restore_session(client, reference))
case warden.session_access_token(client, session) {
  Ok(#(token, Some(exp))) if exp - now() > 30 -> Ok(warden.authorization_header(token))
  Ok(#(token, None)) -> Ok(warden.authorization_header(token))
  Ok(_) -> case warden.refresh_session(client, session) {
    Ok(warden.RefreshCompleted(next)) -> ...session_access_token(next)...
    _ -> Error(Nil)  // 6 more outcomes, 10 errors; RefreshInProgress: poll
  }
  Error(_) -> Error(Nil)
}
```

```gleam
// PROPOSED (sketch)                            imports: warden, warden/config (+ gleam_http types)
use client <- result.try(config.new(issuer:, client_id:, redirect_uri:,
    authentication: config.ClientSecretBasic(config.secret(secret)))
  |> config.with_scopes(["email", "profile"]) |> warden.new)  // validates; names allocated once
use Nil <- result.try(warden.start(client))                       // same StartError
// GET /login
use redirect <- result.map(warden.begin_login(client, request, warden.default_login()))
warden.login_response(response, redirect)       // 303, Location, __Host- cookie, no-store
// GET or POST /auth/callback
use session <- result.map(warden.complete_login(client, request))  // Result(Session, LoginError)
warden.session_reference(session)
// Later request
use session <- result.try(warden.restore_session(client, reference))
use access <- result.map(warden.access_token(client, session))  // margin, join, restore
warden.authorize(api_request, access.token)
// On error: warden.session_error_action(e) -> Reauthenticate | RetryLater | FixConfiguration
```

| Measure (common path)                  | Today                             | Proposed |
| -------------------------------------- | --------------------------------- | -------- |
| Warden imports                         | 2                                 | 2        |
| Distinct Warden functions              | 16                                | 13       |
| Warden types touched (non-error/error) | 16 / 7                            | 9 / 4    |
| Lines (probe / sketch)                 | 105, incomplete under concurrency | about 40 |
| Variants to handle for a token         | 7 `RefreshResult` + 10 errors     | 1 action |
| Cookie attributes the app writes       | 6                                 | 0        |

## 3. Target surface

| Module              | Status        | Key types and functions                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ------------------- | ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `warden`            | keep          | `Client`; `new`, `start`, `supervised`, `stop`, `with_correlation`; `begin_login`, `default_login`, `login_response`, `complete_login`, `recover_custody`; identity accessors and `decode_claims`; `Session`, `restore_session`, `access_token`, `refresh`, `recover_refresh`, `Access`, `authorize`; `userinfo`; `client_credentials`; `introspect`, `decode_token_claims`; `logout`, `default_logout`; one error type per boundary with `describe_*` and `*_action` |
| `warden/config`     | keep, opaque  | opaque `Config`; `new`, `service_client`, `with_*` for every option (flat, no nested `Transport`), `with_custody_store`, `with_transaction_store`, `with_sealing_key`; `describe_config_error`                                                                                                                                                                                                                                                                        |
| `warden/store`      | new           | `Record(key, version, expires_at, sealed)`, `StoreError`; `custody_store(get:, put:, delete_expired:)`, `transaction_store(...)`                                                                                                                                                                                                                                                                                                                                      |
| `warden/telemetry`  | rename        | was `warden/observation`; `http_request()` with a closed reason and `correlation`; new `login()`, `refresh()`, `logout()` descriptors                                                                                                                                                                                                                                                                                                                                 |
| `warden/testing`    | new           | `start_provider`, `config`, `authorize`, `issue_access_token`, `revoke_refresh_tokens`, `set_clock_skew`, `requests`, `stop`, `check_custody_store`                                                                                                                                                                                                                                                                                                                   |
| `warden/internal/*` | keep internal | add `BrowserBinding`, `Callback`, `TrustAnchors` and the four config helpers                                                                                                                                                                                                                                                                                                                                                                                          |

| Count                 | Before       | After                                      |
| --------------------- | ------------ | ------------------------------------------ |
| Public modules        | 3            | 5 (4 if testing ships as `warden_testing`) |
| Public functions      | 61 (38/22/1) | 91 (49/27/2/4/9)                           |
| Common-path functions | 16           | 13                                         |
| Public records        | 10           | 15                                         |
| Public unions         | 39           | 40                                         |
| Opaque types          | 12           | 13                                         |

The total grows because three capabilities the apps built themselves are
added (store port, test provider, revocation) and each error type gains a
`describe_*`. Removed or made internal: `Settings`, `Transport` and
`default_transport`/`with_transport`/`validate`; the config helpers and
accessors; `Callback`, `BrowserBinding` and its two functions;
`session_revision`, `session_access_token`; `RefreshResult`, `RefreshError`,
`RefreshReservationRecovery`, `LoginCompletion` and the two
`CustodyRecovery*` types.

## 4. Proposals

### WARDEN-R1 A custody and transaction store port (blocker)

- **Problem.** Custody and pending logins are private actors started inside
  `start` (`:277-308`) and held in the opaque `Client` (`:56-71`). A restart
  signs everyone out, `SessionNotFound` cannot tell a restart from a logout
  (`:1330-1332`), and two nodes cannot share sessions or replay authority
  (SSO-1, card concern 3, FEEDBACK theme 2, design §4.6). sso_portal wrote
  164 lines of Postgres glue that still is not durable.
- **Change.** Not the six refresh-protocol operations of
  `internal/custody_store.gleam:678-744`, but three functions over sealed
  records. Warden keeps the state machine (reservation, settlement,
  publication, command history, tombstones); the store provides only atomic
  compare-and-set on one table, about 40 lines in pog.

```gleam
// warden/store
pub type Record { Record(key: String, version: Int, expires_at: Int, sealed: BitArray) }
pub type StoreError { StoreUnavailable StoreOutcomeUnknown }
pub fn custody_store(
  get get: fn(String) -> Result(Option(Record), StoreError),
  put put: fn(Record, Option(Int)) -> Result(Bool, StoreError), // None: insert if absent; False: conflict
  delete_expired delete_expired: fn(Int) -> Result(Int, StoreError),
) -> CustodyStore
pub fn transaction_store(get:, put:, delete_expired:) -> TransactionStore
// warden/config
pub fn with_custody_store(config, store: CustodyStore) -> Config
pub fn with_transaction_store(config, store: TransactionStore) -> Config
pub fn with_sealing_key(config, key: Secret) -> Config  // required by either store
```

- **Security (must hold).** Records are AEAD-sealed (`kryptos/aead`), so a
  database leak exposes no refresh token or PKCE verifier and a database
  write cannot forge a `VerifiedIdentity`. Today a process monitor detects
  a dead refresher and quarantines it
  (`internal/custody_store.gleam:168`, `:701`); a durable
  store needs a lease, and **lease expiry must quarantine, never release**,
  or a possibly rotated refresh token is resent. Logout writes a tombstone
  kept for the install-history horizon, so a late `recover_custody` gets
  `RecoveryEnded` rather than resurrecting the session. Lifetimes become
  wall-clock `expires_at` (open question 2).
- **Also.** The in-memory owner stays the default; a custody-epoch prefix in
  references lets it answer `SessionLost` instead of `SessionNotFound`.
  `warden/testing.check_custody_store` is the adapter conformance suite.
- **Breaks callers:** no. **Effort:** L.

### WARDEN-R2 One access operation; failures out of `Ok`

- **Problem.** `refresh_session` returns `Result(RefreshResult, RefreshError)`
  with six failures inside `Ok` (`:1438-1457`, `:1472-1490`), so a caller
  using `result.try` treats a quarantine as success (card concern 5).
  sso_portal maps 17 variants onto three decisions in 40 lines, where
  `InvalidGrant` means re-login and `InvalidRequest` retry (SSO-5). A loser gets
  `RefreshInProgress` (`:1549`) and polls every 20 ms (SSO-3); a stale
  revision needs restore and retry (`:1379-1382`); the expiry margin is app
  glue. `RefreshReservationRecovery` (`:1494-1506`) is carried by three
  variants and consumed by no operation. `LoginRecoveryRequired`
  (`:743-749`) repeats the pattern on login.
- **Change.**

```gleam
pub type Access { Access(session: Session, token: AccessToken, expires_at: Option(Int)) }
/// Refreshes within `refresh_margin` of expiry, waits up to `refresh_wait` for
/// another request's refresh, and restores past a stale revision.
pub fn access_token(client: Client, session: Session) -> Result(Access, SessionError)
pub fn refresh(client: Client, session: Session) -> Result(Access, SessionError)  // after a 401
pub fn recover_refresh(client: Client, recovery: RefreshRecovery) -> Result(Access, SessionError)
pub type SessionError {
  SessionNotFound SessionLost SessionForeign SessionStoreUnavailable SessionHasNoAccessToken
  RefreshTokenUnavailable RefreshRevoked RefreshRejected(OAuthError)
  RefreshNotSent(ProviderFailure) RefreshQuarantined(QuarantineReason)
  RefreshWaitTimedOut RefreshUnconfirmed(RefreshRecovery)
}
pub type Action { Reauthenticate RetryLater FixConfiguration RejectRequest }
pub fn session_error_action(error: SessionError) -> Action
pub fn complete_login(client, request: Request(String)) -> Result(Session, LoginError)
// LoginError gains CustodyUnconfirmed(CustodyRecovery), RecoveryEnded, RecoveryExpired
```

- **Security.** Waiting never authorizes a second dispatch; a waiter
  reserves only after the winner settles as proven not sent, as today.
  Deleting `RefreshReservationRecovery` weakens nothing, because quarantine
  is custody state, not a property of the value. `Action` never maps an
  uncertain outcome to a retry of the same request.
- **Config.** `with_refresh_margin` (30 s), `with_refresh_wait` (5 s).
  `session_revision` becomes internal.
- **Breaks callers:** yes. **Effort:** M.

### WARDEN-R3 `warden/testing`: a scripted provider with test PKI

- **Problem.** Warden's provider, TLS server and PKI are test-private Erlang
  and an OpenSSL script, so secure_mcp wrote 459 lines and sso_portal 644
  (SMCP-5, SSO-6, FEEDBACK theme 8). HTTPS is mandatory and kryptos cannot
  issue CA-signed leaves, so both fell back to `public_key:pkix_test_data`.
- **Change.** OTP `ssl`/`public_key` plus gose for signing; no new dependency.

```gleam
pub fn start_provider(options: ProviderOptions) -> Result(Provider, TestError)
pub fn config(provider: Provider, redirect_uri: String) -> config.Config  // issuer, client, anchor, loopback
pub fn authorize(provider, redirect: warden.LoginRedirect, subject: String) -> Result(Request(String), TestError)
pub fn issue_access_token(provider, subject:, audiences:, scopes:, ttl_seconds:) -> String
pub fn revoke_refresh_tokens(provider, subject: String) -> Nil
pub fn set_clock_skew(provider, seconds: Int) -> Nil
pub fn requests(provider) -> RequestCounts
pub fn check_custody_store(store: store.CustodyStore) -> Result(Nil, List(String))
pub fn stop(provider) -> Nil
```

- **Security.** `testing.config` sets the test anchor and
  `AllowLoopbackForTesting` explicitly; no production default changes.
- **Breaks callers:** no. **Effort:** L.

### WARDEN-R4 A gleam_http boundary that sets the cookies safely

- **Problem.** The boundary is strings: `QueryCallback`/`FormPostCallback`
  (`:736-741`), a binding cookie value (`:432-443`), a `#(String, String)`
  header (`:1401`) (SSO-8). Worse, six cookie duties fall to the app
  (`docs/APPLICATION-RESPONSIBILITIES.md`: `__Host-`, `Secure` whatever the
  scheme, `HttpOnly`, `SameSite` by response mode, a lifetime beyond the
  login, reuse across tabs); the reference RP needs
  `protect.binding_attributes` to get them right. `gleam_http` is already a
  dependency.
- **Change.** `Callback` and `BrowserBinding` become internal.

```gleam
pub fn begin_login(client, request: Request(a), options: LoginOptions) -> Result(LoginRedirect, BeginLoginError)
pub fn login_response(response: Response(b), redirect: LoginRedirect) -> Response(b)
pub fn complete_login(client, request: Request(String)) -> Result(Session, LoginError)  // query or form post
pub fn authorize(request: Request(a), token: AccessToken) -> Request(a)
```

- **Security.** The binding cookie is always `__Host-`, `Secure`,
  `HttpOnly`, `Path=/`, `SameSite=Lax` (query) or `None` (form post), with
  `Cache-Control: no-store`; nothing relaxes it. The shape check stays.
- **Breaks callers:** yes. **Effort:** S–M.

### WARDEN-R5 A handle that survives restarts; lazy discovery when supervised

- **Problem.** `supervised` (`:173-180`) returns `ChildSpecification(Client)`,
  but `static_supervisor.add` discards child data, and a restart re-runs
  `start`, which allocates new names and a new pool key (`:236`, `:242`,
  `:277-278`): a captured `Client` goes stale. `StartError` is flattened to
  `InitFailed("warden failed to start")` (`:177`). Discovery runs in child
  init, so a provider outage at boot fails the parent tree (SSO-10).
- **Change.**

```gleam
pub fn new(config: Config) -> Result(Client, StartError)        // validates; allocates names once
pub fn start(client: Client) -> Result(Nil, StartError)          // waits for discovery, ≤ startup timeout
pub fn supervised(client: Client) -> ChildSpecification(Client)  // same names; discovers in background
pub fn stop(client: Client) -> Nil
```

- **Security.** Until discovery and the compatibility check succeed, every
  operation returns `ProviderNotReady`; `begin_login` already re-checks
  compatibility (`:552-555`).
- **Breaks callers:** yes. **Effort:** M.

### WARDEN-R6 Opaque `Config`; a service-client constructor

- **Problem.** `Settings` is a public 18-field record with a nested
  `Transport` (`config.gleam:216-257`); secure_mcp writes
  `config.Transport(..config.default_transport(), ...)` (`app.gleam:102`),
  and timeouts, `allowed_hosts` and `max_pending_logins` have no setter.
  Both apps print `validate`'s `List(ConfigError)` with `string.inspect`
  (secure_mcp `app.gleam:117`, sso_portal `app.gleam:185`). `config.new`
  requires `redirect_uri` (`config.gleam:275`) and `start` refuses a provider
  without the authorization-code grant (`:357-360`), so a
  `client_credentials`-only service invents a redirect URI and still fails
  against a machine-only server (card concern 1). `valid_scope`,
  `valid_redirect_uri`, `algorithm_name` and `TrustAnchors` are public
  machinery (`config.gleam:407`, `:542`, `:584`, `:642`).
- **Change.** Opaque `Config` with flat setters: `with_allowed_hosts`,
  `with_request_timeout`, `with_max_response_bytes`, `with_startup_timeout`,
  `with_store_timeout` and `with_max_pending_logins` join the existing ones;
  validation moves into `warden.new` (R5); `describe_config_error`;
  `InvalidLimit(String)` becomes `InvalidLimit(Limit)`; a new
  `config.service_client(issuer:, client_id:, authentication:)` needs no
  redirect URI and configures no login.

- **Security.** `service_client` refuses `PublicClient`, skips only the
  login compatibility checks, and makes `begin_login`/`complete_login`
  return `LoginNotConfigured`.
- **Breaks callers:** yes. **Effort:** M.

### WARDEN-R7 Revocation on logout (RFC 7009)

- **Problem.** Logout removes custody and builds the end-session URL, but the
  refresh token stays live at the provider, and the app cannot revoke it
  because the token is never exposed (SSO-2, `:2005-2065`).
  `LogoutOptions` has no default, so callers construct it in full
  (sso_portal `web.gleam:308,327`; reference RP `web.gleam:377,396`), and
  adding the field breaks them. `observation.gleam:21-23` already claims
  Warden sends revocation requests.
- **Change.**

```gleam
pub fn default_logout() -> LogoutOptions   // revoke: RevokeRefreshToken
pub type LogoutOutcome { LoggedOut(provider_redirect: Option(String), revocation: RevocationOutcome) }
pub type RevocationOutcome { Revoked RevocationUnsupported RevocationFailed(ProviderFailure) }
```

- **Security.** Custody is removed first; a failed revocation never restores
  it. Design §4.8 lists revocation as a gap needing a growth decision
  (open question 4).
- **Breaks callers:** yes. **Effort:** M.

### WARDEN-R8 Introspection a resource server can authorize with

- **Problem.** `TokenInfo` has no audience and exposes `claims: Dynamic`
  (`:1921-1933`); `introspect` maps `active: true` to `ActiveToken` without
  checking `exp` (`internal/native/client.gleam:496-529`). secure_mcp decodes
  `aud` as string-or-list and re-checks expiry (`auth.gleam:98-133`) (SMCP-4,
  card concern 4). A bearer token over the 64 KiB request cap fails as a
  transport failure, which a resource server reads as "provider down".
- **Change.** Replace `claims` with `audiences: List(String)` plus
  `decode_token_claims(info, decoder)`; check `exp` strictly (no tolerance,
  as D15 does for ID tokens) and `nbf` with the clock tolerance, answering
  `InactiveToken`; refuse tokens over 8 KiB as `TokenTooLarge` without a
  request.
- **Breaks callers:** yes. **Effort:** S.

### WARDEN-R9 Failure classification and descriptions

- **Problem.** No error type has a description or classification: apps
  print `string.inspect` (secure_mcp `app.gleam:117-120`), and sso_portal
  keeps a 31-line `LoginError` map. Growing unions: `IdentityProblem`,
  `Incompatibility` (PAR, JAR), `OAuthError` and `Denial` (IANA registries),
  `LoginError`, `BeginLoginError`, `SessionError`, `ConfigError`,
  `TransportReason` (follows http_gun), `Prompt` (`create`), `ResponseMode`
  (JARM), `SigningAlgorithm`, `ClientAuthentication` (mTLS). Closed:
  `HttpMethod`, `IssuerParameterPolicy`, `PkceAdvertisementPolicy`, `Trust`,
  `Introspection`.
- **Change.** One error type per boundary, each with
  `describe_<type>(error) -> String`; `login_error_action` and
  `session_error_action` return `Action`; module docs name the growing
  unions. `TransportFailure(sent: Bool)` becomes an `evidence` of `NotSent`
  or `MaybeSent` (FEEDBACK theme 3).
- **Breaks callers:** partly. **Effort:** S.

### WARDEN-R10 `warden/telemetry`: closed reasons, correlation, session events

- **Problem.** `observation.Failed(sent: Bool, class: String)`
  (`observation.gleam:39-42`) is stringly beside the closed `TransportReason`
  (`:126-144`); events carry no correlation, so apps join by emitting pid
  (SSO-7, SMCP-9); login, refresh and logout emit nothing, which hid the
  SSO-3 race.
- **Change.** Rename to `warden/telemetry`; `Failed(evidence, reason)` with
  a `TransportReason`; `correlation` in all metadata, set by a pure
  `warden.with_correlation(client, id)` view and forwarded to Warden's
  http_gun calls; add `login()`, `refresh()` and `logout()` descriptors with
  closed outcomes and no identity values.
- **Breaks callers:** yes. **Effort:** M.

### WARDEN-R11 Small corrections

- `ClientToken.expires_in` (`:1854`) is relative while sessions report
  `expires_at`; use `expires_at`. S.
- Provider-actor calls use the store timeout (5 s + 1 s,
  `internal/call.gleam:26`, `internal/native/provider.gleam:518`) but wait
  on a 10 s key fetch, so a slow JWKS refetch reports `UnknownSigningKey`
  early. Derive the call timeout from the request timeout. S.
- Docs: the README should start with the common path and carry a
  supervision example and the defaults table; its snippet does not compile
  (`secret`, comment-only case arms); there is no CHANGELOG;
  `warden-design.md` §4.3–4.4 still shows laboratory `CustodyOwner`
  signatures. S.
- Dependencies: `http_gun` and `sinal` are path dependencies (D16), which
  blocks publication. The gose and kryptos ranges admit versions the
  security evidence never covered (D18): run CI on the newest resolved
  versions and record them in `SUPPLY-CHAIN.md`. S.

## 5. Defaults table

| Operation                         | Current default                                                                                                                                                                                     | Proposed                                                 |
| --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| `start`: discovery and first JWKS | 15 s shared deadline                                                                                                                                                                                | keep; `supervised`: background, backoff 1 s to 60 s      |
| Provider HTTP request             | 10 s deadline; body 1 MiB; head 16 KiB, 100 headers; no redirects                                                                                                                                   | keep; document head limits                               |
| Request body                      | 64 KiB                                                                                                                                                                                              | keep; bearer tokens over 8 KiB refused locally (R8)      |
| Store calls                       | 5 s + 1 s proxy margin                                                                                                                                                                              | keep                                                     |
| Provider-actor calls              | 5 s + 1 s, shorter than the 10 s fetch they wait on                                                                                                                                                 | request timeout + 1 s (R11)                              |
| `complete_login` end to end       | no single deadline; about 34 s worst case                                                                                                                                                           | document the bound                                       |
| Pending logins                    | 100 000, 10 min each, swept every 60 s                                                                                                                                                              | keep                                                     |
| Callback input                    | 16 KiB total, 4 KiB per value                                                                                                                                                                       | keep; document                                           |
| Login option values               | **no cap**                                                                                                                                                                                          | 2 KiB per value                                          |
| Sessions in custody               | **no count cap** (D14); 12 h absolute, 1 h idle; swept every 60 s                                                                                                                                   | per-identity cap, oldest evicted (open question 6)       |
| Install/publication history       | 100 000 entries, hard-coded (`:299`)                                                                                                                                                                | keep; document                                           |
| JWKS cache                        | `Cache-Control` clamped to 60 s–24 h, else 1 h                                                                                                                                                      | keep                                                     |
| Unknown-`kid` refetch             | immediate per new kid (64 remembered), else at most once a second                                                                                                                                   | keep                                                     |
| Refresh loser                     | **none**: immediate `RefreshInProgress`                                                                                                                                                             | wait up to 5 s                                           |
| Refresh margin                    | **none** (app glue)                                                                                                                                                                                 | 30 s                                                     |
| Resend after a possible send      | never (refresh token, authorization code)                                                                                                                                                           | keep                                                     |
| Refresh holder (durable store)    | process monitor                                                                                                                                                                                     | lease of request + store timeout; expiry quarantines     |
| Introspection `exp`               | **not checked**                                                                                                                                                                                     | strict `exp`; `nbf` with clock tolerance                 |
| Logout revocation                 | none                                                                                                                                                                                                | revoke the refresh token when advertised                 |
| `client_credentials`              | no cache; one token request per call                                                                                                                                                                | document                                                 |
| Supervisor restarts               | 10 in 60 s                                                                                                                                                                                          | keep; document                                           |
| Security policy                   | advertised S256 required; `iss` required when advertised; public destinations, system trust; RS256/PS256/ES256/EdDSA, `none`/HMAC unrepresentable; exact audience; clock tolerance 5 s, 0 for `exp` | keep, all fail closed                                    |
| Binding cookie                    | the app's duty                                                                                                                                                                                      | `__Host-`, `Secure`, `HttpOnly`, `SameSite` by mode (R4) |

No defaults table exists today (`config.new`'s doc lists five); the README
should carry this one.

## 6. Convention feedback

- **1, opaque config.** Fits `Config`. Keep Warden's pure validation that
  reports every problem at once; it moves into `warden.new`. Per-call option
  records (`LoginOptions`, `LogoutOptions`) work as public records with a
  `default_*()` constructor and record update, as the API guidelines allow;
  the observed break (SSO-2) came from a record without a default.
- **2, returned records.** Add: a type whose construction would forge
  authority (`Session`, `VerifiedIdentity`, `AccessToken`, recovery values)
  is opaque whatever its evolution; 13 negative compile cases check that.
- **3, classification.** `is_retryable` is the wrong question for
  single-use codes and rotating refresh tokens, which are never resent after
  a possible send. Classify by caller action instead.
- **4, bounded by default.** D14 refuses a global session cap because a
  full store would deny logins; allow a per-principal bound with a stated
  rationale.
- **5, lifecycle.** `start(config)` plus `supervised(config)` cannot yield a
  restart-stable handle, because the names must exist before the child
  specification. Use `new(config) -> Handle`, then `start(handle)` and
  `supervised(handle)`. Child init should not block on a remote party.
- **6, errors.** `describe_error` collides when a module has several error
  types; use `describe_<type>`. "One error per boundary" works when a
  boundary is a family of operations with one recovery model.
- **7, glossary.** A `<pkg>/testing` that mints tokens ships a fake IdP in
  production builds; allow a sibling `<pkg>_testing` package. Correlation
  is a client view (`with_correlation`), since Warden emits in the caller's
  process.

## 7. Open questions

1. **Store trust.** Sealed records for every durable store (proposed), or
   also a trusted unsealed store? Who rotates the sealing key, and are two
   keys accepted during rotation?
2. **Clock.** Durable lifetimes need wall-clock `expires_at`; accept that
   change to design §4.6 for durable stores?
3. **Reservation recovery.** Delete `RefreshReservationRecovery` and defer
   operator reconciliation of a quarantine (design §4.4 leaves it open)?
4. **Revocation.** Adopt RFC 7009 now (a gap in design §4.8) and make it the
   logout default?
5. **Test support.** `warden/testing` in the package, or `warden_testing`?
6. **Session cap.** A per-identity cap with eviction, or D14's unbounded
   count?
7. **Boundary.** Replace the raw-string `Callback` with `gleam_http` requests
   (proposed), or keep both, which makes two ordinary paths?
8. **Resource-server role.** Local JWT access-token validation (RFC 9068) in
   Warden, or in another package?
9. **Per-login redirect URI** (SSO-10): one from a configured allowlist with
   exact matching, or one redirect per client?
