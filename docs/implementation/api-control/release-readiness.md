# Release readiness review

## Scope

- The user authorized consumer review, release documentation, and branch and gate verification on 23 September 2026. Publication, version selection, dependency upgrades, and Dream HTTP Client adoption remain outside this wave.
- Corrections target concrete release blockers and misleading examples. Current public signatures and protocol requirements in the [API control contract](contract.md) remain binding.
- The user selected Apache-2.0 for LLM Wire during this review.

## Assignments

- Blueprint and Sinal: audit public examples, correct released-versus-unreleased migration history, and prepare release notes.
- Relay: audit tool and continuation examples, correct outcome documentation, and prepare release notes.
- LLM Wire: audit configuration and custom-provider examples, prepare release notes, and address licensing and CI readiness.
- Oversight: independently review the composed consumer, verify branch ancestry and assembled gates, and record remaining release decisions. All four assignments are accepted; publication prerequisites below remain open.

## Verification status

- Consumer reviews are complete. Blueprint's migration guide now distinguishes released 1.7.1 APIs from implementation-branch APIs; Sinal documents observer ownership and span result retention; Relay documents current content-call outcomes and continuation ownership; LLM Wire documents its public adapter builder and supported runtime.
- Unreleased changelogs are present in all four packages. LLM Wire has the approved Apache-2.0 license and package description.
- Root verification passed Blueprint's 151 Erlang and 150 JavaScript tests, Sinal's 62 tests, LLM Wire's 156 tests, and the pilot's 10 tests plus executable example. The expanded separate-consumer fixture compiles schema-only tools, structured preparation, continuation, and Sinal observation while retaining the negative prepared-call boundary check.
- Local verification used Gleam 1.18.1, Erlang/OTP 28, and Node.js 22.21.1 on aarch64-darwin. Blueprint's hosted workflow configures Gleam 1.17 and Node.js 24; that separate matrix was not run here.
- Source format, check, and build gates passed for these packages; Sinal and LLM Wire Nix gates passed. Sinal's initial Markdown formatting failure was corrected and its Nix gate rerun.
- Relay's initial run passed 135 tests and failed two stale sibling-revision assertions. Tests and the checksum script now read one tracked `sibling-revisions.txt`; the frozen MCP checksum is unchanged. The final run passed all 137 tests, the negative compiler fixtures, schema fixtures, checksum verification, 109 conformance checks, and Nix formatting.
- Local Hex export passed for Blueprint and Sinal at their unchanged manifest versions. Their exports include README documentation; changelogs and the migration guide remain repository documents, so release-time links and hosting must be checked. Export rejected Relay and LLM Wire because their path dependencies are not Hex dependencies. These artifacts are inspection outputs, not selected release versions.
- The pilot uses sibling path dependencies. Local composition does not establish that a package can resolve its dependencies after publication.

## Branch integration

- Blueprint's `implementation/schema-aware-core` includes all eight local commits after released `main` at `0e379c6`; `main` has no divergent commits. A fast-forward is possible, but no release-branch move is performed during this review.
- Sinal, Relay, and LLM Wire begin on `master` at `63c7c7d`, `e036033`, and `ca88550` respectively. Oversight begins at `c535b3d` with the deferred Dream tracking note still uncommitted.
- Every repository's earlier `codex/api-ergonomics` branch is an ancestor of its reviewed HEAD; no work from those branches is missing.
- Branch verification is local. It does not imply that commits have been pushed or released.

## Remaining publication work

- Select release versions and convert Relay and LLM Wire's Blueprint and Sinal path dependencies to compatible published package requirements.
- Publish prerequisites before dependent packages, then verify resolution from clean independent consumers.
- Confirm Blueprint's release-branch integration and record the tested commit before tagging. Run its configured hosted compiler and JavaScript matrix; local verification is not evidence for unrun combinations.
- Add hosted LLM Wire CI after its dependency layout is reproducible. Relay's existing hosted workflow also needs released dependencies or explicit available sibling revisions; it currently checks out only Relay.
- Confirm LLM Wire's repository URL before adding package repository metadata; the local repository has no configured remote.
- Resolve LLM Wire's documented strict 16 KiB response-header allocation requirement. Its current rejection test checks an already assembled header block and does not establish a pre-allocation bound in Gun 2.6.0. The existing coverage ledger treats this as a release acceptance decision; this wave does not silently relax it.
- Treat Relay's bundled listeners as unprotected and its frozen-protocol coverage as partial, as documented in its changelog. Initial release notes do not claim complete MCP conformance or production readiness.
- Keep [Dream adoption](dream-http-refinement.md) deferred pending upstream discussion and explicit acceptance of its remaining limitations.

## Recorded delivery

- Blueprint release documentation is committed at `ecf5c60`; Sinal release documentation at `13105bb`; LLM Wire licensing, documentation, and consumer verification at `36dbc25`. Relay release documentation and provenance checks are committed at `c0510b3`.
- No public application API, package version, dependency range, protocol fixture, or transport implementation changed during this wave. Relay's package description was narrowed to its demonstrated scope.
- Local test logs are retained under `/private/tmp/gleam-dream-release-readiness-20260923`. Repository changelogs and this report provide the durable result.
- Nothing was pushed, tagged, or published. Blueprint remains on its implementation branch; release-branch movement remains explicit publication preparation.
