# sso_portal: feedback

## Verdict

**Warden, http_gun and Sinal compose into an ordinary wisp/mist/pog portal, but
durable sessions are not possible.** Login, callback, a Postgres session row,
a billing call over http_gun with the user's token, refresh on expiry and on
401, and a refresh race between two requests all work through public imports.
All 10 tests pass and `gleam run` prints the full narrative. The string-typed
Warden boundary costs about 14 lines in wisp and is not the problem. The
friction is session lifecycle:

- Warden's custody is in-memory with no port. The Postgres row is only an
  index into it, and a Warden restart signs everyone out (SSO-1, blocker).
- Logout cannot revoke the refresh token at the provider (SSO-2).
- A request that loses a refresh race has to poll (SSO-3).
- A logout that races a refresh silently leaves the session in custody
  (SSO-4).
- The app had to write a 644-line scripted OpenID provider and a test PKI
  before it could exercise any of this (SSO-6).

Glue per seam, in app lines:

| Seam                                                       | Glue                                                                                                                  |
| ---------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Warden ↔ wisp/gleam_http strings                           | ~14 (`web.gleam:52-56,73-78,355-361`, `billing.gleam:33-37`); the routes total ~110, incl. a 31-line `LoginError` map |
| Durable custody (pog)                                      | ~164 (`session_store.gleam` 119, `web.gleam:163-207`), and the custody is still not durable                           |
| Warden token → http_gun request                            | 2 for the header, 23 for 401 → refresh → retry (`web.gleam:280-302`)                                                  |
| Refresh policy and race                                    | 160 (`access.gleam`): 40 outcome mapping, 21 join/poll, 17 expiry margin                                              |
| Logout race                                                | 19 (`web.gleam:214-232`)                                                                                              |
| Telemetry correlation across packages                      | ~50 (`telemetry.gleam:62-65,102-115,168-191,235-256,275-276`)                                                         |
| http_gun clients for loopback                              | ~20 (`app.gleam:192-214`), 16 (`browser.gleam:28-43`)                                                                 |
| Test provider + PKI for Warden                             | 644 (`fake_idp.gleam` 584, `pki.gleam` 36, `sso_portal_pki_ffi.erl` 24)                                               |
| Startup ordering (`redirect_uri` before the port is bound) | 18 (`server.gleam:74-91`)                                                                                             |

Dependency resolution: there were no conflicts. The resolver picked wisp
2.2.2, mist 6.0.3 and pog 4.1.0 alongside Warden's exact pins
(`gleam_crypto == 1.6.0`, `gleam_time == 1.11.0`, `gose == 2.2.0`,
`kryptos == 1.5.0`, `telemetry == 1.4.2`). The only resolution errors were
Hex API rate limits from the parallel builds.

**Status (2 Oct 2026):** warden 845b75e replaced the exact pins with
major-bounded ranges. `gleam update` resolved the same versions (the manifest
is byte-identical: gleam_stdlib 1.0.5, gleam_crypto 1.6.0, gleam_time 1.11.0,
gose 2.2.0, kryptos 1.5.0, telemetry 1.4.2).

## Findings

### SSO-1 Session custody cannot be made durable; the app's Postgres row is only an index

- **Packages**: warden, pog. **Kind**: extensibility. **Severity**: blocker.
- **Evidence**:
  - The app stores what it can in Postgres (`session_store.gleam:1-119`):
    subject, email and Warden's custody reference.
  - It cannot store tokens. Warden never reveals the refresh token, and
    `AccessToken` is opaque (`warden.gleam:1386-1404`).
  - `sessions_survive_web_restart_but_not_warden_restart_test`
    (`test/sso_portal_test.gleam:216-233`) shows the consequence:
    - After a web-tier restart, the row plus Warden's live custody still
      serve `/dashboard`.
    - After `app.restart_warden` (`app.gleam:122-132`),
      `warden.restore_session` returns `SessionNotFound` and the durable row
      becomes useless. The app deletes it and redirects to `/login`
      (`web.gleam:185-192`).
  - `SessionNotFound` also covers logout and expiry
    (`warden.gleam:1329-1342`), so the app cannot tell "Warden restarted"
    from "signed out".
  - This is the card's concern 3 (`docs/composition/scan/warden.md`,
    "No storage port"), now with a running reproduction.
  - Cause: the transaction store and custody owner are private actors
    started inside `warden.start` (`warden.gleam:286-306`) and held opaquely
    in `Client` (`warden.gleam:56-70`).
