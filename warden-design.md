# Typed Gleam OIDC / OAuth 2.0 Relying Party — Design

**Status:** Draft v0.1 · **Date:** 2026-09-19 · **Working package name:** `warden` (check Hex availability)
**Target:** Gleam on Erlang/OTP 27+ · **Backend (v1):** [`oidcc`](https://github.com/erlef/oidcc) via FFI

Items marked **[VERIFY]** are claims I could not confirm from public docs and must be resolved by a spike (§9) before the design is frozen.

---

## 1. Goals, scope, non-goals

### Goals

1. Give Gleam applications a **strongly typed, hard-to-misuse** OIDC Relying Party (RP) and OAuth 2.0 client API.
2. **Inherit correctness from a certified, audited implementation** (`oidcc`) rather than re-implementing protocol or crypto logic.
3. Keep the backend **replaceable**: one narrow seam, a backend-agnostic test suite, and a documented migration path (§5).
4. Make validation **externally sourced**: OpenID Foundation conformance suite, RFC test vectors, third-party OPs, and the upstream library's own fixtures — not bespoke tests we wrote ourselves (§6).

### Non-goals (v1)

- Writing or re-implementing JOSE, crypto, discovery, JWKS handling, or ID-token validation. (Facade rule, §2.)
- Building an OAuth/OIDC **authorization server**. Use Keycloak, Ory, Boruta, etc.
- Implicit, hybrid and resource-owner-password flows (deprecated by current OAuth security guidance; also outside oidcc's certified profiles).
- JavaScript target support. `gleam.toml` pins `target = "erlang"`.
- A catalogue of social-login provider quirks (GitHub, Apple, …). Possible later as a separate `warden_providers` package, using Elixir's `assent` as a reference for quirks.

---

## 2. Design principles

| #   | Principle                               | Consequence                                                                                                                                                            |
| --- | --------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| P1  | **Delegate, don't reimplement**         | Any check `oidcc` performs stays in `oidcc`. The facade only adds checks `oidcc` leaves to the caller, in exactly one module (`warden/login`), each with its own test. |
| P2  | **Parse at the edge, typed inside**     | The Erlang shim converts terms to Gleam types once. No `Dynamic` escapes the FFI module.                                                                               |
| P3  | **Insecure states are unrepresentable** | Opaque types with validating constructors (`Issuer`, `State`, `Nonce`, `PkceVerifier`, `Pending`, tokens). If you hold a `VerifiedIdentity`, it was verified.          |
| P4  | **Secure defaults; opting out is loud** | PKCE S256 and nonce are always on. Anything weaker requires a function prefixed `unsafe_`, which appears in review greps and CI lints.                                 |
| P5  | **One seam**                            | All backend-specific code sits behind the `Backend` record (§4.9). Nothing above it mentions `oidcc`.                                                                  |
| P6  | **Tests come from outside**             | We write adapters and harnesses, not protocol tests from scratch.                                                                                                      |

---

## 3. Target design

### 3.1 Layers

```
┌──────────────────────────────────────────────────────────────┐
│ Application (wisp / mist handlers, sessions, storage)        │
└───────────────▲──────────────────────────────────────────────┘
                │ typed public API  (warden, warden/login, warden/token, …)
┌───────────────┴──────────────────────────────────────────────┐
│ Facade (pure Gleam)                                          │
│  • typed domain model, opaque constructors                   │
│  • state / PKCE-verifier / nonce generation                  │
│  • callback parsing, state comparison, Pending lifecycle     │
│  • error taxonomy + mapping                                  │
└───────────────▲──────────────────────────────────────────────┘
                │ Backend record (the seam, §4.9)
┌───────────────┴───────────────┐      ┌────────────────────────┐
│ warden/backend/oidcc            │      │ (future) native backend│
│  Gleam decoders + Erlang shim │      │  gose + kryptos + HTTP │
└───────────────▲───────────────┘      └────────────────────────┘
                │ Erlang calls
┌───────────────┴──────────────────────────────────────────────┐
│ oidcc (certified, audited) → erlang-jose → OTP crypto/ssl    │
└──────────────────────────────────────────────────────────────┘
```

### 3.2 Repository / module layout

Single Hex package for v1. Splitting later is easier than merging, but opaque types cannot be constructed across packages, so v1 stays one package **[see open question Q3]**.

```
src/
  warden.gleam                  # top-level operations (begin_login, complete_login, refresh, …)
  warden/issuer.gleam           # Issuer (validated https URL)
  warden/provider.gleam         # Provider handle, supervision child spec
  warden/client.gleam           # Client, ClientId, ClientAuth, Secret, RedirectUri
  warden/scope.gleam            # Scope
  warden/login.gleam            # AuthRequest, Pending, Callback, parse_callback, state/PKCE logic
  warden/token.gleam            # Tokens, AccessToken, RefreshToken, IdTokenHint, TokenType
  warden/identity.gleam         # Identity, StandardClaims, Claims, UserKey
  warden/error.gleam            # error types
  warden/store.gleam            # PendingStore interface + ETS-actor reference impl
  warden/entropy.gleam          # injectable randomness (deterministic in tests)
  warden/backend.gleam          # Backend record definition (the seam)
  warden/backend/oidcc.gleam    # oidcc implementation (decoders, mapping)
  warden/backend/mock.gleam     # in-memory backend for application developers' tests
src/warden_oidcc_ffi.erl        # the ONLY Erlang file; shape conversion, no logic
test/                         # unit, contract, corpus tests
conformance/                  # reference RP app + harness for the OIDF suite (separate Gleam project)
```

### 3.3 Responsibility matrix

Who performs each security-relevant step. **The "oidcc" rows are assumptions taken from its feature list and must be confirmed against its source in spike S1.** Where oidcc leaves a step to the caller, the facade owns it.

| Step                                                                            | Owner                         | Notes                                                                                                                |
| ------------------------------------------------------------------------------- | ----------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| Discovery, issuer exact-match, metadata caching                                 | oidcc                         | via its provider configuration worker                                                                                |
| JWKS fetch, refresh on unknown `kid`                                            | oidcc                         | README lists automatic JWK refreshing                                                                                |
| Authorization URL construction, PKCE challenge (S256)                           | oidcc                         | facade supplies the verifier                                                                                         |
| **PKCE verifier generation**                                                    | **facade**                    | 32 bytes CSPRNG → base64url (43 chars); entropy injectable for the RFC 7636 App. B vector                            |
| **`state` generation and comparison**                                           | **facade**                    | constant-time compare; single-use via `PendingStore.take`                                                            |
| **`nonce` generation**                                                          | **facade**                    | passed to oidcc for both request and validation **[VERIFY: oidcc rejects a missing/mismatched nonce when supplied]** |
| RFC 9207 `iss` response parameter check                                         | oidcc or facade **[VERIFY]**  | oidcc lists RFC 9207 support; confirm it is enforced on the callback path, else facade enforces                      |
| Callback param parsing (duplicates, code+error together)                        | **facade**                    | RFC 6749 §4.1.2                                                                                                      |
| Code exchange, client authentication                                            | oidcc                         | `client_secret_basic/post/jwt`, `private_key_jwt`                                                                    |
| ID token signature, `alg` pinning, `iss`, `aud`, `azp`, `exp`, `nbf`, `at_hash` | oidcc                         | never the facade                                                                                                     |
| Userinfo `sub` match                                                            | facade **enforces via types** | `expected: Subject` is a required argument                                                                           |
| Pending TTL                                                                     | **facade**                    | default 10 min, plus store-level expiry                                                                              |
| Error mapping to typed taxonomy                                                 | **facade**                    | golden-tested (§6, V1)                                                                                               |
| TLS verification, timeouts, SSRF policy for discovery/JWKS                      | **facade config → shim**      | never rely on library/OTP defaults; see §3.5                                                                         |

### 3.4 Process model

- `oidcc` runs a **provider configuration worker** (a supervised process, registered by name) that discovers and refreshes metadata and JWKS.
- The facade exposes `provider.child_spec(config)` returning a child specification for a `gleam_otp` supervisor (exact types depend on the pinned `gleam_otp`). The worker's registered name is created **once at startup** from a typed name (e.g. `gleam/erlang/process.new_name`), never from user-supplied strings, to avoid unbounded atom creation.
- `Provider` is an opaque handle: `#(Backend, BackendHandle)`.
- Worker crash → supervisor restart. Calls made while unavailable return `Error(ProviderUnavailable(_))`; they never panic.

### 3.5 FFI boundary rules

1. **One Erlang file** (`warden_oidcc_ffi.erl`), ≤ ~300 lines, containing only: argument conversion (Gleam term → oidcc option map), record → map flattening for decoders, and normalising `{ok, _} | {error, _}`. No conditionals about security. Anything with logic lives in Gleam.
2. Every value coming back is decoded with `gleam/dynamic/decode` into a Gleam type inside `warden/backend/oidcc`. Decoder failure → `Error(Backend(MalformedBackendResponse(_)))`, never a crash.
3. **Error mapping is total.** Each known oidcc error reason maps to a specific variant; anything else maps to `Backend(Unmapped(String))` — kept for forward compatibility and logged, never treated as success.
4. **Explicit TLS policy** in the shim: `verify_peer`, OS/`public_key:cacerts_get()` trust anchors, hostname check, bounded timeouts, and a size cap on responses, passed through oidcc's request options **[VERIFY exact option names in the pinned version]**. A test asserts that a self-signed OP is rejected.
5. **Private-key material** (`private_key_jwt`, DPoP) crosses the boundary as a JWK JSON string — one of the few places an encoded string is genuinely required (§4.12). The Gleam type is opaque and redacted.
6. Function names/arity in the shim are pinned to the exact oidcc version. An oidcc bump that changes them fails compilation of the shim or the contract tests, not production.

### 3.6 Dependency and version policy

- Pin `oidcc` (and transitively `jose`) to **exact versions** with a committed lockfile. Upgrades are deliberate PRs that must pass the full validation gate (§6.9).
- oidcc requires **OTP 27 or newer**; CI matrix: minimum and latest supported OTP.
- Note on upstream risk: the EEF deprecated `oidcc_cowboy` for lack of usage, so upstream does prune what nobody uses. Track `oidcc` maintenance health as a standing item (§9).
- **Certification is version-specific.** The certification listing shows `oidcc` **3.0.0**; current releases are newer (3.8.0 at time of writing). We may say "built on a certified library" but must not say "certified" for the facade or for newer oidcc versions unless we run and submit the suite ourselves (§6.3).

### 3.7 Login sequence

```
App                Facade                     oidcc                   OP
 │ begin_login ───►  gen state, nonce, verifier
 │                   build Pending ─────────► create_redirect_url ───► (URL only)
 │ ◄── #(Uri, Pending)
 │ store.put(pending) ; redirect user ─────────────────────────────► authenticate
 │ ◄──────────────────────── redirect back with code, state, iss ────
 │ parse_callback(params)
 │ store.take(id) ──► Pending (single use, TTL)
 │ complete_login:
 │   check state == pending.state  (constant time)
 │   check iss param if present    (or delegate, S1)
 │   ─────────────────────────────► retrieve_token ─────────────────► token endpoint
 │                                   validate ID token (sig/alg/iss/aud/exp/nonce/at_hash)
 │ ◄── Session(tokens, identity)    ◄────────────────────────────────
```

---

## 4. Library API

Snippets are illustrative Gleam; final signatures are settled during M1.

### 4.1 Core opaque types

```gleam
// warden/issuer
pub opaque type Issuer { Issuer(Uri) }
pub type IssuerError { NotHttps NotAbsolute HasQueryOrFragment Malformed }
pub fn parse(String) -> Result(Issuer, IssuerError)
pub fn unsafe_allow_http_for_testing(String) -> Result(Issuer, IssuerError)  // localhost only
pub fn to_string(Issuer) -> String

// warden/login
pub opaque type State { State(String) }         // 256-bit, from Entropy
pub opaque type Nonce { Nonce(String) }
pub opaque type PkceVerifier { PkceVerifier(String) }
pub opaque type Pending { Pending(/* state, nonce, verifier, redirect_uri,
                                     issuer, client_id, created_at, expires_at */) }
pub opaque type AuthCode { AuthCode(String) }

// warden/scope — open only where the spec is open
pub type Scope { OpenId Profile Email Address Phone OfflineAccess Custom(String) }
```

### 4.2 Provider

```gleam
pub type ProviderConfig {
  ProviderConfig(
    issuer: Issuer,
    name: process.Name(ProviderMessage),   // created once at startup
    http: HttpPolicy,                      // timeouts, size caps, TLS (secure defaults)
    refresh: RefreshPolicy,                // metadata/JWKS refresh intervals
    allowed_id_token_algs: Option(List(SigningAlg)),  // pin; default = from client registration
  )
}
pub fn child_spec(ProviderConfig) -> supervision.ChildSpecification(Provider)  // oidcc backend
pub fn child_spec_with(Backend, ProviderConfig) -> supervision.ChildSpecification(Provider)
pub fn issuer(Provider) -> Issuer
```

### 4.3 Client

```gleam
pub type ClientAuth {
  NoAuth                                  // public client (PKCE only)
  SecretBasic(Secret)
  SecretPost(Secret)
  SecretJwt(Secret)
  PrivateKeyJwt(key: SigningKey, alg: SigningAlg)
}
pub type Client { Client(id: ClientId, auth: ClientAuth, redirect_uri: RedirectUri) }
// Secret and SigningKey are opaque; reveal() is explicit; constructors trim/reject empty.
// RedirectUri is validated: absolute, no fragment; https unless loopback.
```

### 4.4 Login flow

```gleam
pub type AuthRequest {
  AuthRequest(
    scopes: List(Scope),                 // OpenId is always added
    prompt: List(Prompt),                // None_ | Login | Consent | SelectAccount
    max_age: Option(Duration),
    login_hint: Option(String),
    acr_values: List(String),
    ui_locales: List(String),
    extra: List(#(String, String)),      // escape hatch; cannot override reserved names
    par: Bool,                           // use pushed authorization request (RFC 9126)
  )
}
pub fn default_request() -> AuthRequest

pub type Callback {
  CallbackCode(code: AuthCode, state: State, iss: Option(String))
  CallbackError(error: AuthorizationErrorCode, description: Option(String),
                state: Option(State), iss: Option(String))
}
pub type CallbackParseError {
  MissingParameter(String)
  DuplicateParameter(String)      // e.g. two `code` params → reject
  AmbiguousResponse               // code and error both present
}

// Top-level operations (warden.gleam)
pub fn begin_login(Provider, Client, AuthRequest) -> Result(#(Uri, Pending), LoginError)
pub fn begin_login_with(Provider, Client, AuthRequest, Entropy) -> Result(#(Uri, Pending), LoginError)
pub fn parse_callback(params: List(#(String, String))) -> Result(Callback, CallbackParseError)
pub fn complete_login(Provider, Client, Pending, Callback) -> Result(Session, LoginError)
```

`complete_login` consumes a `Pending` obtained from `PendingStore.take`, so the compiler pushes callers toward single-use handling. State comparison happens **before** any network request.

### 4.5 Tokens and identity

```gleam
pub type Session { Session(tokens: Tokens, identity: Identity) }

pub type Tokens {
  Tokens(
    access: AccessToken,               // opaque; token.reveal(access) to obtain the string
    token_type: TokenType,             // Bearer | DPoP | OtherType(String); case-insensitive parse
    expires_at: Option(Timestamp),
    refresh: Option(RefreshToken),
    scopes: Option(List(Scope)),
    id_token_hint: Option(IdTokenHint),   // for logout only; not a trusted identity source
  )
}

pub opaque type Identity { ... }            // constructible only by a backend after verification
pub fn key(Identity) -> UserKey             // (issuer, sub): the ONLY stable identity key
pub fn subject(Identity) -> Subject
pub fn standard(Identity) -> StandardClaims // typed: email: Option(String), email_verified: Option(Bool), …
pub fn auth_time(Identity) -> Option(Timestamp)
pub fn acr(Identity) -> Option(String)
pub fn amr(Identity) -> List(String)
pub fn decode_claims(Identity, decode.Decoder(a)) -> Result(a, ClaimsError)   // custom claims
```

`UserKey` deliberately makes "key users by email" awkward; `email` is a claim, not an identity.

### 4.6 Other operations

```gleam
pub fn refresh(Provider, Client, Tokens) -> Result(Tokens, RefreshError)
pub fn client_credentials(Provider, Client, List(Scope)) -> Result(Tokens, TokenError)
pub fn userinfo(Provider, Client, Tokens, expected: Subject) -> Result(UserinfoClaims, UserinfoError)
pub fn introspect(Provider, Client, token: AccessToken) -> Result(Introspection, IntrospectError)
pub type Introspection { Active(IntrospectionClaims) | Inactive }
pub fn end_session_url(Provider, Client, LogoutRequest) -> Result(Uri, LogoutError)
// LogoutError includes NoEndSessionEndpoint when the OP does not advertise one.
```

`expected: Subject` is required so a caller cannot skip the userinfo `sub` check.

### 4.7 Errors

Closed variants, matched exhaustively by callers:

```gleam
pub type LoginError {
  ProviderUnavailable(ProviderError)
  AuthorizationDenied(code: AuthorizationErrorCode, description: Option(String))
  StateMismatch
  PendingExpired
  IssuerParamMismatch(expected: Issuer, got: String)
  TokenEndpoint(TokenEndpointError)          // enum of RFC 6749 §5.2 codes + Other(String)
  IdToken(IdTokenFailure)
  Backend(BackendError)                      // MalformedBackendResponse | Unmapped(String)
}
pub type IdTokenFailure {
  BadSignature UnsupportedAlg(String) NoneAlgRejected KeyNotFound
  Expired NotYetValid IssuerMismatch AudienceMismatch AzpMismatch
  NonceMismatch AtHashMismatch MissingClaim(String) Malformed
}
```

Error values never contain secrets or raw tokens. A test asserts that `string.inspect` of every error variant is free of secret material.

### 4.8 Pending store

```gleam
pub type PendingStore {
  PendingStore(
    put: fn(Pending) -> Result(PendingId, StoreError),
    take: fn(PendingId) -> Result(Option(Pending), StoreError),   // atomic, single-use
  )
}
```

`PendingId` is an opaque random 256-bit handle (goes in a signed cookie). Reference implementations: an ETS-backed actor, and a cookie-sealed store using AEAD from `kryptos`/`gleam_crypto` for stateless deployments. The `take`-once semantics is what defeats callback replay.

### 4.9 Backend interface (the seam)

```gleam
pub type Backend {
  Backend(
    start_provider:      fn(ProviderConfig) -> Result(BackendHandle, ProviderError),
    authorization_url:   fn(BackendHandle, Client, AuthorizationParams) -> Result(Uri, LoginError),
    exchange_code:       fn(BackendHandle, Client, AuthCode, ExchangeParams) -> Result(Session, LoginError),
    refresh:             fn(BackendHandle, Client, Tokens) -> Result(Tokens, RefreshError),
    client_credentials:  fn(BackendHandle, Client, List(Scope)) -> Result(Tokens, TokenError),
    userinfo:            fn(BackendHandle, Client, Tokens, Subject) -> Result(UserinfoClaims, UserinfoError),
    introspect:          fn(BackendHandle, Client, AccessToken) -> Result(Introspection, IntrospectError),
    end_session_url:     fn(BackendHandle, Client, LogoutRequest) -> Result(Uri, LogoutError),
  )
}
```

A record of functions is Gleam's idiom for this (no traits/behaviours). It is intentionally **high-level and effectful**: it returns verified results, so a future backend can implement it with a totally different internal structure (sans-IO, different HTTP client) without the facade caring.

### 4.10 Feature scope

Derived from oidcc's published feature list; gaps are called out explicitly rather than silently filled.

| Capability                                                       | v1            | Source                              |
| ---------------------------------------------------------------- | ------------- | ----------------------------------- |
| Discovery, JWKS auto-refresh                                     | ✅            | oidcc                               |
| Authorization code + PKCE + nonce                                | ✅            | oidcc + facade                      |
| Client auth: basic, post, `client_secret_jwt`, `private_key_jwt` | ✅            | oidcc                               |
| ID token validation                                              | ✅            | oidcc                               |
| Refresh token, client credentials                                | ✅            | oidcc                               |
| Userinfo (incl. JWT response)                                    | ✅            | oidcc                               |
| Introspection (RFC 7662)                                         | ✅            | oidcc                               |
| RP-Initiated Logout                                              | ✅            | oidcc                               |
| RFC 9207 issuer identification                                   | ✅            | oidcc **[VERIFY enforcement path]** |
| PAR (RFC 9126), Request Objects (JAR)                            | v1.1          | oidcc                               |
| DPoP (RFC 9449)                                                  | v1.1          | oidcc                               |
| JARM, FAPI 2.0 Security / Message Signing profiles               | v2 (optional) | oidcc                               |
| `jwt_bearer` grant                                               | v1.1          | oidcc                               |
| Dynamic client registration                                      | later         | oidcc                               |
| **Token revocation (RFC 7009)**                                  | ❌ gap        | not in oidcc's list **[VERIFY]**    |
| **Device authorization grant (RFC 8628)**                        | ❌ gap        | not in oidcc's list                 |
| **Token exchange (RFC 8693)**                                    | ❌ gap        | not in oidcc's list                 |
| **Back-/front-channel logout**                                   | ❌ gap        | oidcc lists only RP-initiated       |
| Implicit / hybrid / ROPC                                         | ⛔ excluded   | by design                           |

**Gap policy:** a gap stays unsupported, or is contributed upstream to oidcc, or — only if unavoidable — implemented as a small isolated module with its own external test sources and an explicit security review. We do not quietly grow a second protocol core.

### 4.11 Usage sketch (wisp, illustrative)

```gleam
pub fn login(req: Request, ctx: Context) -> Response {
  let request = login.AuthRequest(..login.default_request(), scopes: [scope.Profile, scope.Email])
  case warden.begin_login(ctx.provider, ctx.client, request) {
    Ok(#(url, pending)) -> {
      let assert Ok(id) = { ctx.store.put }(pending)
      wisp.redirect(uri.to_string(url))
      |> wisp.set_cookie(req, "warden_pending", store.id_to_string(id), wisp.Signed, 600)
    }
    Error(e) -> log_and_500(e)
  }
}

pub fn callback(req: Request, ctx: Context) -> Response {
  use params <- result.try(callback_params(req))            // query, or form body for form_post
  use cb <- result.try(warden.parse_callback(params) |> result.map_error(bad_request))
  use id <- result.try(pending_cookie(req))
  use pending <- result.try(take_pending(ctx.store, id))   // None → 400 (replay/expired)
  case warden.complete_login(ctx.provider, ctx.client, pending, cb) {
    Ok(session) -> start_app_session(identity.key(session.identity), session)
    Error(login.StateMismatch) -> wisp.bad_request()
    Error(e) -> log_and_401(e)
  }
}
```

### 4.12 Where strings remain (and why)

| String                                                             | Reason                                                                               |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------ |
| `Scope.Custom(String)`, `acr_values`, `login_hint`, `extra` params | Spec-open vocabularies                                                               |
| Custom claims                                                      | Accessed only through a caller-supplied `Decoder`, never as loose maps               |
| JWK JSON at the FFI boundary for `private_key_jwt` / DPoP          | oidcc consumes JWKs; wrapped in an opaque, redacted `SigningKey`                     |
| Opaque token values                                                | Opaque by definition; wrapped in `AccessToken`/`RefreshToken` with explicit `reveal` |

Everything else (URLs, algorithms, error codes, grant types, token types, prompts, response types) is a Gleam type.

---

## 5. Replaceability

### 5.1 Why we might replace oidcc

- A need for the **JavaScript target** or **zero-FFI** deployment.
- oidcc maintenance risk, OTP-version constraints, or a required feature it will not accept upstream.
- A wish to gain typed internals (e.g. injectable clock, sans-IO) that oidcc does not offer.

### 5.2 What makes it cheap

1. **The `Backend` record** is the only thing a new implementation must provide (§4.9). Application code never imports `oidcc`.
2. **Backend-agnostic tests**: contract and corpus suites take a `Backend` value (`contract.run(backend)`); conformance runs the reference RP through the public API only. A second backend must pass the _same_ suites unchanged.
3. **oidcc becomes the oracle**: the differential harness (V7) runs the same scenarios through both backends and fails on any accept/reject disagreement.
4. **Types encode semantics, not oidcc's shapes**: error taxonomy, `Identity`, `Tokens` are ours.

### 5.3 Candidate replacement stack

`gose` (typed JOSE, algorithm pinning, keys validated at construction) + `kryptos` (crypto) + `gleam_http`/`gleam_httpc` + our own discovery/JWKS cache actor. **gose is pure Gleam, requires OTP 27+ or Node 22+, does not support X.509 parameters or JWE compression, and is a young library** — it earns trust only by passing the same external suites, with oidcc/erlang-jose as differential oracles.

### 5.4 Migration procedure

1. Implement the new backend behind `Backend` (separate module or package).
2. Pass: contract suite → corpus suite → differential suite vs oidcc → OIDF conformance for the same profiles (results compared test-by-test against oidcc's).
3. **Shadow verification** in staging for side-effect-free operations only (ID-token/JWT validation, discovery parsing): run both backends, serve oidcc's result, log disagreements. Authorization codes are single-use and cannot be shadowed.
4. Flip the default in `provider.child_spec`; keep oidcc backend available for at least one release.
5. Remove only after a full release cycle without divergence.

---

## 6. Validation plan

Principle: **we adapt and drive externally-owned test assets; we do not author protocol expectations.** Where we write code, it is a harness or adapter.

### 6.1 V0 — Supply chain

- Exact pins + lockfile; CI fails on retired/vulnerable Hex packages; SBOM per release.
- Review oidcc and erlang-jose changelogs and security advisories on every bump.

### 6.2 V1 — Facade unit tests (Gleam)

Scope: only code we own.

- `Issuer.parse` accept/reject tables; `RedirectUri` rules.
- `parse_callback`: duplicates, code+error together, missing state, empty values, `iss` variants; property tests (qcheck) for arbitrary parameter lists — no crash, deterministic classification.
- `Pending`: TTL, single-use through `PendingStore`, state constant-time compare (behavioural check + code review).
- **PKCE**: RFC 7636 Appendix B vector through injected `Entropy`; verifier length/charset properties.
- **Error mapping golden tests**: enumerate every error reason oidcc can return (from its dialyzer types/source) and assert a mapping exists; unknown reasons must hit `Unmapped`, never `Ok`.
- Redaction: `string.inspect` of every error and of `Client` contains no secret.
- FFI decoders: fuzz with arbitrary Erlang terms; must return `Error`, never crash.

### 6.3 V2 — OpenID Foundation conformance suite (primary gate)

The suite acts as a fake OP and the RP under test performs real flows against it, including negative tests where the OP returns invalid data (e.g. an ID token signed with the wrong algorithm) and the RP must reject it.

**Reference RP app** (`conformance/`): a minimal Gleam web app built **only on the public API** (no backdoors), exposing login start, callback, form_post callback, third-party-initiated login, and RP-initiated logout endpoints.

**Profiles to run** — those oidcc itself is certified for: Config RP, Basic RP, Form Post RP, 3rd-party-initiated RP, RP-Initiated Logout RP. Optional later: FAPI RP plans, and the non-certification "relying party tests" plan for extra configurations.

**Harness**: an HTTP driver with a cookie jar that starts each test in the suite, calls the RP's entry point, follows redirects, and fetches the suite's log/result for each test. We model it on two existing automations rather than inventing one: `erlef/oidcc_conformance` (oidcc's own) and `panva/openid-client-conformance-tests`. **[VERIFY: real browser is not required for the RP plans.]**

**Local vs hosted**: a local suite instance is fine for CI and internal use (self-signed certs; the RP's TLS policy needs a test-only trust anchor injected via config, not by weakening defaults). Results from a local instance cannot be used for certification; only the hosted suite counts.

**Acceptance criteria**

- Every test in each profile PASSES, or is documented as WARNING/SKIPPED with the _same_ status as in oidcc's submitted certification logs (the `oidcc_conformance` repo stores those).
- Logs are archived as CI artifacts per release.

**Certification claim policy**: "built on an OpenID-certified library" is accurate. "Certified" applies only if we submit our own run to the hosted suite for a specific version (check current OIDF fee/membership terms).

### 6.4 V3 — Crypto / JOSE assets (only where we touch them)

oidcc/erlang-jose own JOSE correctness. We validate only what the facade or shim does:

- `private_key_jwt` assertion generation, verified by an independent verifier (panva/jose in Node) in the interop rig.
- If DPoP is enabled: RFC 9449 example vectors.
- Wycheproof (Google) and RFC 7515/7517/7520 vectors become mandatory **only** when a native backend/gose is introduced (§5), run against it.

### 6.5 V4 — Behavioural equivalence with raw oidcc ("transparency" tests)

A shared **scenario corpus** (data files, not code): valid token; bad signature; `alg: none`; HS/RS confusion; unknown `kid` then JWKS rotation; wrong `iss`/`aud`/`azp`; expired / not-yet-valid; nonce missing/mismatch; `at_hash` mismatch; missing `sub`; oversized/garbage responses; token endpoint errors.
Each scenario runs (a) directly against oidcc from an Erlang test module and (b) through the facade. Assert equivalent accept/reject class and mapped error. This proves the facade neither weakens nor accidentally strengthens oidcc's behaviour, and it is the same corpus the future backend must satisfy.

### 6.6 V5 — Interoperability with real OPs

Containers (Testcontainers or docker compose): Keycloak, Ory Hydra, Dex, `panva/node-warden-provider` (scriptable, itself certified), and a scriptable mock OP (e.g. navikt `mock-oauth2-server`) for failure injection.
Recorded discovery + JWKS fixtures (no secrets in CI) for Google, Microsoft Entra (multi-tenant issuer templating), Okta, Auth0 to catch metadata quirks. Optional nightly job against live test tenants using dedicated, low-privilege apps.
Ported cases from oidcc's own fixtures (`priv/test/fixtures`) and, where relevant, `assent`, subject to license review (oidcc is Apache-2.0) with attribution.

### 6.6b V5b — Attack matrix (from RFC 9700, the OAuth Security BCP)

Each row is a named, automated test using the mock OP and the reference RP.

| Threat                                                  | Expected behaviour                                                                          |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| CSRF / login CSRF (wrong or missing `state`)            | `StateMismatch`, no network call made                                                       |
| Authorization-code replay against RP                    | `PendingStore.take` returns `None` on second use                                            |
| Code injection / PKCE downgrade (OP ignores verifier)   | Exchange fails; RP never accepts a session                                                  |
| Mix-up (`iss` response param differs)                   | `IssuerParamMismatch`                                                                       |
| Token substitution (ID token for other `aud`/`azp`)     | `IdToken(AudienceMismatch)` / `AzpMismatch`                                                 |
| Replayed ID token (wrong `nonce`)                       | `IdToken(NonceMismatch)`                                                                    |
| Algorithm confusion, `alg: none`                        | `IdToken(NoneAlgRejected)` / `UnsupportedAlg`                                               |
| Redirect URI manipulation                               | Rejected client-side config validation; OP rejection surfaces as typed error                |
| Malicious metadata (issuer mismatch in discovery doc)   | Provider start fails / stays unavailable                                                    |
| SSRF via discovery/JWKS URLs pointing at internal hosts | Blocked by `HttpPolicy` (private/loopback ranges denied by default) **[VERIFY hook point]** |
| Self-signed / wrong-host TLS on OP                      | Connection rejected                                                                         |
| Duplicate callback parameters (`code=a&code=b`)         | `DuplicateParameter`                                                                        |

### 6.7 V6 — Non-functional

Provider worker crash/restart; concurrent JWKS refresh under load; timeout and oversize-response handling; no secret leakage in logs (log-capture assertions); memory/atom-table growth check on repeated provider starts.

### 6.8 V7 — Contract + differential suite (for future backends)

`contract.run(backend)` executes V1-adjacent behavioural tests and the V4 corpus for any `Backend` value; a differential runner executes two backends side by side and fails on any disagreement.

### 6.9 Release gates and upgrade playbook

| Gate | Blocks release if…                                                                      |
| ---- | --------------------------------------------------------------------------------------- |
| V0   | unpinned/retired/advisory-flagged dependency                                            |
| V1   | any failure                                                                             |
| V2   | any conformance regression vs the previous release or vs oidcc's certification baseline |
| V4   | any divergence from raw oidcc without an approved, documented reason                    |
| V5b  | any attack row fails                                                                    |
| V5   | any supported-OP interop failure                                                        |

**oidcc bump playbook**: bump pin → compile shim → V1/V4 → V2 conformance run → diff results against the previous run → read changelog/security notes → tag.

### 6.10 Traceability (feature → assets)

| Feature                                      | Primary external asset                              | Ours                            |
| -------------------------------------------- | --------------------------------------------------- | ------------------------------- |
| Code flow, ID-token validation               | OIDF Basic/Config RP plans                          | reference RP                    |
| Form post                                    | OIDF Form Post RP plan                              | form_post endpoint              |
| 3rd-party initiated login                    | OIDF 3rd-party-init plan                            | `iss`/`target_link_uri` handler |
| RP-initiated logout                          | OIDF RP-Initiated Logout plan                       | logout endpoint                 |
| PKCE                                         | RFC 7636 App. B                                     | entropy injection               |
| Refresh / client credentials / introspection | Keycloak, Hydra, Dex, node-warden-provider          | interop tests                   |
| `private_key_jwt`, DPoP                      | independent verifier (panva/jose), RFC 9449 vectors | key-handling tests              |
| Attack resistance                            | RFC 9700 threat list                                | V5b matrix                      |

---

## 7. Security requirements checklist

- [ ] PKCE S256 and `nonce` on every authorization request; no API to disable.
- [ ] `state` ≥ 128 bits from a CSPRNG; constant-time comparison; single-use via atomic `take`.
- [ ] Issuer must be `https` (loopback exception only through `unsafe_*` constructor).
- [ ] ID-token `alg` pinned from provider/client configuration, never from the token header; `none` rejected.
- [ ] Explicit TLS verification, bounded timeouts and response sizes for discovery, JWKS and token requests; SSRF deny-list default.
- [ ] Secrets and tokens are opaque, never logged, never in error values.
- [ ] Identity key is `(iss, sub)`; email is never an identifier.
- [ ] Facade never re-implements a check oidcc performs; deviations are documented in §3.3.
- [ ] Pending TTL enforced in facade and store.
- [ ] No `let assert`/`panic` in library code paths reachable from network input (CI lint).
- [ ] Reference cookie store uses AEAD with key rotation; signed cookies only as a fallback.

---

## 8. Roadmap

| Milestone       | Deliverable                                                                                      | Exit criterion                                              |
| --------------- | ------------------------------------------------------------------------------------------------ | ----------------------------------------------------------- |
| **M0**          | Spikes S1–S5 (§9)                                                                                | Responsibility matrix (§3.3) fully resolved; Q1–Q4 answered |
| **M1**          | Package skeleton, shim, `Provider`, `begin_login`/`complete_login`, `PendingStore`, V0/V1        | Round trip against Keycloak in CI                           |
| **M2**          | Reference RP + conformance harness; Basic, Config, Form Post, 3rd-party-init                     | All tests match oidcc baseline                              |
| **M3**          | Refresh, userinfo, introspection, client credentials, RP-Initiated Logout; V4 corpus; V5b matrix | RP-Initiated plan green; attack matrix green                |
| **M4**          | `private_key_jwt`, PAR, JAR, DPoP; interop matrix (V5)                                           | Independent-verifier tests green                            |
| **M5**          | Hardening (V6), docs, examples, mock backend, 1.0                                                | All release gates green                                     |
| **M6 (opt.)**   | JARM / FAPI 2.0 profiles                                                                         | FAPI RP plans green                                         |
| **M7 (future)** | Native backend spike on gose behind `Backend`                                                    | Contract + differential suites green                        |

---

## 9. Risks, open questions, verification backlog

### Spikes (M0)

- **S1 — oidcc source audit.** For each row of §3.3 marked oidcc/[VERIFY], read the code path and record file/function. Especially: nonce enforcement, RFC 9207 `iss` handling, `at_hash`/`azp` behaviour, refresh-response ID-token rules, how `alg` is pinned, request options for TLS/timeouts/size caps, SSRF hook point.
- **S2 — API surface pin.** Enumerate oidcc's exported functions for the pinned version (client-context construction, redirect creation, token retrieval/refresh/client-credentials, userinfo, introspection, logout URL, DPoP/PAR options) and write the shim against them. Names in this document are indicative.
- **S3 — Harness feasibility.** Run the OIDF suite locally in Docker; drive one Basic RP test with a minimal Gleam app and a scripted HTTP client; confirm no real browser needed.
- **S4 — Gap check.** Confirm whether revocation, device grant, token exchange and back-channel logout exist in the pinned oidcc; decide policy per §4.10.
- **S5 — Error catalogue.** Extract all error reasons from oidcc to seed the golden mapping test.

### Open questions

- **Q1.** Which OIDF profiles must we _claim_ (vs merely pass)? Decides whether to pursue our own certification.
- **Q2.** Is time injectable in oidcc (beyond clock-skew tolerance)? If not, tests rely on real-time fixtures and the native backend later adds an explicit `now`.
- **Q3.** Package split: a separate `warden_backend_native` package cannot construct opaque `Identity`/`Tokens`. Options: keep one package; or expose constructors from an `internal` module (verify the pinned Gleam compiler's enforcement and add a CI lint).
- **Q4.** Is `gleam_otp`'s supervision API stable enough to expose `child_spec` typed directly, or do we wrap it?
- **Q5.** Resource-server use (validating API access tokens): use oidcc introspection only, or also local JWT validation (would need oidcc's JWT-validation entry point, or gose)? Keep behind the same `Backend`.

### Risks

| Risk                                               | Mitigation                                                                                     |
| -------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Upstream deprecation/slowdown of oidcc             | Seam + contract suites + native-backend path (§5); track health each release                   |
| Facade weakens oidcc by mis-mapping options        | V4 transparency tests; minimal shim; matrix in §3.3                                            |
| Conformance suite drift (new plans/versions)       | Pin suite version in CI; scheduled upgrade job                                                 |
| Certification confusion (claims we cannot support) | Claim policy in §6.3                                                                           |
| Gleam ecosystem churn (`gleam_otp`, `wisp`)        | Keep framework code in examples/adapters, core depends on stdlib + erlang/otp/http/crypto only |

---

## 10. References

- oidcc (features, certification, security audit, OTP27 minimum): https://github.com/erlef/oidcc · https://hexdocs.pm/oidcc
- oidcc conformance harness and submitted certifications: https://github.com/erlef/oidcc_conformance
- OpenID certified implementations list (oidcc 3.0.0 profiles): https://openid.net/developers/certified
- OIDF RP conformance testing (suite acts as OP): https://openid.net/certification/connect_rp_testing/
- OIDF logout RP testing: https://openid.net/certification/logout_rp_testing/
- OIDF FAPI RP testing (local vs hosted): https://openid.net/certification/fapi_rp_testing/
- Example per-library automation: https://github.com/panva/openid-client-conformance-tests
- erlang-jose: https://github.com/potatosalad/erlang-jose
- gose (Gleam JOSE/COSE): https://hexdocs.pm/gose
- glow_auth (Gleam OAuth 2 helpers): https://hexdocs.pm/glow_auth
- Boruta (Elixir provider core, for AS-side reference): https://github.com/malach-it/boruta_auth
- Assent (Elixir multi-provider, quirks reference): https://github.com/pow-auth/assent
- RFC 6749, 7009, 7636, 7662, 8628, 8693, 9126, 9207, 9449, 9700; OpenID Connect Core 1.0, Discovery 1.0, RP-Initiated Logout 1.0
