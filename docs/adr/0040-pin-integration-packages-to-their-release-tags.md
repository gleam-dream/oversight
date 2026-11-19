# Pin integration packages to their release tags

<a id="adr-0040"></a>

Supersedes the source selection in
[ADR 0038](0038-pin-the-decisions-packages-to-a-git-commit.md#adr-0038) and the
ref form in
[ADR 0031](0031-consume-published-ecosystem-packages-from-hex.md#adr-0031).

## Decision

- An integration package is not published to Hex. A consumer declares it as a
  Git+path dependency whose `ref` is the package's release tag, named
  `<package>-v<version>`:
  - `fabric_postgres-v0.3.0` in [gleam-dream/fabric](https://github.com/gleam-dream/fabric);
  - `saga_postgres-v0.1.0` in [gleam-dream/saga](https://github.com/gleam-dream/saga);
  - `correio_mailbox-v0.1.1` in [gleam-dream/correio](https://github.com/gleam-dream/correio);
  - `decisions_otp-v0.1.0` and `decisions_postgres-v0.1.0` in
    [gleam-dream/decisions](https://github.com/gleam-dream/decisions).
- The `decisions` core is a Hex requirement, `>= 0.1.0 and < 0.2.0`. At their
  tags both integrations require the core from Hex, so an application resolves
  one core.
- Each `manifest.toml` still locks the commit the tag named when Gleam resolved
  it. `nix/git-sources.nix` registers the fixed source hash of each locked
  commit and nothing else.

## Rationale and consequences

- The owner ruled that integration packages are consumed by Git tag. A tag
  names a release the library's own repository states; a bare commit hash names
  nothing a reader can look up, and the commit ADR 0038 pinned was the head of
  a working branch.
- A tag can be moved. The lockfile, not the `ref`, is the locked-source
  evidence: a moved tag changes nothing until a consumer re-locks, and the
  Nix build then fails until the new commit's hash is registered.
- The commit ADR 0038 pinned declared `decisions` version 0.1.0, as the Hex
  release does, with a different API. While an integration was still a Git+path
  dependency on that commit, a Hex requirement on the core resolved to the Git
  source without a diagnostic. The core and its integrations therefore moved
  together.
- The released `decisions` packages changed what the three applications
  compile against: a record may end before it begins by its own deadline
  (`occurrence.Pending.ended`, `isolated.Lapsed`,
  `decisions.DeadlinePassedBefore`, `learning.Coverage.lapsed_before`), and a
  `decisions_otp` follower is handed `decisions.Begun` or `decisions.NotBegun`.
  No application sets a deadline on an expectation, so each new branch states
  that and ends the work; `moderation_desk`'s follower does nothing for a
  record that ended before it began, because the edit that superseded it has a
  decision of its own.
