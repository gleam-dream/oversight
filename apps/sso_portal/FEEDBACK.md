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
- **Status (wave 4):** resolved by warden 6ed8fb5 (`warden/store`). The port is
  three functions over one table of sealed records
  (`get`, `put(record, expected_version)`, `delete_expired`). The app's pog
  adapter is `warden_records.gleam` (146 lines with comments and an identifier
  guard, about 60 of SQL and decoding) and passes `testing.check_store`
  (`the_postgres_store_passes_warden_conformance_test`).
  `config.with_custody_store`, `with_transaction_store` and `with_sealing_key`
  wire it in (`app.gleam:start_warden`). The reproduction became
  `sessions_survive_web_and_warden_restarts_test`: after `app.restart_warden`
  (a new `Client`, empty processes) the same browser cookie still serves
  `/dashboard`, the provider saw one code grant in total, and the restarted
  Warden then refreshes and logs out the session. With
  `with_custody_store` removed the same test fails (303 to `/login`), so it
  tests the store and not the harness. A second test reads
  `warden_records.sealed`: the access token, the custody reference and the
  subject appear in no row. The portal's own `portal_sessions` row stays (it
  maps the cookie to the reference and carries the subject for counting), but
  it is no longer a workaround for custody.

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
- **Status (wave 4):** resolved by warden 6ed8fb5. `default_logout()` revokes
  the refresh token (RFC 7009) and `logout` returns
  `LoggedOut(revocation: Revoked, ..)`. `login_dashboard_logout_test` now
  asserts `revocations == 1` and `active_refresh_tokens == 0` at the provider;
  `gleam run` step 5 prints `provider refresh tokens active after logout: 0`
  (it was 1). No app code beyond using `default_logout()`.

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
- **Status (wave 4):** resolved by warden 6ed8fb5. `warden.access_token`
  refreshes inside the margin and a concurrent caller waits for the in-flight
  refresh (`with_refresh_wait`, default 5 s) instead of polling. The 160-line
  `access.gleam` (policy type, margin check, 20 ms poll, stale-revision
  restore) is deleted. `concurrent_requests_share_one_refresh_test` passes
  unchanged in intent: one refresh grant, none rejected.

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
- **Status (wave 4):** unchanged and still resolved. The test now holds a
  session across `warden.refresh` and logs out with the stale value; it gets
  `LoggedOut(revocation: Revoked, ..)` and `restore_session` then answers
  `SessionNotFound`.

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
- **Status (wave 4):** resolved by warden 6ed8fb5. `session_error_action`
  returns `Reauthenticate | RetryLater | Recover | ..`; the 40-line outcome map
  is `settled` in `web.gleam` (18 lines, of which 4 recover an unconfirmed
  refresh and 5 map the action to the page decision). `RefreshUnconfirmed` is
  the one case the app still handles and cannot test, since neither
  `warden/testing` nor `testing.memory_store` injects a lost publication.

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
- **Status (wave 4):** resolved by warden 6ed8fb5 (`warden/testing`).
  `fake_idp.gleam` (584), `pki.gleam` (36) and `sso_portal_pki_ffi.erl` (24)
  are deleted: 644 lines. `testing.start_provider`, `testing.config`,
  `with_refresh_delay`, `with_access_token_ttl`, `set_clock_skew`,
  `revoke_refresh_tokens` and `requests` cover the knobs the tests used. Not
  covered, so the app still carries glue (see "Re-run after wave 4"): no HTTP
  `/authorize`, no access-token revocation, a PEM-only trust anchor.

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
- **Status (follow-up):** partially resolved by http_gun c45adfe.
  `http_gun.with_correlation` takes a `sinal/correlation.Correlation` and the
  `correlation` key in http_gun events carries it, so the app's request key is
  now `correlation.unique()` instead of a borrowed http_gun `Id`: the type
  change touches 9 lines of `telemetry.gleam` and removes the `gun_telemetry.new_id`
  call (`web.gleam:224-225` is unchanged). The join glue does not shrink,
  because Warden still carries no correlation. The collector keeps its
  `Dict(Pid, Correlation)`, `Link`, `AddWarden` and the emission-time pid
  resolution (`telemetry.gleam:60-65,84-106,148-170,215-238`, about 45
  lines). Only the second key the wave 2 re-run feared never appeared.
