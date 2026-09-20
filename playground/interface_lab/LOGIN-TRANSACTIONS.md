<!-- THROWAWAY: Can concurrent login transactions remain distinct before token verification? -->

# Login transaction boundaries

## Decision

- A configured client and transaction are distinct typed values.
- A transaction retains its client, state, nonce, verifier, identifier, and expiry. Authorization-request data exposes the challenge rather than the verifier.
- `plan_login` consumes injected material and time. It produces authorization-request data plus a transaction, not an authorization URL or authenticated session.
- This experiment uses an issuer-bearing callback profile. `check_callback` requires the callback issuer and state to match the transaction and rejects expiry, missing codes, empty codes, and provider rejection.
- Successful checks produce `CheckedCallback`, never `VerifiedIdentity`.
- A checked callback retains the transaction for a future token-exchange boundary. Its type cannot bypass Warden's verified-identity boundary.

## Evidence

- `login_transactions` plans two issuers and tabs, preserves their distinct material, rejects swapped state and issuer, and accepts each correct callback.
- Exact expiry, missing and empty code, provider rejection, and invalid expiry planning are checked explicitly.
- Repeated successful callback checks succeed in this pure model. The probe makes the absence of atomic consumption visible.
- `checked_identity` fails compilation when a checked callback is passed to `warden.subject`.

- The combined laboratory passed twenty-one isolated consumers, twenty-two intended compiler failures, and thirteen executable probe groups on Gleam 1.18.1.

## Limits and next contract

- The opaque text wrappers currently check only non-emptiness. They do not validate URL syntax, redirect policy, issuer discovery, code syntax, or PKCE strength.
- Verifier and challenge are independent synthetic test inputs. Their relationship is not checked or derived. Production planning must use a trusted entropy source and the correct challenge derivation.
- Time is injected as seconds since the Unix epoch. No clock, timer, or clock-skew policy is implemented.
- Client configuration is trusted fixture input; HTTP parsing and callback normalization remain outside this module.
- Issuer-less callback profiles are not modeled. They require a deliberate provider/configuration policy rather than silently omitting the binding check.
- Transactions and checked callbacks are copyable. A production store must load, check, and atomically consume the transaction with an explicit replay/race result before completing login.
- No URL construction, network operation, token exchange, signature check, nonce claim validation, browser-session binding, or identity issuance runs here.
- The existing `warden` module remains a separate minimal identity-boundary experiment. Consolidation must connect this transaction contract to its actual `oidcc` verification adapter, not label local checks as token verification.
- The upstream integration questions and oracle selection remain in [protocol/auth research](../../research/protocol-auth-boundaries.md).