- **What durable custody would need**: Warden already has the right
  operation set internally (`warden/internal/custody_store.gleam:651-714`):
  `install`, `get`, `reserve_refresh`, `settle_refresh`, `publish_refresh`
  and `remove`. A Postgres implementation needs:
  1. Those six operations as a public record of functions over public
     command/receipt types (`Install`, `Snapshot`, `Dispatch`, `Publish`,
     `Settlement`).
  2. Atomic revision compare-and-set:
     `update ... set revision = revision + 1 where reference = $1 and revision = $2 and reservation is null`.
  3. Idempotent command ids, so a resubmitted `Install` or `Publish`
     returns the original receipt.
  4. Absolute and idle expiry evaluated by the store.
  5. A codec for `VerifiedIdentity`. The store holds verified claims, so the
     contract must say that the store is trusted, or Warden must re-check a
     MAC it adds on encode.
- **Proposal** (warden): `config.with_custody(settings, store: custody.Store)`.
  `custody.Store` is a public record of the six functions above, plus a
  public `warden/custody` module that holds the command, receipt and
  `identity_codec` types. The current actor stays the default. Pending
  logins need the same treatment (`with_transactions`) for multi-node use.
  Separately, return `SessionUnknownToCustody` distinct from
  `SessionEnded`/`SessionExpired`.

### SSO-2 Logout cannot revoke tokens; the refresh token stays live at the provider

- **Packages**: warden. **Kind**: composition. **Severity**: major.
- **Evidence**:
  - `gleam run`, step 4, prints `provider refresh tokens still active after logout: 1`.
  - `warden.logout` removes local custody and builds the end-session URL
    (`warden.gleam:1996-2048`). It never calls a revocation endpoint, and
    no `revoke` operation exists. `LogoutOutcome` has only
    `RedirectToProvider | NoEndSessionEndpoint`
    (`warden.gleam:1977-1983`).
  - The application cannot fill the gap itself: the refresh token is never
    exposed, so `web.gleam:323-344` can only delete its row.
  - A copied refresh token stays usable until the provider expires it.
    Revocation appears among the card's "still missing" items. The new
    evidence is that an app cannot work around it.
  - Docs nit: `warden/observation.gleam:21-23` lists "revocation" among the
    requests Warden makes.