- **Status (wave 3):** partially resolved by http_gun e55fa1d. Events now
  always go through `sinal.emit`, so Warden's private http_gun client
  (previously `observations: None`) shows its provider calls in the app's
  `[http_gun, lifecycle]` handler: discovery, JWKS and `/token` each appear as
  six milestones (checked: 57 records for one login, the 401 trace unchanged).
  They are uncorrelated, because Warden cannot take a `Correlation`, and the
  pid link for `[warden, http, request]` is unchanged (about 45 lines). The
  same default also delivers the test browser's own client to the handler,
  which is noise here (see "Re-run after wave 3").
- **Status (wave 4):** resolved by warden 6ed8fb5. One
  `correlation.unique()` per request goes to `warden.with_correlation` and
  `http_gun.with_correlation` (`web.gleam:traced`, 10 lines).
  `[warden, http, request]`, `[warden, login]`, `[warden, refresh]` and
  `[warden, logout]` carry it, and Warden's `/token` call now appears among the
  correlated `[http_gun, lifecycle]` events. The pid map, `Link`, `AddWarden`
  and the emission-time lookup (about 45 lines) are gone from `telemetry.gleam`.

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
- **Status (wave 4):** resolved by warden 6ed8fb5. `begin_login(client,
request, options)` takes the wisp request, `login_response` writes the 303
  and the `__Host-warden_binding` cookie, `complete_login` takes the request,
  `authorize(request, token)` sets the header, and `logout_response` builds the
  redirect. The binding cookie code, the raw-query handling and the header tuple
  are gone (about 14 lines). One line remains: `request.set_body(request, "")`,
  because `complete_login` wants `Request(String)` and wisp's request carries a
  `Connection`.

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
- **Status (wave 3):** partially resolved by http_gun e55fa1d.
  `destination.loopback_only()` replaces the nested record update, so the
  billing client's "no helper for denying public hosts" workaround and the
  comment that explained it are gone (`start_billing_client` 21 → 13 lines),
  and the browser client sets its policy in one pipeline step
  (`browser.new` 11 → 9 lines, with `destination` imported again because
  `config.allow_loopback` would have kept public hosts allowed). The two
  vocabularies remain: Warden still takes the `DestinationPolicy` enum
  (`app.gleam`, `AllowLoopbackForTesting`) while the billing and browser
  clients take `destination.Policy`.
- **Status (wave 4):** unchanged. `testing.config` and `testing.trusting` set
  `AllowLoopbackForTesting` for Warden (the app no longer names it), while the
  billing and browser clients still take `destination.loopback_only()`. Two
  vocabularies for one intent remain; they are just no longer in app code for
  Warden.

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
- **Status (wave 4):** not offered. `LoginOptions` has no `redirect_uri` and
  `warden.new` still validates a fixed `redirect_uri`, so `server.free_port`
  and the port reservation remain (18 lines, `server.gleam`, `app.gleam`).
  `warden.supervised` starts without the provider, which covers the outage
  half of the finding, but the app starts Warden directly with `warden.start`
  and has not exercised that path.

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

## Re-run after the follow-up fixes

Packages: http_gun c45adfe (056536b), sinal and warden at head. All 10 tests
pass under `../scripts/with-postgres.sh gleam test`, and `gleam run` prints the
full narrative. The step 2 trace is unchanged: every http_gun milestone is
`(correlated)` and the Warden `POST /token` sits between the two attempts.
Step 4 still reports one provider refresh token active after logout (SSO-2).

Only `telemetry.gleam` changed (16 added, 15 removed, 253 → 254 lines). The app
defines no Sinal events and no record builders, uses no json_blueprint and no
grind, so the Blueprint field, sinal builder, `required_field()` and grind
`worker.codec` follow-ups do not touch it.

| Seam                         | Before                                                      | After                                                                 |
| ---------------------------- | ----------------------------------------------------------- | --------------------------------------------------------------------- |
| Request key type             | `gun_telemetry.Id` from `new_id()`, http_gun's own id       | `correlation.unique()`, the shared Sinal type; 1 import, 0 net lines  |
| http_gun side of the join    | `GunLifecycle.correlation` compared to the pid-link id      | same comparison, now against the `Correlation` the app passed in      |
| Warden side of the join      | ~45 (pid links, `AddWarden`, `begin_request`, trace filter) | ~45, unchanged (SSO-7)                                                |
| `begin_request` return value | an http_gun `Id` that only http_gun understood              | a `Correlation` the app can also log, return to the browser, or reuse |

Net: the glue did not shrink. The brief expected join tables keyed on
http_gun's old `Id` to disappear, but this app never had one: it had a single
pid → id map, and that map is needed for Warden, not for http_gun. The change
is a type swap; the app gains a vocabulary that Warden can adopt later, not
fewer lines.

