# Custody-owned session refresh

## Question

- Can scheduled and interactive callers share one refresh protocol whose custody owner reserves token generations and publishes replacements?
- This experiment extends the existing Session and CustodyOwner. It introduces no second identity constructor or public refresh execution token.

## Admission

- An additive refresh port preserves independent login custody use. Refresh checks session owner and provider binding before invoking that port.
- A reservation request binds the session reference, expected revision, provider, and caller command identifier.
- The trusted owner records dispatch issuance and command deduplication. Only a matching newly issued dispatch invokes the configured provider callback.
- Missing refresh material is a typed rejection. Trusted owner-provided material and authentication evidence are stored facts, not independently verified by the Session value.
- Pending, competing, recorded, and uncertain reservation replies cannot implicitly authorize a second provider call. Opaque values remain copyable.

## Provider settlement

- Proven no-send, definite endpoint rejection, uncertain provider outcome, and successful attestation have distinct outcomes. Ordinary transport failure cannot establish no-send.
- Known outcomes require an exact owner-recorded settlement receipt. Replaying a command returns its recorded outcome; a new command may be admitted only when the owner releases the generation.
- Unknown provider outcome quarantines the generation. Invalid success may already have rotated tokens, so it also requires reconciliation.
- Absent refreshed ID-token evidence preserves the canonical identity. Present evidence must match original identity, provider, nonce, and authentication-time continuity under the selected profile.
- Refresh token omission retains current material; an explicit replacement supersedes it. Returned unchanged scopes compare as case-sensitive sets rather than ordered lists.

## Publication and recovery

- Publication retains the exact dispatch, expected custody revision, and replacement material. A valid receipt must match the command, retain the session reference, and change the revision before Session construction.
- Unknown or contradictory publication acknowledgement retains an owner-bound recovery command. Recovery cannot call the provider.
- Reservation recovery and publication recovery have distinct types. A status read cannot silently clear quarantine or reissue an uncertain dispatch.
- Automatic resumption of an uncertain reservation remains an explicit unresolved obligation where the owner cannot prove safe dispatch authority.

## Verified evidence

- The constructive `session_refresh` consumer starts from verified login and custody installation, then exercises retained and rotated refresh tokens.
- An immutable owner ledger models scheduled and interactive admission, command replay, competing callers, and quarantine after an uncertain provider outcome.
- Publication recovery returns the recorded session after lost acknowledgement. Receipts with another command, an unchanged revision, or another session reference retain the exact original unresolved recovery.
- Foreign owner/provider, stale revision, unrelated dispatch, missing refresh token, and changed subject, nonce, authentication time, or scopes reject without issuing a replacement session.
- Compiler negatives distinguish reservation recovery from publication recovery and the refresh backend from the login backend.
- Scripted callbacks and ledger transitions establish interface behavior. They do not establish atomic storage or concurrent dispatch exclusion.

## Remaining scope

- Actual concurrency, durable atomic storage, transport classification, cryptographic validation, token secrecy, revocation, and reconciliation resolution require later interface or runtime evidence.
- The current endpoint-rejection category does not yet expose typed provider error details or retry hints. Reauthentication policy and automatic retry therefore remain outside this slice.
- The [pinned refresh research](../../research/warden-refresh-contract.md) records the selected oidcc adapter's absent-ID-token limitation. Scripted alternative capability does not establish that adapter's support.
