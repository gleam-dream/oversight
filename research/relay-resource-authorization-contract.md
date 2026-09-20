# Relay resource authorization follow-up contract

## Question and status

- The experiment asks how Relay can admit one verified bearer grant, filter the tool catalog, and authorize each named dispatch without depending on Warden or introducing a global request context.
- The [resource authorization experiment](../playground/interface_lab/RESOURCE-AUTHORIZATION.md) now supplies the pure grant and protected-registry boundary. It does not establish bearer verification, HTTP challenges, protected-resource metadata, protocol errors, or authorization conformance.
- The experiment keeps application context application-owned. Relay receives that context explicitly for listing and dispatch, because no current consumer requires a generic Relay request-context wrapper.

## Existing boundary

- [API coverage](../API-COVERAGE.md#relay) assigns resource-server authorization to Relay and leaves the capability open. Its missing experiment includes bearer verification, resource binding, scopes, tenant policy, and tool visibility.
- [Protocol and authorization boundaries](protocol-auth-boundaries.md#authorization-ownership) assign token verification to a narrow configured verifier. Relay retains resource, audience, scope, tenant, and tool-policy decisions after verification.
- [`relay.gleam`](../playground/interface_lab/src/lab/relay.gleam) already provides `ContextTool(context)`, `Registry(context)`, `Declaration`, and explicit-context dispatch. The follow-up experiment must reuse that registry rather than add a second tool representation.
- [`relay_exchange.gleam`](../playground/interface_lab/src/lab/relay_exchange.gleam) already retains application context inside each parsed call. The authorization experiment must not move that context into process-global state.
- [`request_scoped_tools.gleam`](../playground/interface_lab/src/consumers/request_scoped_tools.gleam) already demonstrates an application-owned tenant, Warden identity, and typed argument policy. The new layer must leave argument-dependent authorization inside the typed handler.
- [The first server contract](relay-server-contract.md#ownership-boundary) already assigns bearer extraction and verification to the authorization adapter. It also requires authorization-sensitive listing and explicit context at invocation.

## Authorization stages

- The configured verifier checks token validity and returns a public `VerifierAttestation(principal)`. The attestation states the principal, audiences, and scopes that the configured verifier accepted.
- `VerifierAttestation(principal)` is constructible because an external verifier adapter must return it. Its constructor is an explicit trust boundary rather than proof of cryptographic verification.
- `ProtectionConfig` retains one exact resource and its required endpoint scopes. `ProtectedRegistry(context, principal)` retains that configuration, the existing registry, and its tool policy without retaining application context.
- Relay constructs opaque `GrantedRequest(principal)` only after the verifier succeeds and Relay accepts one `ProtectionConfig`. The grant retains the accepted resource and every attested scope so a different protected registry can recheck its own requirements.
- Visibility decides whether a declaration appears in the catalog for one grant and application context. Execution authorization runs independently on every named dispatch.
- Typed argument authorization remains inside `ContextTool(context)`. Relay's execution authorization runs before argument decoding and therefore cannot decide a rule that depends on the decoded application input.

## Proposed surface

```gleam
pub opaque type BearerToken
pub opaque type Resource
pub opaque type Scope
pub opaque type ProtectionConfig

pub type VerifierPurpose {
  TrustedVerifier
  TestOnlyVerifier
}

pub type VerifierDeclaration {
  VerifierDeclaration(
    name: String,
    version: String,
    purpose: VerifierPurpose,
  )
}

pub type VerifierAttestation(principal) {
  VerifierAttestation(
    principal: principal,
    audiences: List(Resource),
    scopes: List(Scope),
  )
}

pub type VerificationError {
  BearerRejected
  VerifierUnavailable
  VerifierUnmapped
}

pub type AdmissionError {
  VerificationFailed(VerificationError)
  ResourceNotGranted
  MissingEndpointScope(Scope)
}

pub type GrantUseError {
  GrantResourceMismatch
  GrantMissingEndpointScope(Scope)
}

pub opaque type Verifier(principal)
pub opaque type GrantedRequest(principal)

pub fn protection_config(
  resource: Resource,
  required_scopes: List(Scope),
) -> ProtectionConfig

pub fn trust_verifier(
  declaration: VerifierDeclaration,
  verify: fn(BearerToken) ->
    Result(VerifierAttestation(principal), VerificationError),
) -> Verifier(principal)

pub fn admit(
  verifier: Verifier(principal),
  token: BearerToken,
  protection: ProtectionConfig,
) -> Result(GrantedRequest(principal), AdmissionError)

pub fn grant_principal(grant: GrantedRequest(principal)) -> principal

pub fn grant_resource(grant: GrantedRequest(principal)) -> Resource

pub fn grant_scopes(grant: GrantedRequest(principal)) -> List(Scope)

pub type Visibility {
  Visible
  Hidden
}

pub type ExecutionAuthorization {
  ExecutionAuthorized
  ExecutionUnauthorized
}

pub type InaccessibleCause {
  UnknownTool
  HiddenTool
  ExecutionDenied
}

pub type ProtectedDispatchError {
  GrantUseFailed(GrantUseError)
  InaccessibleTool(InaccessibleCause)
  InvocationFailed(relay.InvocationError)
}

pub opaque type ToolPolicy(context, principal)
pub opaque type ProtectedRegistry(context, principal)

pub fn tool_policy(
  visibility: fn(
    context,
    GrantedRequest(principal),
    relay.Declaration,
  ) -> Visibility,
  execution: fn(
    context,
    GrantedRequest(principal),
    relay.Declaration,
  ) -> ExecutionAuthorization,
) -> ToolPolicy(context, principal)

pub fn protect_registry(
  protection: ProtectionConfig,
  registry: relay.Registry(context),
  policy: ToolPolicy(context, principal),
) -> ProtectedRegistry(context, principal)

pub fn visible_declarations(
  registry: ProtectedRegistry(context, principal),
  context: context,
  grant: GrantedRequest(principal),
) -> Result(List(relay.Declaration), GrantUseError)

pub fn dispatch_granted(
  registry: ProtectedRegistry(context, principal),
  context: context,
  grant: GrantedRequest(principal),
  name: String,
  input: value.Value,
) -> Result(value.Value, ProtectedDispatchError)
```

- `Resource` and `Scope` retain exact configured strings in the first profile. Their constructors reject empty values without normalizing case, aliases, paths, or trailing separators.
- `protection_config` retains one resource and its required endpoint scopes. `protect_registry` retains that configuration, the existing registry, and the tool policy without capturing application context.
- `admit` accepts only an attestation whose audience list contains exactly the configured resource from `ProtectionConfig`. It rejects absent, duplicate, or additional audiences until a broader audience-policy experiment defines their meaning.
- `admit` requires every endpoint scope from `ProtectionConfig`. It retains every actual granted scope rather than only the scopes required by the admitting configuration.
- `grant_principal`, `grant_resource`, and `grant_scopes` provide read-only access to the accepted grant. There is no dedicated accessor for the presented bearer token or verifier attestation; the generic principal accessor does not enforce redaction.
- Per-tool requirements remain in `ToolPolicy`, because one endpoint-level scope list cannot express tenant-specific tool visibility.
- `trust_verifier` records the configured verifier identity and purpose. These labels do not enforce a production/test boundary, and grants do not authenticate verifier provenance. `TestOnlyVerifier` remains visible in configuration and is never selected by Relay as a production default.
- `visible_declarations` and `dispatch_granted` first compare the grant's actual resource and scopes with the retained `ProtectionConfig`. A resource mismatch or missing endpoint scope returns before tool policy, argument decoding, or handler invocation.
- `dispatch_granted` then resolves the declaration, re-evaluates visibility, and evaluates execution authorization with the current explicit application context. It invokes the existing registry only when the declaration remains visible and execution is authorized.

## Inaccessible tools

- An unknown name, a hidden declaration, and an execution denial all become one external inaccessible-tool outcome. This rule prevents a named call from revealing whether a tool exists but is unavailable to the caller.
- Relay retains the internal cause as `UnknownTool`, `HiddenTool`, or `ExecutionDenied` for application observation. The protocol adapter must collapse those causes before constructing the external response.
- Visibility never grants execution. A caller may name a hidden tool, and policy may change after listing, so every dispatch re-evaluates visibility and execution authorization before argument decoding or handler invocation.

## Decisive consumers

- **Independent MCP service.** A configured verifier returns `ServicePrincipal`, the exact configured resource, and endpoint scopes without importing Warden. The consumer admits the grant, lists one visible tool, and dispatches it through a `ProtectedRegistry`.
- **Web identity and bearer principal.** Application context contains `warden.VerifiedIdentity`, while `GrantedRequest(ApiPrincipal)` carries the independently verified bearer principal. A negative fixture rejects the Warden identity where the grant is required, and application policy decides whether the two principals may act together.
- **Tenant-specific tools.** One application context makes a declaration visible, while the explicit current context supplied to a later dispatch makes execution unauthorized. The consumer receives the inaccessible external outcome, observes the internal execution-denial cause, and records zero handler calls.
- The tenant consumer uses an input decoder and a handler that both panic if invoked. A denied dispatch must return before either panic, which proves the pure call order for the scripted experiment.
- Admission consumers also reject a wrong resource, an additional audience, and a missing endpoint scope before registry policy runs.
- A grant admitted for resource A cannot list or dispatch through a protected registry for resource B. Both operations return a resource mismatch before tool policy, decoding, or handler invocation.
- A grant admitted under weaker endpoint requirements cannot enter a stronger protected registry unless its actual granted scopes satisfy the stronger configuration. One probe rejects a genuinely insufficient grant, while another accepts a grant whose retained scopes already satisfy both configurations.

## Protected invocation integration

- A protected transport retains `ProtectedRegistry(context, principal)` and invokes only `visible_declarations` or `dispatch_granted`. It must not cache a raw tool, handler, `ContextTool`, or `Registry` for later protected invocation.
- A protected invocation must never call `relay.dispatch` directly. Direct dispatch would bypass the retained resource, endpoint-scope, visibility, and execution checks.
- Gleam values are copyable, so constructing `ProtectedRegistry` cannot invalidate a previously retained raw registry. The transport integration and its tests must establish that every protected route uses the protected surface.

## Evidence boundary

- The pure experiment can establish constructor ownership, exact resource comparison, endpoint-scope admission and reuse checks, visibility filtering, execution re-evaluation, early denial, and separation between Warden identity and Relay grant.
- The pure experiment cannot establish that a configured verifier checked a signature, token status, expiry, issuer, audience, or sender constraint. A public attestation remains a trusted adapter assertion.
- Re-evaluating policy on dispatch proves only that Relay invokes the callback with the supplied current context. It does not make policy lookup, tenant data, application mutation, and handler execution atomic.
- Relay must not add the presented bearer token as a grant field. The generic principal remains adapter-owned and may contain arbitrary data. Runtime tests must establish that adapters, errors, observations, and downstream calls do not expose or forward it.
- HTTP bearer extraction, challenges, protected-resource metadata, status mapping, JWT validation, introspection, key rotation, and authorization conformance remain operational work from [API coverage](../API-COVERAGE.md#relay).

## Deferred coverage

- Anonymous access is excluded because the first consumer is a protected endpoint. Relay has no `Anonymous` principal variant until a concrete public-tool consumer defines its interaction with listing and named calls.
- Pagination is excluded because the first experiment returns one finite visible declaration list. Authorization-sensitive cursors must later bind catalog revision, grant, application tenant, and visible view.
- Deferring anonymous access and pagination leaves the resource-server authorization row partial. The experiment answers ownership and policy composition only.

## Unresolved decisions

- The production representation of `BearerToken` remains transport-owned, including whether extraction can avoid an intermediate application string.
- The principal vocabulary remains adapter-owned. A later consumer must decide which stable issuer, subject, client, or workload identifiers Relay exposes for observations.
- The current pure profile retains the attested scope list and uses exact membership for requirements. It reports the first missing scope in configuration order; transport scope parsing and normalization remain unsettled.
- The application-observation surface for internal inaccessible causes remains unsettled. It may be a returned internal error, an injected callback, or a Sinal event, while the external outcome remains identical.
- A future multiple-audience profile must define accepted additional audiences and the applicable token-profile checks before relaxing the singleton resource rule.
