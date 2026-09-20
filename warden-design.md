# Warden — typed OIDC relying party and OAuth client

## 1. Purpose, scope, and status

- Warden provides a typed Gleam OIDC relying party and OAuth client on Erlang/OTP 27+. The default implementation must reuse pinned `oidcc` through a narrow Erlang boundary rather than implement a second protocol or cryptographic core.
- This design consolidates the baseline at `9194f02` with transaction, verification, custody, and refresh findings. The initial [public facade](PUBLIC-API.md) does not remove broader [coverage](API-COVERAGE.md#warden); unimplemented operations remain requirements rather than completed APIs.
- Required baseline operations remain discovery, authorization-code login, refresh, client credentials, userinfo, introspection, and RP-initiated logout. Later protocol families and explicit gaps retain their separate dispositions in §4.8.
- Authorization-server implementation, implicit/hybrid/password flows, and JavaScript runtime support remain excluded from the initial package. A social-provider quirks catalog remains optional later work, with Assent as a reference rather than the default backend.
- Historical upstream certification does not certify Warden or the selected newer backend version. Scripted attestations and storage histories establish interface behavior only.

## 2. Design principles and ownership

- Delegate backend protocol checks to `oidcc`; implement missing caller obligations in one canonical Warden owner. Document every deliberate stricter policy and test its option mapping.
- Decode foreign terms at one boundary and expose typed outcomes. Public claim maps, token strings, or adapter attestations must not directly construct verified identity.
- Opacity establishes constructor ownership within a configured trust model. It does not establish cryptographic correctness, honest adapters, secret erasure, or linear consumption of copyable values.
- Warden owns web identity and session custody. [Relay](relay-design.md) owns MCP bearer grants, resource authorization, and MCP-specific client discovery; a Warden identity is not a Relay grant.
- Ordinary identity, token, and session JSON uses standard Gleam JSON encoders/decoders, with any reusable codec abstraction independent of schemas. [Blueprint](blueprint-design.md) is needed only when a particular integration requires JSON Schema; serialized state alone does not require it. Warden retains identity, token, provider, and session semantics without introducing a universal identity or persistence protocol.
- The backend remains replaceable through typed operation contracts. Protocol expectations come from external specifications, vectors, upstream fixtures, and conformance assets; Warden-specific orchestration and ownership need their own tests.

## 3. Target design

### 3.1 Package, modules, and processes

- One Erlang-target Hex package contains provider/client configuration, login transactions, identity, tokens, session custody, refresh, errors, stores, entropy, and backend adapters. Framework handlers remain examples or thin adapters.
- One named Erlang boundary performs `oidcc` argument conversion, record flattening, exception containment, and sanitized error classification. The baseline approximate 300-line target is a review constraint, not permission to omit required HTTP ownership or security handling.
- The provider configuration worker owns discovery, metadata refresh, and JWKS refresh under supervision. Provider handles remain opaque; unavailable workers return typed errors rather than panics.
- Registered names are allocated once at trusted startup and never by converting request strings to atoms. Supervisor child-spec exposure remains subject to the selected `gleam_otp` API.
- Login transaction storage and session custody have distinct owners and protocols. Neither a live process handle nor a copyable checked callback substitutes for durable storage authority.

### 3.2 Configuration and authorization planning

- Issuer configuration requires an absolute HTTPS URI with no query or fragment and exact issuer matching. Any loopback-only HTTP test constructor must be explicit; production configuration must exclude issuer-regex quirks.
- Redirect configuration requires an absolute URI without a fragment, HTTPS except for a defined loopback policy, and exact reuse through authorization and exchange. The prototype's nonempty string constructors do not yet establish those rules.
- Client authentication retains public-client, secret-basic, secret-post, secret-JWT, and private-key-JWT alternatives. Secrets and signing keys remain opaque with explicit trusted-adapter access and redacted errors.
- Provider configuration retains client identity, allowed signing algorithms, HTTP limits, TLS policy, metadata/JWKS refresh policy, and the supervised provider binding. Algorithms must come from configured policy rather than untrusted token headers; `none` must reject.
- Authorization options retain scopes, prompt, maximum authentication age, login hint, ACR values, UI locales, and permitted extension parameters. `openid` is added for login; extension parameters must not override reserved names.
- Login planning creates independent material for concurrent tabs and issuers. It binds transaction identifier, issuer, client, redirect, state, nonce, PKCE verifier/challenge, creation time, and expiry.
- State and nonce use trusted cryptographic entropy; the baseline state target is 256 bits and must never fall below its 128-bit security requirement. PKCE uses 32 random bytes encoded as a 43-character base64url verifier, with S256 derived from that same verifier.
- Authorization output exposes the challenge rather than the verifier. PKCE S256 and nonce are mandatory for login; weaker defaults must not be inferred from backend permissiveness.
- Pending lifetime retains the baseline ten-minute default with explicit policy. Production entropy, challenge derivation, URL construction, browser binding, and clock behavior remain obligations beyond injected laboratory material.

### 3.3 Responsibility matrix and pinned verification policy

| Responsibility                                                        | Owner                                         | Required contract                                                                          |
| --------------------------------------------------------------------- | --------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Discovery, metadata and JWKS refresh                                  | `oidcc` worker through bounded HTTP           | Exact issuer and configured transport policy                                               |
| State, nonce, PKCE material, transaction binding                      | Warden                                        | Trusted entropy, S256, exact retained values                                               |
| Callback parsing and RFC 9207 issuer comparison                       | Warden                                        | Validate before consumption/exchange; backend receives a code rather than the raw callback |
| Authorization URL, code exchange, client authentication               | `oidcc` adapter                               | Exact configured provider, redirect, client, verifier, and nonce                           |
| Signature, algorithm, issuer, audience, time, nonce, authorized party | `oidcc` with explicit Warden options          | Required ID token and strict audience profile                                              |
| Access-token hash                                                     | `oidcc`                                       | Conditional check when `at_hash` and access token are present                              |
| Identity construction and session installation                        | Warden canonical owner                        | Accepted binding checks and confirmed custody receipt                                      |
| Userinfo subject continuity                                           | Backend call configured by Warden             | Required expected subject                                                                  |
| Refresh serialization, rotation, publication                          | Custody owner plus configured refresh adapter | Owner/provider binding, exact revision/command receipts, uncertainty retention             |
| TLS, SSRF, limits, redaction, exception mapping                       | Configured adapter boundary                   | Explicit runtime tests; never assumed from upstream defaults                               |

- The pinned login adapter supplies retained `redirect_uri`, nonce, and verifier with `require_pkce: true`, `trusted_audiences: []`, and `validate_azp: client_id`. It requires an ID token before returning an identity attestation.
- `require_pkce: true` alone permits backend metadata supporting plain PKCE; Warden must establish S256 during authorization planning. The backend nonce default is `any`, so omission of the retained nonce would weaken validation.
- The first audience profile accepts exactly the configured client, with a matching authorized party when present. Multiple audiences require an explicit later policy defining mandatory authorized-party behavior.
- The pinned path validates signature, configured algorithms, exact issuer, audience, expiry, not-before, required claims, nonce, and a present authorized party. `at_hash` remains conditional rather than an unconditional response property.

### 3.4 HTTP, FFI, and secret handling

- Pin `oidcc = "3.9.0"` and its resolved dependencies with a committed lockfile. Shim function names and arities, option maps, return shapes, and error mappings must be tested against that exact backend.
- Foreign decoding must reject malformed shapes without crashing. Foreign exceptions and exits require explicit containment at supported boundaries; no unexpected backend term may become success.
- Error mapping matches closed outer shapes and discards embedded response bodies, claims, tokens, and arbitrary terms. Unknown failures become sanitized unmapped errors without a generic term formatter, replacing the baseline's unsafe `Unmapped(String)` diagnostic intent.
- Errors and observations must exclude authorization codes, state, nonce, verifier, client secrets, tokens, raw claims, and formatted foreign terms. Audit fields are limited to nonsecret identifiers, classifications, and timing.
- Opaque wrappers do not prevent VM inspection or crash dumps. Runtime logging, crash-dump policy, trusted adapter views, and secret storage remain explicit operational responsibilities.
- HTTP configuration must pass peer verification, system trust anchors, hostname checking, and bounded timeout through the pinned request options. Test providers use explicit trusted-CA configuration rather than disabling verification.
- Discovery, JWKS, token, and other provider responses require size bounds and SSRF policy. Default buffered HTTP behavior does not prove limits before allocation, and a request-options map does not by itself prove private-address or redirect rejection.
- The malicious-provider harness must test private endpoints, DNS rebinding, cross-host redirects, oversized fixed/chunked bodies, timeout, invalid certificates, unknown-key refresh, and malformed adapter returns. If the selected seam cannot reject before connection and body allocation, use a bounded custom HTTP adapter or separately owned discovery/JWKS retrieval while retaining `oidcc` protocol/JOSE reuse.
- Private signing material may cross the trusted FFI boundary in the required JWK representation. That boundary conversion does not authorize exposing it in ordinary public errors or application context.

## 4. Public operations and internal ownership contracts

### 4.1 Callback parsing and checked transactions

- Raw query and form-post parsing must reject duplicates, missing required values, empty codes, ambiguous code-plus-error responses, and invalid shapes. Issuer-less callbacks require explicit provider policy rather than assumed acceptance.
- Stored transactions bind immutable material to a revision. A store must never reuse a revision after changing that material.
- Callback checking compares state in constant time and issuer against the stored binding before any network request. An invalid state or issuer must not consume the legitimate transaction.
- A checked code or checked denial retains transaction identity, revision, expiry, and private binding material. Neither value is a verified identity or proof of consumption.
- Correctly bound provider denial consumes the transaction terminally without invoking exchange. Raw provider error descriptions do not become secret-bearing public diagnostics.

### 4.2 Atomic consumption and exchange

- Consumption is a store-owned atomic operation: acquire the critical section, load the current record, inspect status/revision, sample the clock, decide, and commit. No caller timestamp may substitute for the locked clock sample.
- A matching terminal consumed record takes precedence over revision comparison so a losing callback reports replay rather than an unrelated revision change. A pending revision mismatch rejects before expiry or mutation.
- A matching pending transaction is valid only while `now < expires_at`; equality rejects. Confirmed consumption changes it to terminal before the token request begins.
- Bounded terminal records distinguish replay and expiry from missing storage. Missing record, unavailable storage, and unknown commit remain distinct outcomes; none authorizes exchange.
- The high-level login operation rejects a differently bound backend before accessing the store. It privately creates the exchange request only after confirmed consumption, using the exact consumed transaction and checked code.
- Public consumption exposes sanitized disposition without a secret-bearing exchange capability. Copyable checked values cannot enforce single use; concurrent storage must admit exactly one backend invocation.
- Exchange binds provider, exact issuer, client authentication, redirect, code, nonce, and verifier. Callback state is absent because Warden already checked it against that revision.
- A known endpoint rejection, identity rejection, or uncertain exchange leaves the transaction consumed. Warden never restores pending state or silently repeats a possibly transmitted code.
- Generic `oidcc` HTTP failure does not prove no transmission and maps conservatively to unknown exchange outcome. Connection retry is permitted only with proven no-send evidence; the initial consumed-login contract otherwise requires a new login even after proven provider unavailability.

### 4.3 Identity, tokens, claims, and session custody

- A configured verification adapter returns a public attestation rather than constructing identity. Warden validates shape and original issuer/client/audience/subject bindings before its canonical module issues opaque identity.
- The production constructor binds the pinned `oidcc` path. Explicit custom-adapter configuration records adapter identity and purpose; labels alone cannot prove an adapter honest or enforce a production/test barrier.
- Stable identity uses `(issuer, subject)`; email remains an optional claim. Standard claims, authentication time, ACR, AMR, and caller-decoded custom claims remain required public data capabilities.
- Access tokens, refresh tokens, and logout-only ID-token hints remain distinct types. Session exposes confirmed custody references and identity rather than a general token accessor; trusted adapter views support storage and request construction.
- Token response contracts retain token type, expiry, granted scopes, optional refresh material, and original authentication evidence. Token type remains extensible where the protocol is open; missing expiry is not fabricated.
- Scope validation preserves case and rejects invalid delimiters or bytes. The demonstrated ASCII scope profile does not settle every provider-specific scope or expiry policy.
- Custody installation retains the exact verified identity, provider binding, authentication evidence, and tokens under one stable command. A usable session requires an accepted-command receipt matching owner, command, material, identity, reference, and revision.
- Uncertain installation returns owner-bound recovery for the same command and material. Recovery never repeats authorization-code exchange, and a contradictory receipt cannot resolve it.
- The store must serialize installation and return stable history when an accepted command is retried. Scripted immutable ledgers do not prove durable atomicity, encryption, redaction, or concurrent installation.

### Current login and custody declarations

- Code below is a current prototype declaration excerpt: constructor definitions and function signatures retain the linked source module’s names and aliases; function bodies and unrelated declarations are omitted. These excerpts are not standalone modules or published package signatures, and no new compilation or runtime claim follows from this documentation pass.
- [The canonical transaction module](playground/interface_lab/src/lab/warden_transaction.gleam) owns these types. [Verified login](playground/interface_lab/src/consumers/verified_login.gleam) and [session custody](playground/interface_lab/src/consumers/session_custody.gleam) exercise configured assertions and exact installation receipts; they do not invoke the production `oidcc` adapter.
- `complete_login` requires a custody owner and returns `LoginCompletion`, rather than returning a Session immediately after a backend assertion. Recovery accepts the custody command and cannot replay the consumed authorization-code exchange. These laboratory protocol entry points remain internal design evidence under the freeze.

```gleam
pub type LoginCompletion {
  LoginCompleted(Session)
  LoginRecoveryRequired(CustodyRecoveryCommand)
}

pub fn complete_login(
  store: TransactionStore,
  backend: VerificationBackend,
  custody_owner: CustodyOwner,
  checked: CheckedOutcome,
) -> Result(LoginCompletion, CompleteLoginError)

pub fn recover_custody(
  owner: CustodyOwner,
  recovery: CustodyRecoveryCommand,
) -> Result(CustodyRecoveryResult, CustodyRecoveryError)
```

### 4.4 Custody-owned refresh

- Refresh begins from the session's custody owner, provider binding, reference, revision, and original authentication evidence. It must reject a different owner or provider before calling a refresh port.
- Reservation binds the expected revision and caller command identifier. Only a matching newly issued dispatch authorizes the provider call; pending, competing, recorded, or uncertain replies do not authorize another dispatch.
- Missing refresh material is a typed rejection. Custody material is a trusted stored fact, not independently authenticated by possession of a Session value.
- Proven no-send, definite endpoint rejection, uncertain transmission, and successful attestation remain distinct outcomes. Known settlement requires an exact recorded receipt; command replay returns recorded outcome rather than repeating the provider request.
- Unknown provider outcome quarantines the token generation because the provider may have rotated it. Invalid successful output also requires reconciliation rather than releasing the predecessor for ordinary retry.
- An absent refreshed ID token preserves established identity without creating a new authentication event. Present evidence must retain issuer, subject, audience, and applicable original nonce/authentication-time continuity under the selected profile.
- Omitted refresh token retains current material; explicit replacement supersedes it. The demonstrated profile requires returned scopes to remain unchanged and compares them as case-sensitive sets rather than ordered lists.
- That unchanged-scope profile and its original-identity checks are selected prototype policy, not the complete OAuth response vocabulary. Broader permitted scope transitions and authentication-evidence profiles remain retained operation requirements requiring explicit policy and external fixtures; neither this profile nor the pinned absent-ID-token limitation silently narrows future backend capability.
- Publication commits access material and replacement refresh material together, bound to exact dispatch and expected revision. A valid receipt retains the session reference, matches the command, and advances the revision before a new Session is issued.
- Lost or contradictory publication acknowledgement retains the exact owner-bound recovery command. Publication recovery must not call the provider; reservation recovery has a different type and cannot silently clear quarantine or authorize redispatch.
- Automatic recovery from uncertain reservation remains unresolved where dispatch authority cannot be established. Reconciliation, reauthentication policy, and retry hints require explicit behavior rather than inference from opaque values.
- The pinned `oidcc` refresh overload requires expected subject and rejects an absent returned ID token as `sub_invalid`. This is narrower than OIDC's permitted response vocabulary, so the default adapter must declare that limitation.
- The pinned refresh path sets `nonce: any`; Warden must separately retain and check relevant original continuity evidence. Its response extraction also omits absent refresh material, so custody must explicitly distinguish retain from replace.
- A scripted alternative exercises absent-ID-token refresh without proving default adapter support. Run the shared response corpus through the actual pinned adapter before choosing a production alternative; never fabricate ID-token evidence to hide the mismatch.

### Current refresh result and recovery declarations

- [The same transaction owner](playground/interface_lab/src/lab/warden_transaction.gleam) defines a separate `RefreshBackend` and phase-specific recovery types. [The refresh consumer](playground/interface_lab/src/consumers/session_refresh.gleam) models reservation, rotation, quarantine, and publication; [the negative recovery consumer](playground/interface_lab/negative/refresh_recovery_phase.gleam) rejects reservation recovery as publication recovery.
- These declarations preserve uncertainty explicitly without proving atomic storage or transport classification. Their unchanged-scope profile and scripted absent-ID-token capability do not narrow the broader requirements or establish pinned `oidcc` support.

```gleam
pub type RefreshResult {
  RefreshCompleted(Session)
  RefreshDidNotSend
  RefreshRejectedByEndpoint
  RefreshProviderQuarantined(RefreshReservationRecovery)
  RefreshResponseQuarantined(RefreshValidationError, RefreshReservationRecovery)
  RefreshReservationUnresolved(RefreshReservationRecovery)
  RefreshPublicationUnresolved(RefreshPublicationRecovery)
}

pub fn refresh_session(
  owner: CustodyOwner,
  backend: RefreshBackend,
  session: Session,
  command_id: RefreshCommandId,
) -> Result(RefreshResult, RefreshError)

pub fn recover_refresh_publication(
  owner: CustodyOwner,
  recovery: RefreshPublicationRecovery,
) -> Result(RefreshResult, RefreshError)
```

### 4.5 Remaining provider operations

- Client credentials must return typed token outcomes independently of login identity. Its scopes, authentication method, expiry, errors, and custody policy remain operation-specific requirements.
- Userinfo must require expected subject and reject a response whose subject differs. JSON and JWT userinfo responses remain retained backend capabilities requiring exact adapter tests.
- Introspection distinguishes active claims, inactive token, and transport/backend failure. Introspection does not itself authorize a Relay resource or establish a web login.
- RP-initiated logout retains typed request configuration, logout-only ID-token hints, and an explicit missing-end-session-endpoint outcome. Local session/custody disposition and provider logout behavior require separate tests.
- Third-party-initiated login and form-post callbacks remain required reference-RP paths, including issuer and target-link handling. The initial parsed callback facade does not establish their HTTP behavior.
- Each operation needs an independent consumer, typed error family, exact pinned call mapping, and provider fixtures. General backend effectful functions must not collapse their distinct authority or retry rules.

### 4.6 Stores and application integration

- Transaction storage retains an ETS-backed reference target and a durable-store port with atomic revision/status/expiry checks. Browser cookies may carry an opaque random transaction reference under application session policy.
- The baseline cookie-sealed store requires authenticated encryption and key rotation if pursued. Encryption alone cannot establish atomic take-once replay prevention; a stateless-only cookie implementation must not claim the demonstrated store contract without a shared replay authority.
- Applications may install confirmed identity and session references in their own sessions and pass identity through request-scoped tools. Browser binding, persisted custody restoration, session expiry, revocation, and logout remain runtime obligations.
- Storage ports, commands, receipts, and recovery values are internal design evidence until runtime implementation validates them. Laboratory visibility does not promote unfinished protocol machinery into the frozen public API.

### 4.7 Error contracts

- Login distinguishes malformed callback, binding mismatch, expiry, replay, changed revision, storage failure, unknown commit, provider denial, definite exchange rejection, uncertain exchange, and rejected identity.
- Token validation retains specific sanitized categories for bad signature, unsupported/none algorithm, missing key, issuer/audience/authorized-party mismatch, expiry/not-before, nonce, access-token hash, missing claims, and malformed response.
- Provider, refresh, userinfo, introspection, logout, and custody errors remain distinct where their recovery consequences differ. Unmapped backend failure and foreign exception never become success or include formatted raw values.
- No network-reachable library path may rely on panic or unchecked assertion for malformed input. Scripted panic sentinels prove call ordering only; actual exception containment still requires runtime tests.

### 4.8 Full capability disposition

| Baseline capability                                                  | Disposition                                                            | Remaining evidence or friction                                                          |
| -------------------------------------------------------------------- | ---------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Discovery and JWKS auto-refresh                                      | Retained `oidcc` reuse                                                 | Bounded HTTP, provider supervision, rotation, SSRF, and malformed metadata tests        |
| Code flow, S256, nonce, state, RFC 9207                              | Retained; pure transaction/consumption partially demonstrated          | Entropy, challenge derivation, parsing, browser binding, exact FFI options, concurrency |
| Basic/post/secret-JWT/private-key-JWT client authentication          | Retained                                                               | Configuration and independent assertion verification                                    |
| ID-token validation, typed identity, claims                          | Retained                                                               | Concrete `oidcc` adapter and external crypto/claim oracles                              |
| Tokens and sessions                                                  | Retained with custody ownership replacing public token bags            | Exact installation, redaction, expiry, durable restoration                              |
| Refresh                                                              | Retained with reservation, rotation, quarantine, publication, recovery | Atomic owner, actual adapter, absent-ID-token limitation, reconciliation                |
| Client credentials, userinfo including JWT, introspection, RP logout | Retained required operations                                           | Independent typed consumers and runtime provider cases remain open                      |
| PAR, JAR, DPoP, JWT-bearer grant                                     | Retained later capability slices                                       | Pinned backend mapping and respective external suites                                   |
| Dynamic registration                                                 | Retained later scope                                                   | Configuration, provider compatibility, and external evidence                            |
| JARM and FAPI 2.0 security/message-signing                           | Retained optional later scope                                          | Profile-specific conformance required                                                   |
| Revocation, device grant, token exchange, back/front-channel logout  | Retained explicit gaps                                                 | Verify backend support; remain unsupported until an explicit growth decision            |
| Implicit, hybrid, password flows; JS runtime                         | Baseline exclusions retained                                           | No implied support from backend capability                                              |
| Replaceable backend and application mock                             | Retained                                                               | Same operation contracts and external corpus, explicit custom trust                     |
| Stateless cookie-only single use                                     | Unsupported security inference removed                                 | AEAD does not prove shared replay prevention                                            |
| Resource-server authorization                                        | MCP policy assigned to Relay; introspection remains Warden             | Verified web identity and resource grant are distinct authorities                       |

## 5. Backend replaceability

- Applications depend on Warden operations rather than `oidcc` records. Verification and refresh use separately configured contracts; remaining provider operations extend the seam without allowing arbitrary backend identity construction.
- A replacement must pass the same operation contracts, external corpus, differential tests, and selected conformance profiles. Deliberate Warden restrictions must be documented so a difference from permissive raw defaults is not misclassified as accidental drift.
- The baseline native candidate remains `gose` plus crypto and HTTP libraries with owned discovery/JWKS caching. Its maturity, algorithm support, X.509/JWE limitations, runtime requirements, and suitability require verification at the selected version rather than inherited trust.
- Replacement procedure remains contract tests, corpus, differential tests, and conformance before switching defaults. Shadow only side-effect-free verification/parsing in staging; never send single-use authorization codes or rotating refresh tokens to two backends.
- Retain the previous backend for at least one release after a default change. Separate-package publication must preserve opaque ownership through explicit attestation contracts rather than exposing identity constructors.

## 6. Validation plan and external oracles

| Gate                         | Required assets and scenarios                                                                                                                                                     | Acceptance limit                                                                                 |
| ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| V0 Supply chain              | Exact pins/lockfile, advisory and retirement checks, release SBOM, changelog/security review                                                                                      | Upgrades are deliberate; upstream certification does not transfer                                |
| V1 Owned facade              | URI/redirect tables, callback parsing/property tests, constant-time state review, RFC 7636 Appendix B, transaction races, FFI term fuzzing, total error mapping, secret sentinels | Scripted ordering does not establish crypto or atomic stores                                     |
| V2 OIDF                      | Public-API reference RP; Basic, Config, Form Post, third-party initiation, RP logout; optional later FAPI and additional RP plans                                                 | Run current pinned plans and archive logs; historical warnings/skips require explicit comparison |
| V3 JOSE boundary             | Independent `panva/jose` verification of private-key JWT, RFC 9449 DPoP vectors; Wycheproof and RFC 7515/7517/7520 for a native backend                                           | Do not claim revalidation of all upstream crypto from wrapper tests                              |
| V4 Raw-backend differential  | Identical external scenario corpus through raw `oidcc` and Warden                                                                                                                 | Reject unexplained disagreement; record stricter facade policy explicitly                        |
| V5 Provider interoperability | Keycloak, Hydra, Dex, scriptable provider/mock; recorded Google/Entra/Okta/Auth0 metadata and JWKS; optional dedicated live tenants                                               | Use no secret fixtures; confirm exact provider names/versions before execution                   |
| V5b Attack matrix            | RFC 9700 threats plus callback, transport, and refresh attacks                                                                                                                    | Every required row must pass before production acceptance                                        |
| V6 Operational               | Worker crash/restart, concurrent refresh, timeouts, body bounds, process/memory/atom growth, logging, storage loss                                                                | Real runtime and network evidence required                                                       |
| V7 Replacement               | Same contract/corpus and differential runs against each backend                                                                                                                   | Equivalent declared semantics rather than identical foreign record shapes                        |

- The reference RP must expose login start, query/form callback, third-party initiation, and RP logout using public APIs only. Harnesses are modeled on `erlef/oidcc_conformance` and `panva/openid-client-conformance-tests`; browser-free automation remains to be proven.
- Local conformance uses explicit test trust anchors and supports CI evidence. Certification requires the applicable hosted submission for the exact Warden release; historical upstream logs cannot substitute for it.
- Preserve the baseline release gates: no vulnerable/unpinned dependency, no owned-facade failure, no conformance regression, no unexplained backend divergence, no failing attack row, and no supported-provider interoperability failure. Archive results per release and compare every backend upgrade.
- The code/token corpus must include valid tokens, bad signatures, `alg: none`, HS/RS confusion, unknown keys and rotation, wrong issuer/audience/authorized party, expired/not-yet-valid claims, missing/mismatched nonce, bad `at_hash`, missing subject, malformed/oversized responses, and endpoint errors.
- Add encrypted unsigned ID-token rejection at the pinned fixed backend. Login tests must also prove required-ID-token enforcement and strict audience/authorized-party option mapping rather than merely echoing adapter declarations.
- Attack tests retain login CSRF, code replay, injection/PKCE downgrade, issuer mix-up, token substitution, nonce replay, algorithm confusion, redirect manipulation, malicious discovery, SSRF, wrong-host/self-signed TLS, and duplicate callback parameters.
- Concurrent consumption tests must race two callbacks and observe one exchange, then hold the lock across exact expiry and observe no exchange. Include missing storage, unknown commit, backend crashes, and post-send transport loss without retry.
- Custody tests must lose installation acknowledgement, recover the same command without exchange, and reject foreign owner or altered material. Refresh tests must cover retain/replace, absent/present ID token, changed identity/nonce/authentication time/scopes, overlapping commands, stale revision, and lost response after provider rotation.
- Refresh publication tests must reject mismatched command, unchanged revision, foreign session reference, and contradictory acknowledgements while retaining the original recovery command. Recovery must never redispatch the provider.
- Seed each secret with a distinct sentinel and inspect errors, observations, and foreign failure mappings. Negative compiler consumers must distinguish token kinds, checked/consumed/verified values, attestations, custody ownership, and reservation versus publication recovery.

## 7. Pinned evidence and claims

- The accepted backend pin is `oidcc` `3.9.0`, Apache-2.0, source `aa212d52d0140addf057c34917b734647401b34e`; annotated tag object `e5bad400ecb538bc0d826d54516fd7ee3b1cb2a8`. The recorded vulnerable range through `3.8.0` makes the baseline's older release reference unsuitable.
- [Verification research](research/warden-verification-contract.md) records exact source paths for nonce, PKCE, audience, authorized party, ID-token presence, `at_hash`, and failure handling. [Refresh research](research/warden-refresh-contract.md) pins `oidcc_token.erl` SHA-256 `289be9bcb0e4677cba3dc98a3b4675070aec7beb27054726da395166b85ac2e3` and records absent-ID-token and nonce-continuity limitations.
- [Protocol/auth research](research/protocol-auth-boundaries.md) records historical `oidcc` `3.0.0` certification for Basic, Config, Form Post, and third-party-initiated RP. Refresh and RP logout runs in the upstream harness are additional evidence, not additional certified-profile claims for Warden.
- The recorded upstream conformance harness revision is `b632d9745b9490229ebca004b4df9928e1457d51`. The current suite version, exact provider fixtures, imported source licenses, and selected profile versions must be pinned before executable acceptance claims.
- RFC 6749, 7636, 7662, 9126, 9207, 9449, and 9700 plus OIDC Core, Discovery, and RP-Initiated Logout supply operation expectations. RFC 7009, 8628, and 8693 remain sources for explicit gaps rather than claims of implementation.

## 8. Demonstrated evidence and freeze

- [Login transactions](playground/interface_lab/LOGIN-TRANSACTIONS.md) demonstrates two-tab binding with synthetic entropy/challenges. [Login consumption](playground/interface_lab/LOGIN-CONSUMPTION.md) demonstrates revision/status/expiry transitions through an injected store, not concurrent shared storage.
- [Verified login](playground/interface_lab/VERIFIED-LOGIN.md) demonstrates private consume-and-exchange orchestration and canonical identity construction after configured assertions. It does not invoke `oidcc`, derive PKCE, or validate a signature.
- [Session custody](playground/interface_lab/SESSION-CUSTODY.md) demonstrates exact installation and recovery using immutable ledger transitions. [Session refresh](playground/interface_lab/SESSION-REFRESH.md) demonstrates reservation, settlement, quarantine, publication, and recovery with scripted callbacks.
- Those probes do not establish TLS, SSRF protection, foreign exception containment, cryptographic correctness, durable atomicity, or security certification. The real backend and storage oracles remain open requirements.
- The initial public freeze retains validated configuration, login outcomes, opaque identity/session, and typed session-operation outcomes as intended facades. Unfinished store protocols remain internal, and all original unimplemented capability families remain backlog.
- Do not begin another interface-refinement wave. Reopen the frozen public API only when real implementation produces a concrete caller mismatch.

## 9. Remaining decisions and potential loss

- The source audit resolved several baseline uncertainties, including callback issuer ownership, explicit nonce/PKCE options, strict audience behavior, required login ID token, and refresh mismatch. It did not execute the actual adapter or prove HTTP bounds.
- Remaining adapter work includes exact exported-call mapping, error catalog, default refresh strategy, bounded HTTP seam, time injection/skew, provider supervision types, and conformance-driver feasibility.
- Certification scope, custom verifier trust, persisted custody restoration, cookie replay authority, refresh reconciliation, and gap adoption remain explicit decisions. A small initial facade must not settle them by omission.
- Preserve source provenance and notices when adapting upstream fixtures. Confirm the baseline's scriptable provider reference before pinning it; its draft `node-warden-provider` spelling is not an accepted dependency identifier.
- No supported baseline operation is dropped. Changes remove unsafe assumptions about inherited certification, copyable single-use values, raw error formatting, and stateless cookie replay prevention while preserving their intended security and recovery obligations.
