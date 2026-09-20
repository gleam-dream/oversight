# Warden callback verification contract

## Question and status

- The experiment asks how a checked authorization callback becomes one atomically consumed login and then one verified identity through an injected verification backend.
- The current `CheckedCallback` proves only state, callback issuer, code shape, and pre-check expiry against one in-memory `Transaction`.
- The current value is copyable, has no store revision, can be checked repeatedly, and cannot establish token or identity validity.
- This note proposes a consumer and type work order that moves the authoritative expiry decision into atomic consumption and makes backend trust an explicit configuration choice.
- No storage, token exchange, cryptographic verification, or runtime behavior is implemented here.

## Pinned evidence

- Warden's reference backend remains [`oidcc` 3.9.0](https://github.com/erlef/oidcc/tree/3.9.0), source commit [`aa212d52d0140addf057c34917b734647401b34e`](https://github.com/erlef/oidcc/commit/aa212d52d0140addf057c34917b734647401b34e), under Apache-2.0.
- Version 3.9.0 is the first release outside the affected range of the encrypted unsigned ID-token vulnerability. [Upstream advisory](https://github.com/erlef/oidcc/security/advisories/GHSA-533g-4vf3-xwrj)
- The pinned token retrieval path accepts the authorization code plus the original redirect URI, nonce, PKCE verifier, and `require_pkce` option, then validates the token response. [Pinned token API](https://hexdocs.pm/oidcc/3.9.0/oidcc_token.html)
- OAuth authorization codes are bound to the client and redirect URI, expire shortly, and must not be used more than once. [RFC 6749 §4.1.2](https://www.rfc-editor.org/rfc/rfc6749#section-4.1.2)
- PKCE binds the token request to the original verifier whose challenge entered the authorization request. [RFC 7636 §4.6](https://www.rfc-editor.org/rfc/rfc7636#section-4.6)
- OIDC nonce validation binds the ID token to the client session and mitigates replay. [OpenID Connect Core §15.5.2](https://openid.net/specs/openid-connect-core-1_0.html#NonceNotes)

## Required transaction transition

- `Transaction` must gain an opaque revision or another store-issued compare-and-set token.
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

The conceptual store boundary is:

```gleam
pub opaque type TransactionRevision
pub opaque type Clock
pub opaque type StoredTransaction
pub opaque type CheckedCallback
pub opaque type CheckedDenial
pub opaque type ConsumedCallback

pub type CheckedOutcome {
  CodeReady(CheckedCallback)
  ProviderDenied(CheckedDenial)
}

pub type ConsumedOutcome {
  CodeConsumed(ConsumedCallback)
  DenialConsumed
}

pub type ConsumeError {
  TransactionMissing
  TransactionExpired
  CallbackAlreadyConsumed
  TransactionChanged
  StoreUnavailable(StoreFailureCode)
}

pub opaque type TransactionStore

// TransactionStore construction receives an injected Clock. The store calls it
// inside the atomic critical section; callers cannot supply a captured instant.

pub fn load_for_callback(
  store: TransactionStore,
  id: TransactionId,
) -> Result(StoredTransaction, LoadError)

pub fn check_callback(
  transaction: StoredTransaction,
  callback: Callback,
) -> Result(CheckedOutcome, CallbackCheckError)

pub fn consume_callback(
  store: TransactionStore,
  checked: CheckedOutcome,
) -> Result(ConsumedOutcome, ConsumeError)
```

- `consume_callback` is a compare-and-set operation, not `get` followed by `delete`.
- `check_callback` may reject malformed or mismatched callbacks, while only the locked store operation decides exact expiry.
- `ConsumedCallback` is an internal orchestration value rather than an application result.
- The public high-level `complete_login` calls `consume_callback` and the backend without returning the consumed authorization code.
- Gleam cannot make either opaque value linear, so the store transition supplies the single-use guarantee.

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

- `complete_login` first wins the atomic consume.
- A consumed denial returns the typed provider rejection without invoking the backend.
- A consumed code constructs the backend request exclusively from the consumed transaction.
- The request binds the configured provider handle and issuer, client identifier and authentication, exact redirect URI, authorization code, nonce, PKCE verifier, and mandatory PKCE policy.
- Callback state is absent from the token request because Warden has already matched it against the same stored revision.
- The configured backend owns code exchange, signature and algorithm validation, token issuer, audience and authorized-party checks, expiry and not-before checks, nonce, and `at_hash` where applicable.
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
- Warden never restores a consumed transaction or silently repeats a possibly transmitted authorization code.
- A later design may add an explicit attempt journal, while it cannot turn an ambiguous exchange into exactly-once behavior.
- The application response for terminal and ambiguous failures is to start a new login.

## Secret handling

- `CompleteLoginError` carries closed classifications and sanitized reason codes.
- Errors never contain the authorization code, state, nonce, PKCE verifier, client secret, access token, refresh token, ID token, raw claims, or formatted foreign term.
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
- Production evidence still requires ETS and durable-store race tests, process-loss tests around exchange, exact oidcc error mapping, current conformance fixtures, and secret-safe foreign exception handling.
- Refresh remains a separate later contract over an opaque refresh token, token rotation, subject continuity, and atomic replacement.
- Refresh must not reuse `Transaction`, `CheckedCallback`, `ConsumedCallback`, authorization-code retry rules, or callback replay outcomes.
