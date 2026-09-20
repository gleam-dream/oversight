# Warden callback verification contract

## Question and status

- The experiment asks how a checked authorization callback becomes one atomically consumed login and then one verified identity through an injected verification backend.
- The [consumption experiment](../playground/interface_lab/LOGIN-CONSUMPTION.md) checks callbacks against a stored revision and models terminal consumption through an injected store.
- Checked values remain copyable and cannot establish token or identity validity.
- This note specifies the remaining atomic-storage and verification work, including explicit backend trust.
- No shared atomic storage, token exchange, or cryptographic verification is implemented here.

## Pinned evidence

- Warden's reference backend remains [`oidcc` 3.9.0](https://github.com/erlef/oidcc/tree/v3.9.0), under Apache-2.0. The signed `v3.9.0` tag resolves to source commit [`aa212d52d0140addf057c34917b734647401b34e`](https://github.com/erlef/oidcc/commit/aa212d52d0140addf057c34917b734647401b34e).
- Version 3.9.0 is the first release outside the affected range of the encrypted unsigned ID-token vulnerability. The pinned validation path rejects an encrypted ID token without a nested signature as `signature_required`. [Upstream advisory](https://github.com/erlef/oidcc/security/advisories/GHSA-533g-4vf3-xwrj), [pinned JWT source](https://github.com/erlef/oidcc/blob/aa212d52d0140addf057c34917b734647401b34e/src/oidcc_jwt_util.erl#L403-L419), [pinned ID-token source](https://github.com/erlef/oidcc/blob/aa212d52d0140addf057c34917b734647401b34e/src/oidcc_token.erl#L1195-L1227)
- The pinned high-level retrieval path accepts the authorization code, provider worker, client identifier, client authentication, and retrieval options. It constructs the client context before delegating to token retrieval and validation. [Pinned facade source](https://github.com/erlef/oidcc/blob/aa212d52d0140addf057c34917b734647401b34e/src/oidcc.erl#L109-L147)
- OAuth authorization codes are bound to the client and redirect URI, expire shortly, and must not be used more than once. [RFC 6749 §4.1.2](https://www.rfc-editor.org/rfc/rfc6749#section-4.1.2)
- PKCE binds the token request to the original verifier whose challenge entered the authorization request. [RFC 7636 §4.6](https://www.rfc-editor.org/rfc/rfc7636#section-4.6)
- OIDC nonce validation binds the ID token to the client session and mitigates replay. [OpenID Connect Core §15.5.2](https://openid.net/specs/openid-connect-core-1_0.html#NonceNotes)

## Pinned oidcc contract

- Token retrieval requires `redirect_uri` and sends it with the authorization code. Warden must pass the exact redirect URI retained by the consumed transaction. [Pinned retrieval source](https://github.com/erlef/oidcc/blob/aa212d52d0140addf057c34917b734647401b34e/src/oidcc_token.erl#L423-L450)
- ID-token validation defaults `nonce` to `any`, which skips the nonce claim comparison. Warden must pass the retained nonce explicitly. [Pinned nonce source](https://github.com/erlef/oidcc/blob/aa212d52d0140addf057c34917b734647401b34e/src/oidcc_token.erl#L1013-L1054)
- `require_pkce: true` rejects an absent verifier and provider metadata that supports neither `S256` nor `plain`. It does not require `S256`, because either advertised method permits the verifier to enter the token request. [Pinned PKCE source](https://github.com/erlef/oidcc/blob/aa212d52d0140addf057c34917b734647401b34e/src/oidcc_token.erl#L1433-L1466)
- Warden must require `S256` when it creates and admits the authorization request. The retrieval adapter then passes the retained verifier with `require_pkce: true` without treating that option as proof of the challenge method.
- Token validation requires the configured client identifier in `aud`. The default `trusted_audiences: any` permits additional audiences, while `trusted_audiences: []` rejects every audience other than the configured client identifier. [Pinned audience source](https://github.com/erlef/oidcc/blob/aa212d52d0140addf057c34917b734647401b34e/src/oidcc_token.erl#L1283-L1305)
- The default `validate_azp: client_id` rejects a present `azp` that differs from the client identifier. It does not require an absent `azp`, so the initial Warden adapter combines `trusted_audiences: []` with `validate_azp: client_id`; a later multiple-audience policy must define when `azp` becomes mandatory. [Pinned authorized-party source](https://github.com/erlef/oidcc/blob/aa212d52d0140addf057c34917b734647401b34e/src/oidcc_token.erl#L1307-L1315)
- The pinned ID-token path verifies the signature and configured algorithms, exact issuer unless an issuer-regex quirk is configured, client audience, expiry, not-before time, required claims, nonce, and a present authorized party. Warden's production configuration must exclude an issuer-regex quirk and compare the attested issuer with the consumed transaction.
- Retrieval may succeed without an ID token because the token extractor accepts an absent `id_token`. Warden requires an ID token before the adapter may construct `BackendAttestation`. [Pinned extraction source](https://github.com/erlef/oidcc/blob/aa212d52d0140addf057c34917b734647401b34e/src/oidcc_token.erl#L875-L899)
- The pinned path checks `at_hash` when the ID-token claims contain it and an access token is present. Warden must describe this as a conditional backend check rather than an unconditional token-response property. [Pinned access-token hash source](https://github.com/erlef/oidcc/blob/aa212d52d0140addf057c34917b734647401b34e/src/oidcc_token.erl#L901-L930)

## Required transaction transition

- `StoredTransaction` associates pending transaction material with an opaque `StoredRevision`. The trusted store must never reuse a revision after changing that material.
- `CheckedCallback` must retain the transaction identifier, revision, expiry, configured issuer, client identifier, redirect URI, nonce, PKCE verifier, and authorization code without exposing their strings.
- The store must compare identifier, revision, `Pending` status, and expiry in one atomic operation.
- The valid interval is `now < expires_at`.
- The store must sample its injected clock after it has acquired the row lock or equivalent critical section, rather than accept a timestamp captured by the caller before waiting.
- A consume attempt whose locked clock sample is `now == expires_at` returns `TransactionExpired`, even when callback checking ran one tick earlier.
- A successful atomic operation changes `Pending` to a terminal consumed state before any token request starts.
- Two callbacks may both obtain copyable checked values from the same revision.
- Exactly one concurrent consume may succeed; the other returns `CallbackAlreadyConsumed`.
- A bounded consumed tombstone is needed to distinguish the concurrent replay from an unknown identifier or an unrelated revision change.
- Inside the critical section, a consumed status or tombstone takes precedence over revision comparison, so the losing callback returns `CallbackAlreadyConsumed` even when consumption changed the stored revision.
- A pending transaction compares the checked revision next, samples the clock after the lock wait, rejects expiry, and only then changes to `Consumed`.
- State or issuer mismatch does not consume the transaction, because an invalid request must not invalidate the legitimate browser callback.
- A correctly bound provider-denial callback is terminal and should consume the transaction through a checked-denial variant rather than remain an ordinary local check error.

- The canonical type surface lives in [`warden_transaction.gleam`](../playground/interface_lab/src/lab/warden_transaction.gleam).
- The public consume operation returns only sanitized consumption outcomes. It exposes no consumed authorization-code capability.
- Standalone consumption ends a login without issuing an identity. The future high-level operation must consume privately and invoke the configured backend within the same owner.
- Missing storage, unavailable storage, and unknown commit require distinct outcomes. None authorizes backend invocation.
- Store loading and raw callback parsing remain separate follow-up boundaries.
- `check_callback` may reject malformed or mismatched callbacks, while only the locked store operation decides exact expiry.
- Gleam opacity does not make values linear. Shared atomic storage must establish single use.

## Verification boundary

```gleam
pub type AdapterPurpose {
  TrustedAdapter
  TestOnlyAdapter
}

pub type AdapterDeclaration {
  AdapterDeclaration(name: String, version: String, purpose: AdapterPurpose)
}

// Public and constructible by a deliberately configured adapter.
pub type BackendAttestation {
  BackendAttestation(
    issuer: Issuer,
    audiences: List(ClientId),
    subject: Subject,
    tokens: BackendTokens,
    claims: ClaimSet,
  )
}

pub opaque type VerificationBackend
pub opaque type VerifiedGrant
pub opaque type VerifiedIdentity
pub opaque type Session

pub fn oidcc_backend(config: OidccConfig) -> VerificationBackend

pub fn trust_adapter(
  declaration: AdapterDeclaration,
  exchange: fn(ExchangeRequest) ->
    Result(BackendAttestation, BackendError),
) -> VerificationBackend

pub fn complete_login(
  store: TransactionStore,
  backend: VerificationBackend,
  checked: CheckedOutcome,
) -> Result(Session, CompleteLoginError)
```

- `complete_login` rejects a backend bound to a different client before consuming the transaction. It then requires confirmed consumption before invoking the backend.
- A consumed denial returns the typed provider rejection without invoking the backend.
- A consumed code constructs the backend request exclusively from the consumed transaction.
- The request binds the configured provider handle and exact issuer, client identifier and authentication, exact redirect URI, authorization code, nonce, PKCE verifier, and mandatory PKCE policy.
- Callback state is absent from the token request because Warden has already matched it against the same stored revision.
- The configured backend owns code exchange, signature and algorithm validation, token issuer, audience and authorized-party checks, expiry and not-before checks, nonce, and `at_hash` where applicable.
- The default `oidcc_backend` supplies the retained nonce, verifier, and redirect URI. It also supplies `require_pkce: true`, `trusted_audiences: []`, and `validate_azp: client_id` rather than exposing an arbitrary retrieval-options map.
- The default `oidcc_backend` rejects an absent ID token before constructing `BackendAttestation`.
- A public `BackendAttestation` is the configured adapter's assertion that it performed those checks; its constructor is not cryptographic evidence and its type does not prove the adapter honest.
- `oidcc_backend` is the default production path and binds the pinned oidcc adapter without requiring an application to declare custom trust.
- `trust_adapter` is the explicit security boundary for a custom backend. Its declaration records the adapter name, version, and whether it is trusted for ordinary use or test-only use.
- A scripted backend is configured only through the explicit `TestOnlyAdapter` path; Warden does not select it by default.
- Warden compares the attested issuer and client or audience binding with the consumed transaction and validates the attestation shape before its own module constructs the opaque `VerifiedGrant`.
- `VerifiedGrant` contains the accepted issuer, audience/client, subject, tokens, and decoded claims in Warden-owned types.
- `VerifiedIdentity` exposes a stable `(issuer, subject)` key; email remains an optional claim.
- No ordinary public function converts a claim map, subject string, ID token, backend term, or `BackendAttestation` directly into `VerifiedGrant` or `VerifiedIdentity`.
- Opacity proves that an identity followed Warden's configured-backend and binding-check path. It does not prove that a custom adapter implemented its declared verification honestly.
- An application that deliberately installs a dishonest adapter can cause false attestations to be accepted; that action is outside Warden's default-backend guarantee and must remain visible in configuration and review.

## Failure and retry contract

| Outcome                                                                                              | Public classification               | Transaction or code disposition                                                            |
| ---------------------------------------------------------------------------------------------------- | ----------------------------------- | ------------------------------------------------------------------------------------------ |
| State, issuer, or code-shape mismatch                                                                | `CallbackInvalid`                   | The transaction remains pending for the legitimate callback.                               |
| Expiry before atomic consume                                                                         | `TransactionExpired`                | Terminal.                                                                                  |
| Correctly bound provider denial                                                                      | `ProviderDenied`                    | Terminal and consumed without backend invocation.                                          |
| Compare-and-set loses to another callback                                                            | `CallbackAlreadyConsumed`           | Terminal replay.                                                                           |
| Backend proves no token request was sent                                                             | `ProviderUnavailableBeforeExchange` | The initial contract still requires a new login because the local transaction is consumed. |
| Token endpoint returns a defined rejection                                                           | `ExchangeRejected`                  | Terminal.                                                                                  |
| Timeout, connection loss after send, malformed successful response, or backend crash during exchange | `ExchangeOutcomeUnknown`            | Terminal; the provider may have consumed the code.                                         |
| ID-token or claim validation rejects                                                                 | `IdentityRejected`                  | Terminal.                                                                                  |

- The backend may retry connection establishment only while it can prove that no token request was transmitted.
- A generic oidcc `httpc_error` does not prove whether transmission occurred, because the pinned public error type leaves the transport reason as an arbitrary term. The default adapter therefore maps it to `ExchangeOutcomeUnknown` rather than `ProviderUnavailableBeforeExchange`. [Pinned HTTP error source](https://github.com/erlef/oidcc/blob/aa212d52d0140addf057c34917b734647401b34e/src/oidcc_http_util.erl#L27-L37)
- A recognized token-endpoint rejection maps to `ExchangeRejected`. An unrecognized rejection body is discarded and maps to a closed generic rejection reason.
- A malformed successful response, backend crash, or foreign error without a proven pre-transmission state maps to `ExchangeOutcomeUnknown`.
- Warden never restores a consumed transaction or silently repeats a possibly transmitted authorization code.
- A later design may add an explicit attempt journal, while it cannot turn an ambiguous exchange into exactly-once behavior.
- The application response for terminal and ambiguous failures is to start a new login.

## Secret handling

- `CompleteLoginError` carries closed classifications and sanitized reason codes.
- Errors never contain the authorization code, state, nonce, PKCE verifier, client secret, access token, refresh token, ID token, raw claims, or formatted foreign term.
- Pinned oidcc errors may contain raw response bodies, claims, complete token records, invalid property values, or arbitrary transport and JSON terms. The FFI adapter matches only the outer error shape and discards every embedded value before constructing a Warden error.
- Unknown backend terms map to `BackendUnmapped` without applying a generic term formatter.
- Audit events carry transaction identifier, provider identifier, failure class, and timing fields only.
- Fixtures seed every secret with a unique sentinel and assert that error inspection and audit output contain none of them.
- Opaque Gleam types do not prevent VM crash dumps or generic inspection of values held by trusted code, so operational crash-dump and logging policy remains a runtime obligation.

## Consumer-led work order

1. Add a versioned in-memory fake store with an injected clock, `Pending`, `Consumed`, and `Expired` states, and one locked compare-and-set operation.
2. Extend the pure callback result with the stored identifier and revision while preserving current state, issuer, missing-code, empty-code, and provider-denial cases; make exact expiry an atomic-store case.
3. Add the default oidcc-shaped backend configuration plus an explicit `trust_adapter` configuration that accepts public adapter attestations.
4. Add a scripted backend declared `TestOnlyAdapter`; complete one login with issuer, client, redirect, state, nonce, verifier, and code sentinels, and assert that Warden uses transaction values and checks the attested bindings.
5. Run two checked callbacks for one revision concurrently through an injected barrier; require one backend invocation, one `Session`, and one `CallbackAlreadyConsumed` result rather than `TransactionChanged` for the loser.
6. Hold the store lock, enqueue a consume while the clock reads `expires_at - 1`, advance it to `expires_at`, then release the lock; require `TransactionExpired` and no backend invocation.
7. Exercise missing transaction, store failure, provider unavailable before send, explicit token rejection, invalid nonce, invalid audience, bad signature, malformed backend shape, and ambiguous transport loss.
8. Attempt to construct `VerifiedIdentity` directly from issuer, subject, claim map, ID-token text, or `BackendAttestation` in negative fixtures; each must fail. Pair this with a positive fixture showing that an explicitly trusted custom adapter can issue an attestation that Warden accepts after binding checks.
9. Inspect every error and audit value with sentinel secrets and require complete redaction.
10. Run the same backend contract cases through the pinned oidcc adapter later; keep cryptographic and wire claims pending until that differential suite executes.

## Acceptance boundary

- The type experiment proves that checked callback, atomic store consumption, configured-adapter attestation, Warden binding checks, and identity issuance have distinct constructors and owners.
- The concurrent fake proves the intended compare-and-set outcome only for that fake.
- The opaque identity proves passage through those owners, while it cannot prove custom adapter honesty or cryptographic validity.
- Cryptographic confidence in the default path remains contingent on the pinned oidcc adapter and later differential runtime evidence.
- The pure experiment cannot establish that the FFI sends the exact Erlang option map, calls the pinned function, configures exact issuer matching, requires an ID token, or maps every foreign failure without secrets.
- The pure experiment cannot establish signature, issuer, audience, authorized-party, nonce, time, or access-token-hash validation. Those claims require a differential FFI oracle against the pinned backend.
- Production evidence still requires ETS and durable-store race tests, process-loss tests around exchange, pre-transmission evidence tests, exact oidcc error mapping, current conformance fixtures, and secret-safe foreign exception handling.
- Refresh remains a separate later contract over an opaque refresh token, token rotation, subject continuity, and atomic replacement.
- Refresh must not reuse `Transaction`, `CheckedCallback`, `ConsumedCallback`, authorization-code retry rules, or callback replay outcomes.
