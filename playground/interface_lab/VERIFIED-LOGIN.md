<!-- THROWAWAY: Can consumption and an explicitly trusted backend issue one composable identity? -->

# Verified login boundary

## Ownership

- The transaction module owns callback checks, consumption, backend invocation, and identity construction.
- `warden` is a facade over the canonical identity type. It no longer defines a competing pending-login or verification model.
- `trust_adapter` installs a callback bound to one client configuration and records its declared identity and purpose.
- A test adapter is an explicit configuration choice. This experiment supplies no default production backend.
- A public backend attestation is a configured adapter assertion. Constructing it does not establish cryptographic verification or issue a Warden identity.

## Login sequence

- The login operation compares the configured backend client with the original checked client before accessing the store. Issuer, client identifier, and redirect URI must match.
- Checked denials retain the client binding privately without retaining the raw provider reason.
- Consumption must succeed before the operation creates an exchange request or invokes the backend.
- Denial, replay, expiry, changed revision, missing storage, unavailable storage, and unknown commit cannot invoke the backend.
- The private exchange request uses the original transaction and checked code. Public consumption results cannot construct or resume that request.
- The configured adapter can inspect the request material needed for exchange. No request field contains callback state.
- The request declares required nonce and PKCE checks and a strict audience profile. These declarations express adapter obligations rather than evidence that they ran.

## Attestation acceptance

- The attested issuer must equal the original client issuer.
- The attested audience list must contain exactly the configured client identifier. Empty, duplicate, and additional audiences fail this first profile.
- A present authorized party must equal the configured client identifier. Its absence is accepted for the singleton audience profile.
- The subject must be nonempty.
- Only the canonical owner constructs the opaque identity after these checks. The [custody boundary](SESSION-CUSTODY.md) additionally checks original nonce evidence and confirms token installation before issuing a session.
- Identity uses the issuer and subject together as its stable key. Email is not an identity key.

## Failure and result

- Returned errors contain closed classifications rather than backend terms, request material, or raw claims.
- Exchange rejection, unknown exchange outcome, and rejected identity assertions leave the transaction consumed.
- The operation never retries exchange or restores pending state after consumption.
- An unknown exchange outcome may mean that the provider consumed the authorization code. Starting another login is separate from retrying the consumed code.
- `Session` now retains verified identity and confirmed custody references. An uncertain installation returns a distinct custody recovery command; cookies, expiry policy, refresh, logout, and durable session persistence remain separate requirements.

## Composition evidence

- The scripted backend checks the original request fields before returning an attestation.
- The resulting identity passes through the `warden` facade into application-owned request context and the existing tool registrations.
- Panic callbacks check that rejected configuration never accesses the store and that rejected consumption never invokes the backend.
- Binding failures and returned backend failures cannot issue a login result.
- Compiler-negative consumers reject direct identity construction, an attestation used as identity, a checked outcome used as a login result, and a public consumption result used as an exchange request.

## Limits

- A deliberately installed adapter can lie about verification, retain request secrets, or replay an inspected request. Opacity establishes constructor ownership within the configured trust model.
- Returned error shapes do not catch callback exceptions, process exits, or arbitrary foreign failures. Exception containment and secret-safe runtime observation require the actual BEAM adapter.
- Scripted stores and sequential transitions do not prove atomic consumption under concurrency.
- This experiment does not run oidcc, construct its Erlang option map, verify tokens, generate entropy, or derive a PKCE challenge.
- Required PKCE does not by itself enforce S256. Authorization planning and the pinned adapter must establish that policy.
- The [verification contract](../../research/warden-verification-contract.md) retains the full token, session, storage, and oracle obligations.