New friction:

- **The pid map is the whole cost and no http_gun change can remove it.**
  Warden's `[warden, http, request]` event has no `correlation` field, so the
  collector still resolves the emitting pid at emission time. Once Warden
  accepts a `Correlation` (the SSO-7 proposal, now with the right type),
  `begin_request` is `correlation.unique()`, `Link`, `AddWarden` and the dict
  go, about 45 lines.
- **A request process cannot hand its correlation to a library that calls
  Warden on its behalf.** The correlation reaches http_gun through
  `with_correlation` on a client view, but `warden.restore_session` and
  `refresh_session` take no equivalent, so the one call that produces the
  `/token` event is the one call the app cannot tag.
- **`Correlation` is opaque with only `unique()` and `from_string`.** The app
  never needs to construct one from an inbound header, so this costs nothing
  here, but `last_request_trace` still selects "the most recent request" by
  the collector's own `last` field rather than by a value a test could name.
- No breaking change beyond `with_correlation`'s argument type had to be
  absorbed, and the migration guide's before/after snippet matched the app's
  one call site.

## Re-run after wave 3

Packages: http_gun e55fa1d (14eacc6), sinal 42dd684, warden 57e1f54. All 10
tests pass under `../scripts/with-postgres.sh gleam test`, and `gleam run`
prints the full narrative with the same four steps and the same step 2 trace.
`warden.stop` now waits up to 5 s for its supervisor; `restart_warden` and
`app.stop` need no change and the suite still runs in about 5 s. Step 4 still
reports one provider refresh token active after logout (SSO-2). No finding
besides SSO-7 and SSO-9 is touched: the blockers named in the wave 3 brief
(pool, transactional submit, abandonment, job context, saga storage) belong to
saga and grind, which this app does not use, and SSO-1 (durable custody) is a
Warden port that wave 3 did not add.

What changed (5 files, 66 added and 61 removed, of which about 40 on each side
are `gleam format` re-indenting the three observers):

| Seam                                                                               | Glue before                                                                                                                                                                  | Glue after                                                                                                                    |
| ---------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| Billing client config (`app.gleam`)                                                | 21 lines: `Config(..)` update, `allow_loopback`, then a second `Config(..)` update with a nested `Policy(..)` to deny public hosts, plus a comment saying there is no helper | 13: `default() \|> with_request_timeout \|> with_connect_timeout \|> with_observations \|> with_destination(loopback_only())` |
| Browser client (`browser.gleam`)                                                   | 11: `Config(..)` update with `trust` and `deadline_ms`, then `allow_loopback`                                                                                                | 9: three setters; `loopback_only()` is the intent, not `allow_loopback`                                                       |
| `Failure` reads (3 places)                                                         | `string.inspect(failure.reason)` printed constructor names (`ConnectionFailed(..)`)                                                                                          | `error.describe(failure)`: a one-line message that never leaks URL or headers                                                 |
| `stop` results (2 places)                                                          | `let _ = http_gun.stop(..)` and a `Nil` after it                                                                                                                             | `http_gun.stop(..)` returns `Nil`; 1 line removed                                                                             |
| Handler ids (3 observers)                                                          | automatic `{sinal_handler, N}` ids (the "Automatic ids lose attribution" friction)                                                                                           | `observe_labelled(event, "sso_portal_warden", ..)`; `list_handlers` is readable again, no `Result`, no suffix                 |
| Correlation join with Warden                                                       | about 45 lines                                                                                                                                                               | about 45, unchanged (SSO-7)                                                                                                   |
| Everything else (session store, access policy, logout, fake provider, PKI, routes) | unchanged                                                                                                                                                                    | unchanged                                                                                                                     |

Net: about 10 lines of glue removed from the two config sites plus the
`Failure` and `stop` call sites, and 0 added. The app uses no
`correlation.from_key` (it makes request keys with `unique()`), no
`fields.check` (it defines no Sinal events), no views, no `supervised`/`named`
(the clients are owned by `App`, not a supervisor) and no json_blueprint, saga
or grind.

Seams that still need glue:

- **Warden correlation (warden, SSO-7)**: the pid-to-`Correlation` map, `Link`,
  `AddWarden` and the emission-time lookup stay until `[warden, http, request]`
  carries a correlation or `restore_session`/`refresh_session` accept one.
