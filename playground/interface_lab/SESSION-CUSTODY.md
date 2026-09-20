# Verified login and token custody

## Question

- Can verified login establish a usable session whose token material belongs to a named custody owner?
- This experiment prepares an origin for later refresh work. It does not implement refresh, a secret store, or cryptographic verification.

## Identity and token boundary

- The configured login backend returns identity attestation, token material, and original authentication evidence.
- Access, refresh, and logout-only ID tokens have distinct types. Explicit trusted-adapter views permit storage and request construction; Session exposes no token accessor. Their wrappers establish token kind, not verification or secrecy against runtime inspection.
- The canonical transaction module checks the existing issuer, client, audience, and subject bindings before privately issuing identity or preparing custody installation.
- Custody installation retains that exact verified identity, configured provider binding, original authentication evidence, and token material. Public claims cannot become an identity through a second constructor.

## Installation ownership

- The custody owner accepts one stable installation command and returns its accepted-command receipt with a session reference and revision.
- A successful session result requires confirmation of that installation. A malformed success receipt does not prove storage happened correctly.
- An uncertain installation retains an opaque recovery command. Recovery repeats custody installation with the same material; it never repeats the consumed authorization-code exchange. A temporarily unavailable custody port preserves the recovery command.
- A receipt for another owner, command, identity, provider binding, or token material cannot resolve the original request.
- The trusted store must serialize installation and return the same installed reference and revision when recovering an already accepted command. Exact-command comparison is checked by the interface; stable receipt history remains the store obligation. The immutable ledger consumer models this rule without proving concurrent storage behavior.

## Consumer evidence

- Complete login with and without refresh material, then read identity through the existing Warden facade.
- Lose acknowledgement after installation changes the ledger, then recover the same session without another exchange.
- Reject foreign owners, altered command material, and contradictory receipts.
- Reject invalid identity claims before a sentinel custody callback runs. Scope parsing rejects whitespace, control bytes, quote, backslash, and non-ASCII while preserving case; one private Erlang byte conversion supports the public string constructor.
- Keep token kinds and custody references distinct in compiler-negative consumers.

## Remaining scope

- Refresh claims, token generation changes, uncertain provider outcomes, token replacement, scope transitions, expiry policy, revocation, and logout remain separate contracts.
- Native secret custody, redaction under foreign errors, cryptographic verification, and concurrent installation require runtime oracles.
- The [refresh research](../../research/warden-refresh-contract.md) records the pinned adapter's absent-ID-token limitation and original-claim continuity obligations.
- The source-isolated consumer and two compiler negatives pass. Explicit immutable ledger transitions exercise recovery; no concurrent store or provider transport runs.
