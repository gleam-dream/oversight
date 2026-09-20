<!-- THROWAWAY: Can copied callback checks preserve explicit store-owned consumption semantics? -->

# Login consumption

## Boundary

- The existing transaction module owns stored transactions, checked outcomes, and consumption commands.
- A pending record retains transaction material and its revision. Consumed and expired records retain only identifier and revision.
- Adapter rehydration constructors accept trusted storage input. They do not authenticate stored records or prevent a dishonest adapter from reconstructing pending state.
- A revision identifies immutable transaction material. Reusing a revision for changed material violates the store contract.
- A consumption command exposes routing metadata without exposing the authorization code, nonce, or verifier.

## Transition order

- Identifier mismatch fails before inspecting the record status.
- A matching consumed or expired record returns its terminal result before comparing revisions.
- A pending record with a different revision returns transaction-changed without transitioning, even if its expiry has passed.
- A matching pending record expires when the locked clock is at or beyond its expiry.
- Otherwise, consumption replaces the pending record with a consumed record.
- Code and denial use the same store transition. Warden derives the public consumption result from the original checked outcome, so the store cannot replace its denial classification.

## Store contract

- The public consume operation accepts a store and checked outcome. It accepts no current record or caller timestamp.
- The injected store callback must acquire its critical section, load the current record, sample the clock, decide the transition, and commit before reporting success.
- Missing records, unavailable storage, and unknown commit outcomes remain distinct.
- Unknown commit does not establish successful consumption or authorize token exchange.
- The pure transition function is usable inside a store adapter. Calling it outside an atomic operation does not establish single use.

## Result and future issuance

- Public consumption reports code consumption or normalized denial consumption without returning a secret-bearing capability.
- Standalone consumption ends the login transaction without issuing an identity.
- The [verified login operation](VERIFIED-LOGIN.md) configures its backend before consumption and exchanges internally after confirmed consumption.
- An already-consumed result must never resume exchange as if the current attempt had won.
- The canonical owner constructs the verified identity privately after a configured backend attestation and binding checks. The adapter remains responsible for actual token verification.

## Evidence and limits

- The consumer exercises sequential copied checks, terminal records with changed revisions, pending revision mismatch, exact expiry, invalid callbacks, denial replay, and store failure classification.
- Compiler-negative consumers reject forged checked callbacks, checked outcomes used as consumption results, and consumption results used as verified identities.
- Scripted callbacks establish orchestration and pure transitions. They do not establish shared mutable state, lock acquisition, durable commit, concurrent single use, or clock sampling after a real lock.
- Terminal records omit secret payloads, but copied pending records and checked values can retain them. This model does not establish memory erasure or runtime redaction.
- The next operational experiment must race two callbacks against one shared store and observe exactly one backend invocation.
