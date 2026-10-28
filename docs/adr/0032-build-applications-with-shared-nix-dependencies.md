# Build application dependencies as separate Nix derivations

<a id="adr-0032"></a>

Recorded on 2026-10-27.

## Decision

Use the pinned public [Gleam Nix library](https://github.com/gleam-dream/gleam-nix)
to expose a compiled Nix package for each composition application. Keep the
existing Gleam declarations and manifests authoritative for dependency versions
and edges. Rebar3 dependencies use Nixpkgs' builder with the same OTP 29 package
set as the development shell. Git adapters keep their recorded commits and use
explicit fixed source hashes.

Nix quality checks load each application's OTP dependency closure and verify
that equivalent locked dependencies share derivation paths. Existing application
scripts continue to compile with warnings as errors, check handwritten Erlang,
and run their behavioral tests with disposable services.

## Rationale and consequences

Several applications use the same libraries. Independent package derivations
reuse compiled dependencies when their sources, resolved graph, tools, platform
and build settings match. Application changes invalidate the application build
without entering dependency inputs. Nix owns store reuse and configured binary
caches; this change creates no publishing service or cache credentials.

`nix build .#financial_recovery` produces a compiled OTP library. It does not
assemble an executable release or replace the application's test command.
Historical experiments and local-source capture retain their existing workflows.
