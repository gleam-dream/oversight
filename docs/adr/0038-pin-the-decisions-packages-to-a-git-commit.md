# Pin the decisions packages to one Git commit

<a id="adr-0038"></a>

Recorded on 2026-11-16. Supersedes the source selection in
[ADR 0034](0034-consume-the-decisions-packages-by-path-until-published.md#adr-0034).

## Decision

- `clinic_registration`, `payout_desk` and `moderation_desk` declare the `decisions` packages as Git+path dependencies on the repository [gleam-dream/decisions](https://github.com/gleam-dream/decisions), at commit `4691bcec7ef899a00819ea4bed462cb6311268d6`:
  - `decisions` at the repository root;
  - `decisions_otp` at `integrations/decisions_otp`;
  - `decisions_postgres` at `integrations/decisions_postgres`.
- Each application's `manifest.toml` locks these packages with `source = "git"`, the repository address and that commit. The lock replaces the earlier `source = "local"` entries. It records `gleam_crypto` as a requirement of `decisions`.
- `nix/git-sources.nix` registers the fixed source hash of that commit: `sha256-Eg7bkUyPhAtvzgkqChkLSWor6c500FDlrmeJFOcjhp0=`.
- `nix/applications.nix` builds the three applications. The continuous-integration application matrix runs them.
- A Git package at the repository root is the fetched source itself. `nix/applications.nix` gives a root package the source path, and a package with a `path` the subdirectory.

## Rationale and consequences

- A path dependency locked no commit and resolved only from a checkout at one directory depth. A pinned commit makes the three applications' test runs locked-source evidence, as for the other unpublished adapters ([ADR 0031](0031-consume-published-ecosystem-packages-from-hex.md#adr-0031)), and lets Gleam Nix build them ([ADR 0032](0032-build-applications-with-shared-nix-dependencies.md#adr-0032)).
- The commit is on the branch `first-build`. The repository has no `main` branch. If `first-build` is rewritten before a release, this commit can become unreachable. The pin, the three manifests and the registered hash must then move together to a commit that stays reachable.
- The repository is public, as the other tracked library repositories are, so continuous integration fetches the source without a credential.
- The registered hash matches a download of the commit from GitHub.
