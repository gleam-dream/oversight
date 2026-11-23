# Run application tests as Nix checks

<a id="adr-0042"></a>

Recorded on 2026-11-23.

## Decision

Each composition application has a Nix test check,
`checks.<system>.<application>-tests`, built with the pinned
[Gleam Nix library](https://github.com/gleam-dream/gleam-nix)'s `mkTestCheck`.
The check compiles the application with its test code against the same compiled
dependency derivations as its package, fails on any Gleam or Erlang warning in
the application, and runs the application's own test main in the Nix sandbox.
Applications whose tests need PostgreSQL get a disposable PostgreSQL 16 cluster
per check, with the same role, database and variables as
`apps/scripts/with-postgres.sh`.

Git adapters resolve through Gleam Nix's `gitSources` from each manifest and the
hash registry in `nix/git-sources.nix`. Evaluation fetches nothing and needs no
Git credentials.

Continuous integration builds every flake check with
[nix-fast-build](https://github.com/Mic92/nix-fast-build) from the locked
Nixpkgs, in one job, instead of a matrix that runs each application's tests in
the development shell. It first compiles every package and test tree at full
parallelism, then runs the test checks two at a time: several suites assert on
deadlines and lease timing, and four at once on a four-core runner made two of
them fail intermittently. The development launchers stay as they are.

No application is sharded. Measured per-module times put the slowest
application's time almost entirely in one test module, which a module-level
shard cannot split, so sharding would not shorten the build.

## Rationale and consequences

A test check's inputs are the application's declarations, manifest, source and
tests, and the compiled dependencies it shares with the other applications. An
unchanged application keeps its check's store path, so a configured binary
cache would serve it instead of rerunning it. A documentation edit inside an
application changes neither its check nor any other.

One job compiles each shared dependency once for every application. Without a
binary cache, every run still builds and runs every check; caching is a separate
decision and its write access is a trust boundary, because a store path names
the recipe, not its result.

Test checks run on Linux only. On macOS, `nix flake check` evaluates the other
checks and the development launchers run the tests.
