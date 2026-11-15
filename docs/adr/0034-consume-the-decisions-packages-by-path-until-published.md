# Consume the decisions packages by path until their repository is published

<a id="adr-0034"></a>

Recorded on 2026-11-15.

## Decision

- The three applications that use the `decisions` packages declare them as Gleam path dependencies:
  - `clinic_registration`: `decisions`, `decisions_otp` and `decisions_postgres`;
  - `payout_desk`: `decisions` and `decisions_postgres`;
  - `moderation_desk`: `decisions` and `decisions_otp`.
- Each path is `../../../../decisions` or a package directory below it. The path is relative to the application directory.
- The three applications are absent from `nix/applications.nix`, so `nix build` builds none of them. They are also absent from the continuous-integration application matrix.
- `scripts/test-applications.sh` runs each of them:
  - `moderation_desk` runs without PostgreSQL;
  - `clinic_registration` and `payout_desk` run through the disposable PostgreSQL helper.

## Rationale and consequences

- The `decisions` repository has no published remote yet, so it has no commit that a Git dependency can pin.
- Gleam Nix and continuous integration cannot read a path outside the Oversight checkout.
- Gleam resolves a path dependency from the working tree it points to. Until the pins exist:
  - the three applications compile against whatever that tree holds;
  - their manifests do not lock a commit of it, so their test runs are not locked-source evidence.
- The relative path reaches `/code/gleam-dream/decisions` only from a checkout two directories below `/code/gleam-dream`, such as `worktrees/oversight-decisions`. From a checkout one directory below, such as `/code/gleam-dream/oversight`, it reaches a directory that does not exist.

## When the decisions repository is pushed

- Each path dependency becomes a Git+path dependency on one verified commit, in the form `fabric_postgres` and `saga_postgres` already use in `payout_desk/gleam.toml`:
  - `decisions = { git = "<repository address>", ref = "<commit>" }`;
  - `decisions_otp` and `decisions_postgres` add `path = "integrations/decisions_otp"` or `path = "integrations/decisions_postgres"`.
- Gleam regenerates each application's `manifest.toml` with `gleam deps update`.
- `nix/git-sources.nix` registers the fixed source hash of that commit.
- `nix/applications.nix` adds the three application names.
- The continuous-integration application matrix adds the three names.
- The [README](../../README.md#libraries) library table adds the repository by its GitHub address.
- This change supersedes the source selection in this ADR. It follows [ADR 0031](0031-consume-published-ecosystem-packages-from-hex.md#adr-0031) for adapters that remain unpublished, and [ADR 0032](0032-build-applications-with-shared-nix-dependencies.md#adr-0032) for the Nix build.