- **Proposal** (warden): add RFC 7009 support: `LogoutOptions(..,
revoke: RevokeRefreshToken | RevokeAll | NoRevocation)` with a
  `default_logout()` (also the card's concern 6). Return a
  `RevocationFailed(ProviderFailure)` warning variant that does not undo
  local removal.

### SSO-3 Concurrent refresh: the loser gets `RefreshInProgress` and must poll

- **Packages**: warden. **Kind**: ergonomics. **Severity**: major.
- **Evidence**:
  - The reservation itself works.
    `concurrent_requests_share_one_refresh_test`
    (`test/sso_portal_test.gleam:123-149`) sees exactly one refresh grant
    and no rejected grants at the provider.
  - The second request, however, receives `Error(RefreshInProgress)`
    (`warden.gleam:1549`). Warden offers no way to wait for the winner's
    published session.
  - The app polls `restore_session` and retries the refresh every 20 ms
    (`access.gleam:103-123`). An instrumented run showed about 15
    `RefreshInProgress` replies during one 300 ms refresh.
  - A second race path exists: a request still holding the old revision
    gets `RefreshSessionStale` or `SessionStale` from
    `session_access_token` (`warden.gleam:1370-1382`, `:1411-1425`) and
    must restore first (`access.gleam:47`, `:125-134`).
  - Deciding _when_ to refresh is also app glue: compare `expires_at`
    against a margin (`access.gleam:36-52`).
- **Proposal** (warden): one operation,
  `warden.fresh_access_token(client, session, margin_seconds:, wait_ms:) -> Result(#(Session, AccessToken), RefreshError)`.
  It returns the current token when it is not near expiry. Otherwise it
  refreshes, or waits on the in-flight reservation and returns the session
  it publishes, and it restores past a stale revision. `refresh_session`
  remains for forced refresh (the 401 case).

### SSO-4 `logout` refuses a stale session revision and leaves the session in custody

- **Packages**: warden. **Kind**: defect. **Severity**: major.
- **Evidence**:
  - `logout_with_a_stale_session_revision_keeps_custody_test`
    (`test/sso_portal_test.gleam:235-258`): request A holds revision r, and
    request B refreshes it to r+1. `warden.logout(A's session)` then
    returns `LogoutSession(SessionStale)`, and `restore_session` still
    succeeds. The session the user asked to end is still live.
  - Cause: `logout` calls `load_current`, which demands an exact revision
    (`warden.gleam:2017-2019`, `:1370-1382`), before `custody.remove`.
  - A caller that maps every `Error(_)` to "signed out" removes only its
    own row. The reference RP shows "Sign-out failed" instead
    (`warden/consumer/src/warden_reference/web.gleam:386`), which leaves
    the user to retry a logout they cannot see failed for a race.
  - The app retries after a restore (`web.gleam:214-232`).
- **Proposal** (warden): end a session by reference regardless of revision.
  Removal is idempotent and the user's intent does not depend on the
  revision. If revision checking must remain, add
  `logout_reference(client, reference, options)`.
- **Status (2 Oct 2026):** resolved by warden 47e49d8 (in 845b75e); `logout`
  removes custody by reference and never returns `SessionStale`. The app's
  `end_custody` retry (19 lines, `web.gleam:214-232`) is gone; `end_session`
  calls `warden.logout` directly (`web.gleam:209-213`). The reproduction is now
  `logout_with_a_stale_session_revision_ends_custody_test`
  (`test/sso_portal_test.gleam:235-258`): logout with the pre-refresh revision
  returns `Ok`, and `restore_session` then returns `SessionNotFound`.

### SSO-5 Refresh outcomes need a 40-line map to reach three decisions

- **Packages**: warden. **Kind**: ergonomics. **Severity**: minor.
- **Evidence**:
  - `access.gleam:62-101` maps 7 `RefreshResult` and 10 `RefreshError`
    variants (`warden.gleam:1438-1491`) onto three decisions: _use this
    session_, _sign in again_, _retry later_. A fourth case, _another
    request is refreshing_, is handled through SSO-3.
  - It is easy to get wrong: `RefreshRejectedByEndpoint(InvalidGrant)` means
    re-login, while the same constructor with `InvalidRequest` means retry.
  - This is the card's concern 5 (success and failure split across both
    channels), with real glue as evidence.
- **Proposal** (warden):
  `warden.refresh_advice(Result(RefreshResult, RefreshError)) -> RefreshAdvice`
  with `UseSession(Session) | Reauthenticate | RetryLater | JoinInFlight`.
  Alternatively, fold this into SSO-3's `fresh_access_token`, which would
  return that type directly.

### SSO-6 No public test provider or test PKI; a consumer writes 644 lines first

