# Qualify composition through named validation profiles and locked sources

<a id="adr-0019"></a>

## Decision

- The repository runs checks as the profiles quality, application, experiments and full through one runner and one Nix shell. Continuous integration divides the same commands into jobs.
- The final continuous-integration status requires every mandatory job to succeed. Failures, cancellations and unexpected skips cannot satisfy it.
- The runner's application inventory is the authority for discovery, and the continuous-integration matrix derives from it.
- Required runs resolve consumer sources from each project's lockfile. Updating a library is a manual `gleam update`, and no scheduled run moves one.
- All tracked library repositories are public, so continuous integration uses the default read-only token and persists no credentials.

## Rationale and alternatives

- A required status that tolerates a skipped job reports success for work that never ran. The runner therefore rejects cancelled and skipped states and carries controls that prove the rejection.
- Resolving moving branches in required runs would let an unrelated change break a pull request. Lockfiles keep required evidence reproducible, and an update is a deliberate act.
- A scheduled update-and-test run would add a gate that moves sources without anyone deciding to, so the owner declined it.
- A GitHub App or personal token adds a credential for repositories that are already public.

## Consequences

- Application tests have no stable library benchmark. Their durations are operational diagnostics, and package benchmarks stay with the package that owns the workload, so this repository keeps no `BENCHMARKS.md`.
- The applications and experiments are the usage examples, and the `application` and `experiments` profiles compile and run all of them, so a public API change that breaks an example fails a profile. The one exception is the Fabric reader check, which needs sibling Git history that continuous-integration checkouts lack and runs by hand. [ADR 0027](0027-keep-oracle-references-in-a-linked-document.md#adr-0027) records this and where oracle references live.
- Making the final status a required merge check is a repository setting that no workflow changes.
- The repository introduced this validation structure on 6 October 2026 (commit 6d3db3e, "ci: validate ecosystem consumers with pinned dependencies"). [ADR 0015](0015-resolve-composition-consumers-from-locked-git-sources.md#adr-0015) records how consumer sources resolve.
