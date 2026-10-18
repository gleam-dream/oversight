#let terms = (
  (slug: "term-public-consumer", title: [Public consumer], body: [A separate package that imports only the public modules of the library being assessed.]),
  (slug: "term-retained-experiment", title: [Retained experiment], body: [A disposable-system prototype kept as executable evidence for a named design question, rather than as a production implementation.]),
  (slug: "term-behavioral-oracle", title: [Behavioral oracle], body: [A pinned external implementation or specification used to judge a stated subset of observable behavior. Its authority does not extend beyond that subset.]),
  (slug: "term-locked-source", title: [Locked source], body: [The commit that a consumer's lockfile resolves for an unpublished library. The lockfile is the only record of that revision.]),
  (slug: "term-source-provenance", title: [Source provenance], body: [The record of the package declarations, lockfiles and toolchain a consumer executed, kept separate from the repository's own revision and dirty flag.]),
  (slug: "term-validation-profile", title: [Validation profile], body: [A named subset of the repository's checks (quality, application, experiments, full) that the runner executes as one unit.]),
  (slug: "term-local-source-capture", title: [Local-source capture], body: [A disposable copy of authored sources in which sibling dependencies resolve to the copied trees, used to exercise unpublished coordinated changes. It does not qualify the locked sources.]),
  (slug: "term-rendered-layer", title: [Rendered layer], body: [The single generated document assembled from a repository's design sources and canonical vocabulary.]),
)