- **Durable custody (warden, SSO-1)**, **logout revocation (warden, SSO-2)**,
  **refresh race polling (warden, SSO-3, `access.gleam`)**, **stale-revision
  logout (warden, SSO-4)**, **test provider and PKI (warden, SSO-6)**,
  **string boundary (warden, SSO-8)**: untouched by wave 3.
- **Two destination vocabularies (warden and http_gun, SSO-9)**: Warden's
  enum versus `destination.Policy`.

New friction:

- **The new default emits to every handler, including clients the app does not
  care about.** Before wave 3 a client with no `observations` was silent. Now the
  test browser's http_gun client (a harness, not part of the portal) and
  Warden's private client both emit into the app's node-wide
  `[http_gun, lifecycle]` handler. One login produces 57 records, and all but 6
  of them are uncorrelated browser and Warden traffic. `last_request_trace`
  still filters by correlation, so the narrative is unchanged, but
  `telemetry.records` is no longer "the portal's traffic". There is no
  per-client opt-out short of `config.with_observations(some_forwarder)`
  pointing at a forwarder nobody listens to, or an app-level `forwarder.route`.
  A `config.without_observations` (or an observation target of `Silent`)
  would say it directly. Owner: http_gun. Minor, and arguably the right default
  for production.
- **Synchronous handlers now run in the pool and body processes** for any
  client without `with_observations` (the migration guide says so). The app's
  handler only does `process.send`, so it is safe; a handler that did more
  would slow requests, and nothing at the `sinal.observe` call site says which
  emitter processes it will run in.
- **`error.describe` changes what the page prints.** The dashboard used to show
  `ConnectionFailed(ConnectionRefused)` and the test matched on the constructor
  name; it now shows "Connection failed: connection refused; not sent". The
  test asserts the new message and `not sent`. The correct stable key for a
  test or a log is `error.name` (`connection_failed.connection_refused`), but
  the page shows the human line. Nothing to fix, only a test that had pinned
  the old inspect text and was brittle for that reason.
- **Shadowing in the app, not a package problem.** `web.billing_error`'s
  parameter is called `error`, so the natural `import http_gun/error` needed an
  alias (`as gun_error`). Every other app that imports it will hit the same name
  collision with a variable called `error`.
- **`observe_labelled` with a formatter**: three arguments push the closure to a
  hanging indent, so the 12-line observers grew by about 12 lines of
  whitespace-only diff. No logic grew.

Migration guides: the http_gun guide named sso_portal's seams exactly
(`loopback_only()`, `.reason`) and its before/after for `Config` updates
applied as written. It does not say that a `config.allow_loopback` replacement
for the old `allow_loopback` plus nested `Policy` update would leave public
hosts allowed; `loopback_only()` is the equivalent, and a note under the
destination table would save the next reader a security-relevant slip. The
sinal guide's `observe_labelled` snippet matched line for line. Warden's
CHANGELOG entry on `stop` was the only warden change that mattered and needed
no code.

## Re-run after wave 4

Packages: warden 6ed8fb5/5a7da27, http_gun dcfbc07/4a6eeb0, sinal at head.
All 13 tests pass under `../scripts/with-postgres.sh gleam test` (10 before:
`sessions_survive_web_restart_but_not_warden_restart_test` became
`sessions_survive_web_and_warden_restarts_test`, and three tests are new:
sealed rows, the pog store against `testing.check_store`, and a session ended
elsewhere). `gleam run` prints a five-step narrative: step 2 is new (Warden
restarts, the dashboard still loads, the provider has seen one code grant) and
step 5 reports `0` active provider refresh tokens after logout. The suite runs
in about 3 s.

The app diff, excluding docs: 15 tracked files, 603 added and 1156 removed,
plus the new `warden_records.gleam` (146 lines). `FEEDBACK.md` and `README.md`
are not in that count.

