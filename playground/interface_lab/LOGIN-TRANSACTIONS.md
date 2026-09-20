<!-- THROWAWAY: Can callback binding and single-use consumption share one typed transaction? -->

# Login transaction boundaries

## Decision

- A configured client and transaction are distinct typed values.
- A transaction retains its client, state, nonce, verifier, identifier, and expiry. Authorization-request data exposes the challenge rather than the verifier.
- `plan_login` uses injected material and time to produce authorization-request data plus a transaction.
- A stored pending transaction adds a revision to that material. A revision must identify immutable material; a store must never reuse it after changing the transaction.
- `check_callback` binds the callback state and issuer to the stored transaction. Missing and empty codes fail the check.
- Successful checks produce a checked code or a checked denial. Neither result is a verified identity or evidence of consumption.
- Provider denial is normalized to a closed code. A bound denial follows the same terminal consumption path as a bound authorization code.
- Expiry is decided during consumption with the store-owned clock. Callback checking accepts no caller timestamp.

## Consumption

- [Login consumption](LOGIN-CONSUMPTION.md) models pending, consumed, and expired records within the same transaction owner.
- Checked values remain copyable. The atomic store operation must decide which attempt consumes the transaction.
- A public consumption result contains no authorization code or exchange capability. Backend exchange and identity issuance require the subsequent private orchestration boundary.

## Evidence

- `login_transactions` plans two issuers and tabs, preserves their distinct material, rejects swapped state and issuer, and accepts each correct callback.
- Missing and empty codes, invalid expiry planning, normalized denial, and repeatable local checks have explicit probes.
- `login_consumption` checks expiry and replay against modeled stored records.
- `checked_identity` fails compilation when a checked outcome is passed to `warden.subject`.

## Limits

- Text wrappers validate only non-emptiness. URL syntax, redirect policy, issuer discovery, code syntax, and PKCE strength remain outside this experiment.
- Verifier and challenge are independent synthetic inputs. Production planning requires trusted entropy and correct challenge derivation.
- Time uses seconds since the Unix epoch. The injected clock does not establish clock-skew policy or atomic execution.
- Client configuration is trusted fixture input. HTTP parsing and callback normalization remain outside this module.
- Issuer-less callback profiles require an explicit provider policy.
- No URL construction, network operation, token exchange, signature check, nonce claim validation, browser-session binding, or identity issuance runs here.
- The existing `warden` module remains a separate minimal identity-boundary experiment. Its next refinement must become a facade over the canonical transaction and issuance owner.
- The [verification contract](../../research/warden-verification-contract.md) records the pinned backend responsibilities and remaining oracle work.
