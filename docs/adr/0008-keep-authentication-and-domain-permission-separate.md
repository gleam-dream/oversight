# Keep authentication and domain permission separate

<a id="adr-0008"></a>

## Decision

- Hellhound owns OIDC/OAuth validation and token custody. Relay owns MCP admission and protocol error semantics. Applications map authenticated claims to their domain principals and permissions.
- Fabric accepts approval proof only from the configured approver verifier, which decides authentication and authorization for that application.
- Keep a Hellhound-backed verifier as a compiled recipe until repeated consumers justify a larger shared boundary.

## Context and alternatives

- A valid access token does not imply permission to invoke every tool, approve every action, or choose a caller-supplied reviewer identity.
- Putting business authorization into Hellhound would bind it to application policy. Giving Relay responsibility for identity-provider sessions would couple unrelated protocol lifetimes.
- The earlier nominal reviewer value improved identity representation but was superseded by verifier-minted proof; merely constructing a typed reviewer did not establish authorization.

## Consequences

- Application sessions, browser cookies, scope mapping, and protected-resource policy remain visible application decisions.
- Validation infrastructure failure does not open admission. Local validation and introspection have different freshness and latency costs.
- `apps/secure_mcp`, `apps/sso_portal`, and `apps/support_desk` retain separate consumer evidence for these boundaries.

## Provenance

- [Protocol/auth research](https://github.com/gleam-dream/oversight/blob/3baff70/research/protocol-auth-boundaries.md) states the separation.
- [Release decisions](https://github.com/gleam-dream/oversight/blob/3baff70/docs/release-api/DECISIONS.md) record the 3 October 2026 reviewer decision and 4 October verifier-proof refinement.
