# Resolve composition consumers from locked Git sources

<a id="adr-0015"></a>

## Decision

Composition applications and retained runtime experiments declare Git sources for
unpublished ecosystem libraries and optional adapters, each at `ref = "main"`. Their lockfiles
(`manifest.toml`) are the only record of the resolved revisions; no second
revision list exists. Updating a library is a manual `gleam update <package>`,
and no scheduled run moves one. In-repository paths remain appropriate for
packages owned by Oversight itself.

The development shell supplies Git. Evidence retains each executed consumer's
declarations and resolved manifest and the Git commits they lock, separately from
the repository's own revision and dirty flag. No sibling checkout is needed to build
or qualify a consumer.

## Rationale and alternatives

The dependency review found that individually consumable Git packages conflict
with Oversight consumers supplying the same package through a sibling path.
Gleam treats those as different provided sources even at the same commit. Stale
CI pins also omitted Warden's conditional-write types and Fabric's history API
already used by retained applications.

Reverting libraries to sibling paths would restore the consumer installation
failure. Rewriting their manifests during ordinary validation would qualify a
modified graph instead of the declared package graph. A separate revision file and a
checkout-at-revision step duplicated the lock and fetched working trees that no
build used. Locked Git sources preserve standalone consumption and executable
composition evidence.

## Consequences and provenance

Local sibling edits do not change ordinary consumer runtime dependencies.
Incompatible source requirements between libraries fail dependency resolution when
someone updates a lock. Frozen older oracle and compatibility inputs retain their
own revisions.

Accepted during the contribution integration on 13 October 2026. The reproduced
failures were SSO's missing `WriteCondition`/`WriteOutcome` types, research history's
missing Fabric modules, and Gleam's path/Git source conflict for Sinal.

On 16 October 2026 the owner approved retaining this dependency baseline while
implementing unpublished changes without commits or pushes. Explicit local-source
experiments copy authored sources into a new directory, normalize sibling
dependencies throughout that copy, and retain revisions, dirty flags and content
hashes. They preserve frozen Hex oracle versions and generated historical readers.
The Relay admission experiment requires this mode until its local contract is
published. These results do not qualify the immutable Git baseline.
