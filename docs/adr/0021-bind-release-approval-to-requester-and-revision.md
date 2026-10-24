# Bind a release approval to the original requester and revision

<a id="adr-0021"></a>

## Decision

- On 7 October 2026 the repository retained an embargoed archive release experiment. Hellhound validates tokens, Relay admits the request and yields the application principal, Fabric stores approval and action evidence, and the application owns permission, classification, requester binding, revision comparison and the release write.
- The release value carries the native requester principal, and policy and the write handler compare it with the fresh context. A release whose requester or revision changed is refused.
- The approver is constructed once per driver and shared by the agent and the answer handler, so a newly constructed permissive verifier is never interchangeable with the configured one.
- Business success is read from the action outcome and the release record. A completed conversation does not establish release.

## Rationale and alternatives

- A review found that a separately authenticated principal with its own document permission replaced the original requester in fresh context, and the action succeeded because the tool arguments held only document and revision. The regression failed before the fix and passes after it; the agent definition advanced to version 2. No library changed.
- Fabric cannot know which context fields are security-relevant, so the binding rule belongs to the application recipe.
- Endpoint scopes belong to Relay's protection. Prechecking them in Hellhound would collapse a missing-scope refusal into bearer rejection.

## Consequences

- The experiment passes eight tests across the planned matrix, a stale-context write guard and the requester regression.
- Limits: orderly store reopen stands in for a fresh driver, so mid-effect crash recovery, concurrent revoke serialization, verifier outage, proof-expiry timing and full MCP transport remain unexecuted. A duplicate release insert currently reports a refused state and has no idempotent success readback.
- A database query failure maps to an uncertain tool result because a lost reply may hide a committed write; that path is compiled and not executed.