- **Packages**: warden, http_gun. **Kind**: ergonomics/docs. **Severity**: major.
- **Evidence**:
  - Warden's scripted provider is test-private Erlang
    (`warden/test/warden_test_provider.erl`, erlang-jose), and its PKI is an
    OpenSSL script (`warden/scripts/test-pki`).
  - Warden insists on an `https` issuer (`warden/config.gleam:354-355`, `:561-575`),
    and loopback needs `AllowLoopbackForTesting` plus trust anchors.
  - So the app wrote `fake_idp.gleam` (584 lines: discovery, JWKS, PKCE,
    rotation, userinfo, end-session) and a PKI.
  - A self-signed certificate from kryptos is refused by OTP even when it is
    listed as the anchor (`selfsigned_peer`, reproduced with an OpenSSL
    self-signed certificate too). kryptos cannot issue CA-signed leaves, so
    the chain comes from `public_key:pkix_test_data/1`
    (`sso_portal_pki_ffi.erl:1-24`).
  - http_gun has `http_gun/testing` scripts, but they only replace HTTP
    _inside_ a client. Warden builds its own http_gun client and accepts
    none (card: "Warden gives callers no way to inject an existing
    http_gun.Client"), so cassettes cannot stand in for the provider.
- **Proposal** (warden): either publish a `warden/testing` module (or a
  dev-dependency package) with a scripted provider: `start(settings) ->
Provider`, `issuer`, `trust_anchors_pem`, `revoke_refresh_tokens`,
  `set_clock_skew`, `stats`. Or let `warden.start` accept an `http_gun.Client`
  through a test-only `config.with_http_client`, so that `http_gun/testing`
  scripts can play the provider.

### SSO-7 One request cannot be followed across Warden and http_gun without pid bookkeeping

- **Packages**: warden, http_gun, sinal. **Kind**: composition. **Severity**: minor.
- **Evidence**:
  - `billing_401_refreshes_and_retries_in_one_request_test`
    (`test/sso_portal_test.gleam:97-121`) and `gleam run` step 2 print one
    request's trace: http_gun `response_headers(401)`, Warden
    `POST /token -> 200`, then http_gun `response_headers(200)`. Joining them
    took app glue:
    - http_gun events carry a correlation `Id` through
      `http_gun.with_correlation` (`web.gleam:244-245`).
    - Warden's `[warden, http, request]` has no correlation field
      (`warden/observation.gleam:21-45`). The app attributes Warden events by
      emitting pid, which it links to the request's correlation id
      (`telemetry.gleam:102-115`, `:235-256`).
    - mist reuses a connection process across keep-alive requests, so the
      link must be resolved at emission time.
  - Warden's own http_gun client runs with `observations: None`
    (`warden/internal/transport.gleam:263-292`), so provider calls never
    appear as http_gun lifecycle events.
  - Warden emits nothing for login, refresh outcome, the reservation race
    or custody removal. The SSO-3 race and the SSO-4 failed logout are
    invisible except as a `/token` status.
  - The app also has to start the `telemetry` application itself before it
    attaches (`telemetry.gleam:74`, `:275-276`), as the reference RP does.
  - wisp, mist and pog emit nothing through Sinal.
- **Proposal** (warden): `warden.with_correlation(client, http_gun/telemetry.Id) -> Client`,
  a pure view mirroring http_gun's. Put `correlation: Option(Id)` in
  `HttpRequest` metadata and forward it to Warden's http_gun calls. Add
  typed `[warden, session, *]` events (login completed or rejected, refresh
  outcome, logout) with closed, non-secret metadata.
- **Status (wave 2):** partially resolved by sinal 355b100. `attach` and
  `observe` start the `telemetry` application, so the hand start is gone:
  the `ensure_all_started` call, its comment, the `@external` and two imports
  (10 lines, old `telemetry.gleam:15-16,72-76,274-276`). The correlation
  itself is unchanged. Warden's `HttpRequest` still has no correlation field,
  Warden's provider calls still emit no http_gun events, and http_gun still
  keys correlation on its own `telemetry.Id` (HTTPGUN-R8 has not landed). The
  pid-link glue stays (`telemetry.gleam:60-65,84-106,148-170,215-238`).
  `sinal/correlation` was not adopted; see "Re-run after wave 2".

### SSO-8 gleam_http interop: Warden's web boundary is strings

- **Packages**: warden. **Kind**: ecosystem-interop. **Severity**: minor.
- **Evidence**:
  - The callback is `QueryCallback(String)` or `FormPostCallback(String)`
    (`warden.gleam:736-741`). The app must pass `request.query` raw, not
    wisp's parsed pairs (`web.gleam:78`).
  - Bindings are cookie strings parsed by `parse_browser_binding`
    (`web.gleam:52-56`, `:73-76`).
  - The access token comes out as a `#(String, String)` header
    (`billing.gleam:33-37`).
  - The post-logout redirect must be an absolute URL that the app rebuilds
    from the request (`web.gleam:355-361`).
  - About 14 lines in total. Warden already depends on `gleam_http`
    (`warden/gleam.toml`), but exposes no `Request` in its API.
  - **Answer to the brief**: Warden fits an ordinary wisp app. Strings keep
    it framework-neutral, and the glue is small.
- **Proposal** (warden): two helpers:
  - `warden.callback_from_request(request.Request(String)) -> Callback`,
    which picks query or form-post by method.
  - `warden.authorize(request.Request(a), AccessToken) -> request.Request(a)`.

### SSO-9 Two destination vocabularies, and no client to share

- **Packages**: warden, http_gun. **Kind**: composition. **Severity**: nit.
- **Evidence**:
  - Brief item (c): the app keeps two http_gun clients plus the browser's.
  - Warden's provider client is private and built from a closed
    `DestinationPolicy` enum, `PublicInternetOnly | AllowLoopbackForTesting | AllowPrivateNetwork`
    (`warden/config.gleam:204-214`).
  - The billing client is a `destination.Policy` record of booleans
    (`http_gun/destination.gleam:23-35`). The app sets it with a nested
    record update: `allow_public: False, allow_loopback: True`
    (`app.gleam:192-214`).
  - **Not sharing is the right call here**:
    - Warden needs HTTPS to a private root with OIDC limits.
    - Billing is plain HTTP on loopback, with observations sent to the app's
      forwarder.
    - The origins differ, so pooling would gain nothing.
  - **The costs of separation**: Warden's traffic is invisible to http_gun
    telemetry (SSO-7), and the same "loopback allowed" intent is spelled
    two ways.
- **Proposal** (warden): document the mapping from `DestinationPolicy` to
  `destination.Policy` in `config.gleam`. If Warden ever accepts a client
  (SSO-6), take a `destination.Policy` directly.
- **Status (2 Oct 2026):** partially resolved by http_gun a2869b7
  (`config.allow_loopback`). The browser client drops its nested
  `destination.Policy` update and the `http_gun/destination` import
  (`browser.gleam:27-37`, 16 → 8 lines). The billing client uses
  `allow_loopback` too, but it is loopback-only, and denying public hosts still
  needs the nested record update (`app.gleam:198-211`), so it did not get
  shorter. The two vocabularies (Warden's enum, http_gun's record) remain.

### SSO-10 `redirect_uri` must be known before Warden starts, and `start` needs the provider up

- **Packages**: warden. **Kind**: flexibility. **Severity**: nit.
- **Evidence**:
  - `config.new` fixes `redirect_uri`, and `warden.start` performs
    discovery synchronously (`warden.gleam:164-171`).
  - The portal's handler needs the started `Client`, so the app reserves a
    port before binding mist (`server.gleam:74-91`, `app.gleam:68-72`).
  - A provider outage at boot fails the whole portal with
    `DiscoveryFailed`. There is no lazy or retrying start.
- **Proposal** (warden): optionally allow the redirect URI per login
  (`LoginOptions(redirect_uri: Option(String))`, validated against a
  configured allowlist), and a `start` mode that defers discovery to the
  first `begin_login` (`ProviderNotReady` already exists).

## What worked well

- **Login is tight and typed.**
  - `begin_login` and `complete_login` with a browser binding cookie covered
    the whole flow in about 75 lines of wisp.
  - A tampered `state` was refused as `CallbackRejected(UnknownState)`
    before any exchange: the provider saw zero code grants
    (`test/sso_portal_test.gleam:173-187`).
  - Every `LoginError` variant maps cleanly to an HTTP status.
- **The refresh reservation is correct under concurrency.** Exactly one
  refresh token reached the provider while two requests raced. Rotation left
  one live token. A revoked grant surfaced as
  `RefreshRejectedByEndpoint(InvalidGrant)` and forced a clean re-login
  (`test/sso_portal_test.gleam:189-201`).
- **Clock tolerance is one call with a typed failure.** A provider 20 s
  ahead fails with `IdentityRejected(IdTokenNotYetValid)`, and
  `config.with_clock_tolerance(60)` accepts it
  (`test/sso_portal_test.gleam:151-171`).
- **Warden tokens into http_gun.** `AccessToken` stays opaque (no
  accidental logging), and `authorization_header` drops straight into
  `request.set_header`.
- **http_gun failure detail.** Billing down surfaced as
  `ConnectionFailed(ConnectionRefused)` with no string parsing, and the
  session survived (`test/sso_portal_test.gleam:203-214`). A 401 is data,
  not an error.
- **http_gun configuration and telemetry.**
  - `with_correlation` is a pure view, so per-request tracing costs one
    line.
  - The `Anchors([der])` trust and the loopback policy were plain record
    updates.
- **Sinal plumbing.** Typed descriptors from both packages and
  `sinal.observe` worked unchanged. The forwarder dropped under a
  `static_supervisor` with no extra wiring.
- **pog fit.** The session table, `returning` decoders and the shared pool
  had no friction with Warden's pinned dependencies.

## Re-run after fixes (2 Oct 2026)

Packages: warden 845b75e, http_gun a2869b7, sinal at head. `gleam update`
changed nothing in `manifest.toml`; gleam_stdlib resolves to 1.0.5. All 10
tests pass under `../scripts/with-postgres.sh gleam test`, and `gleam run`
prints the full narrative (step 4 still reports one provider refresh token
active after logout: SSO-2 is unchanged).

| Seam                    | Before                                    | After                                                    |
| ----------------------- | ----------------------------------------- | -------------------------------------------------------- |
| Logout race (SSO-4)     | 19 (`web.gleam:214-232`)                  | 0; `end_session` calls `warden.logout` once              |
| Browser http_gun client | 16 (`browser.gleam:28-43`), nested policy | 8 (`browser.gleam:28-35`), `config.allow_loopback`       |
| Billing http_gun client | 13 (`app.gleam:198-210`), nested policy   | 14 (`app.gleam:198-211`), `allow_loopback` + nested deny |

Net: 49 lines removed, 25 added across `web.gleam`, `browser.gleam`,
`app.gleam` and the test.

New friction:

- **`allow_loopback` only widens.** A loopback-only client (the billing API)
  must still write `destination.Policy(..settings.destination, allow_public: False)`,
  so the helper covers half the intent. Proposal (http_gun): a
  `config.loopback_only(config)` helper, or a `destination.loopback_only()`
  constructor.
- No breaking change had to be absorbed: the app does not build
  `request_options.Options` or call `send_with_options`, and `logout`'s
  signature is unchanged.

## Re-run after wave 2

Packages: sinal a0c05ef, http_gun 1dc20a1, warden bf4f796 (all migrated to
the wave 2 Sinal API). The app does not use json_blueprint. All 10 tests pass
under `../scripts/with-postgres.sh gleam test`, and `gleam run` prints the
full narrative. The step 2 trace is unchanged, and step 4 still reports one
provider refresh token active after logout (SSO-2).

Only `telemetry.gleam` changed: 276 → 253 lines, 7 added and 30 removed.

| Seam                               | Before                                                              | After                                  |
| ---------------------------------- | ------------------------------------------------------------------- | -------------------------------------- |
| Telemetry application start        | 10 (`ensure_all_started`, comment, `@external`, 2 imports)          | 0                                      |
| Handler ids                        | 4 (random suffix + 3 `sinal.handler_id`)                            | 0                                      |
| `observe` error plumbing           | 6 (`replace_error` and `)` around each of 3 `use … <- result.try(`) | 0; `let attachment = sinal.observe(…)` |
| Forwarder construction             | 4 (`forwarder.new(name, 1024)` + `replace_error`)                   | 1 (`forwarder.new(name)`)              |
| Correlation across Warden/http_gun | ~45 (pid links, `AddWarden`, `begin_request`, trace filter)         | ~45, unchanged (SSO-7)                 |

The random suffix existed only because a node runs several portals in one
test run and fixed handler ids would collide. Automatic ids remove the reason
for it.

New friction:

- **`sinal/correlation` cannot replace the app's request key yet.** The app
  does not invent a key type; it borrows http_gun's `telemetry.Id`, because
  `http_gun.with_correlation(client, telemetry.Id)` is the only
  correlation-carrying call in the request path. Adopting `Correlation` today
  would add a second key and a second map in the collector for no gain:

  ```gleam
  pub fn begin_request(t: Telemetry) -> #(correlation.Correlation, gun_telemetry.Id) {
    let request = correlation.unique()
    let gun = gun_telemetry.new_id()
    // the collector now maps pid -> Correlation and gun Id -> Correlation
    process.send(t.collector, Link(process.self(), request, gun))
    #(request, gun)
  }
  ```

  So the app keeps `gun_telemetry.Id`. Once http_gun takes a `Correlation`
  (HTTPGUN-R8) and Warden forwards one (SSO-7), `begin_request` becomes
  `correlation.unique()` and the pid map goes.

- **Automatic ids lose attribution.** `telemetry:list_handlers([])` used to
  show `sso-portal-warden-…`; it now shows `{sinal_handler, N}`. `with_id`
  restores a name, but brings back `Result(_, AttachError)` and the
  uniqueness problem the random suffix solved. A `with_label` prefix that
  stays unique (`{sinal_handler, Label, N}`) would keep both. Nit.
- **Forwarder names are node-lifetime.** `telemetry.start` calls
  `process.new_name("sso_portal_http_gun_events")`, so each start leaves one
  `persistent_term` entry of drop counters for the life of the node (about
  one per test). The forwarder docs say so. For an app that starts once this
  costs nothing; a test suite that starts the app per test accrues the
  entries. Nit.

No new API read worse than the old one here: every change removed lines.

Migration guides: the sinal guide was enough. Its `observe` and
`forwarder.new` snippets match the app's code almost line for line, and it
names sso_portal under the telemetry start. It does not say what to use for
a correlation key while the packages still carry their own; the CHANGELOG's
HTTPGUN-R8 line implies "wait", which this app did.