| Seam                                                       | Glue before                          | Glue after                                                                                                              |
| ---------------------------------------------------------- | ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------- |
| Warden ↔ wisp/gleam_http strings                           | ~14, plus a 31-line `LoginError` map | 1 (`request.set_body(request, "")`); `login_failure` is 9 lines on `login_error_action`                                 |
| Durable custody (pog)                                      | ~164 and not durable                 | 146 in `warden_records.gleam` (~60 real) and 3 in `app.gleam`; durable, sealed, conformance-checked                     |
| Refresh policy and race                                    | 160 (`access.gleam`)                 | 0; `settled` in `web.gleam` is 18 (unconfirmed-refresh recovery and the action → page decision)                         |
| Logout revocation                                          | impossible                           | 0                                                                                                                       |
| Warden token → http_gun request                            | 2 + 23 for 401 → refresh → retry     | 1 + 8 (the retry stays, as the API's decision to refuse a live token)                                                   |
| Telemetry correlation across packages                      | ~45                                  | 10 (`traced`); the collector lost its pid map, `Link` and `AddWarden`                                                   |
| Test provider + PKI for Warden                             | 644                                  | 0 for the provider; 18 for the login-page hook, 10 for PEM → DER in the browser, +73 in `billing_api.gleam` (see below) |
| Startup ordering (`redirect_uri` before the port is bound) | 18                                   | 18, unchanged (SSO-10 not offered)                                                                                      |

Net: 644 lines of test provider and PKI, the 160-line `access.gleam`, the pid
link and the string seams are gone. What was added is the pog adapter, the
billing resource server with its deny list, the login-page hook and three new
telemetry observers; the tests grew by 71 lines for three new tests.

Seams that still need glue:

- **Login page for HTTP-level tests (warden, `warden/testing`).** The test
  provider serves no `/authorize`, and `testing.authorize` takes the opaque
  `LoginRedirect`, which only the portal's `/login` handler holds. A browser
  that talks HTTP to the portal cannot use it. The app added `Context.login_response`
  (production: `warden.login_response`) and a test-only replacement that
  registers the login with the provider and points `Location` at the callback.
  The hook is test scaffolding in production code, and the scripted browser never
  visits the provider's login page. Proposal: `testing.authorize_url(provider,
url, subject:)`, or serve `/authorize` for a configured subject.
- **Access-token revocation (warden, `warden/testing`).** `resource.verify` is
  local, so nothing the provider does to a live token reaches the billing API.
  The 401 → refresh path needs a revocation the validator can see, so
  `billing_api.gleam` keeps its own deny list (an actor, about 35 lines). The provider's
  `/revoke` marks access tokens revoked only for introspection and userinfo. This
  is correct for a local validator and needs saying in the `resource` docs:
  revocation is introspection's job.
- **Trust anchor format (warden, http_gun).** `testing.trust_anchor_pem` is PEM;
  http_gun's `Anchors` takes DER and `CustomCa` takes a file path. The browser
  client decodes the PEM itself (10 lines). Proposal: `testing.trust_anchor_der`.
- **pog and `timestamptz` (pog).** `pog.timestamp_decoder()` fails on a
  `timestamptz` column under pog 4.1.0 (`Int` expected, `Array` found), so the
  adapter selects `extract(epoch ...)::bigint` and writes with `to_timestamp`.
  The `warden/store` documentation's SQL sketch uses `timestamptz`, so every pog
  adapter will meet this. The workaround is about 12 lines; a published pog adapter
  (or the fix) would save every consumer the rediscovery.
- **Sealing key custody (app).** The key that opens every record lives in the
  `App` value here (random at start). In production it is a secret-manager value
  that must survive deploys, and losing it turns every session into
  `SessionRecordUnreadable`. Warden documents this; the app does not demonstrate
  `with_previous_sealing_keys` rotation.
- **Unconfirmed refresh (warden).** `RefreshUnconfirmed` and
  `CustodyUnconfirmed` recovery are wired and untested: no provider or store
  option injects a lost publication.

New friction:

- **`complete_login` is `Request(String)`, `begin_login` is `Request(a)`.** wisp's
  request carries a `Connection`, so a GET callback needs `set_body`, and a
  form-post callback would need `wisp.read_body` first. One line here; a
  `form_post` configuration would add the body read to every app.
- **The binding cookie is `Secure` and `__Host-`.** The test browser's jar
  ignores both, but a developer's browser over `http://127.0.0.1` depends on the
  browser treating loopback as secure. The README of the portal says nothing about it.
- **Outcome names in the portal's trace use `string.inspect`.** `[warden, login]`
  and `[warden, refresh]` expose closed outcome types but no name function (only
  `transport_reason_name` exists), so the observers print constructor names.
  Proposal: `login_outcome_name`, `refresh_outcome_name`, `revocation_name`.
- **Warden's provider calls make the trace 7 events longer.** With correlation
  they are now `(correlated)` http_gun events (6 for `/token`, plus `[warden.refresh]`). That is what the
  finding asked for, but `last_request_trace` in the narrative is 20 lines.
- No warden call had to change meaning: the migration guide's sso_portal table
  matched the files it named, including the expected `[warden.http.request]
POST /token -> 200` line.
