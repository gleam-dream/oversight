<!-- THROWAWAY: Can resource authorization protect an existing registry without owning application context? -->

# Resource authorization

## Ownership

- A configured verifier receives an opaque bearer token and returns a public attestation containing an application principal, audiences, and scopes.
- The verifier can inspect its token input. Constructing an attestation does not prove token validity or admit a grant.
- Relay admits an opaque grant only after checking the attested resource and required endpoint scopes.
- The grant retains the principal, accepted resource, and all actual granted scopes. Relay does not add the presented bearer token as a grant field; the adapter remains responsible for the contents of its generic principal.
- Verifier purpose labels record configuration without enforcing a production/test barrier.
- The application selects trusted verifiers. The protected registry does not independently verify an issuer, signature, expiry, or verifier implementation.

## Protected registry

- `ProtectionConfig` retains one resource and its required endpoint scopes.
- `ProtectedRegistry` retains that configuration, the existing Relay registry, and visibility and execution callbacks.
- Application context remains an explicit argument to each listing or dispatch.
- Each protected operation rechecks the grant against its own resource and endpoint requirements before evaluating policy.
- A grant admitted under weaker endpoint requirements can satisfy stronger requirements only when its retained actual scopes contain them.
- Listing evaluates visibility. Named dispatch evaluates visibility and execution authorization before decoding arguments or invoking a handler.
- Per-tool scope requirements remain in ordinary policy closures. Argument-dependent application policy remains inside the existing typed handler.

## First profile

- Resource, scope, and bearer constructors validate only non-emptiness.
- Resource comparison uses exact configured strings without aliases or normalization.
- Audience admission accepts exactly one configured resource. Empty, duplicate, and additional audiences fail this profile.
- Required scopes use exact membership. The grant preserves the verifier's scope list rather than reducing it to the admission requirements.
- Unknown, hidden, and execution-denied tools retain distinct internal causes and share one external inaccessible classification.
- This classification does not establish an HTTP status or MCP protocol response.

## Composition evidence

- `resource_authorization` supplies an application service principal and tenant context without importing Warden.
- The consumer exercises grant admission, protected listing, direct dispatch, resource mismatch, insufficient scopes, changed execution policy, and early rejection before decoding or invocation.
- `web_resource_authorization` compiles an application policy that relates an API principal's mapped account to the Warden issuer-and-subject key.
- The mapped account is an application convention. Neither Warden identity nor a bare token can substitute for the required resource grant.
- Compiler-negative consumers reject raw tokens, unadmitted attestations, web identities, and direct grant construction at this boundary.

## Limits and next experiment

- A trusted verifier may return a false attestation or retain its token input. The type boundary cannot prove an adapter honest.
- A production transport must select the application's configured verifier and route every protected call through the protected registry.
- Grants do not carry verifier-origin or verification-policy identity. Applications with multiple trust domains sharing a resource and principal type need an explicit policy for grant reuse.
- Constructing a protected registry does not invalidate a copied raw registry. The transport must not bypass policy by caching a raw handler or invoking raw dispatch.
- Policy callbacks see the supplied current context. Their evaluation is not atomic with application data changes or handler effects.
- The cross-library account policy is a source-level composition consumer; it does not run web login or bearer verification.
- Native verification, foreign exception containment, token redaction, protected transport integration, challenges, anonymous access, and authorization-sensitive pagination remain open.
- The [authorization contract](../../research/relay-resource-authorization-contract.md) retains the protocol and operational obligations.
