# Agent instructions

## Repository responsibility

- Oversight owns ecosystem composition contracts and executable consumer evidence. The independent libraries, PostgreSQL adapters and Retrace packages own their detailed designs in their own repositories.
- Read the [ecosystem design](docs/design/design.typ), the three context vocabularies ([composition](docs/design/composition/CONTEXT.typ), [applications](docs/design/applications/CONTEXT.typ), [evidence](docs/design/evidence/CONTEXT.typ)), the [context map](docs/CONTEXT-MAP.md), [coverage](docs/COVERAGE.md) and the relevant [ADRs](docs/adr/) before changing a composition boundary.
- Keep the current design timeless. Put rationale, alternatives, findings and attributable dates in ADRs. Do not restore review plans, status reports or change logs as competing authorities.
- Preserve intended capabilities without presenting unbuilt features as working behavior. Record genuine unresolved requirements in the owning context's pending ledger.
- Before proposing or changing a public facade, exercise ordinary use, distinct advanced configuration, application-native types and recovery from a separate consumer.
- Keep compiler evidence, scripted behavior, native runtime checks, database fault tests and upstream conformance claims distinct. Preserve executable inputs and oracle revision and license provenance.
- The compiled applications under `apps/` and experiments under `playground/` are the usage examples; keep a prose usage guide out of the repository so a public API change fails a gate instead of leaving a stale guide. Keep example and fixture READMEs to what the directory is and how to run it.
- Record every oracle's pin, comparison scope and limits in [docs/ORACLE.md](docs/ORACLE.md) in the same change that repins it. Link other repositories by their GitHub address.

## Tooling and workspace

- When updating dependency pins, reconcile affected `manifest.toml` files in examples, consumers and nested packages through Gleam, then run the full repository gate; updating the root lock alone is insufficient.

- `nix develop` supplies Gleam, Erlang/OTP 29, rebar3, Elixir, Python with jsonschema, PostgreSQL 16 and lefthook. Run each experiment from its documented directory in this shell.
- `apps/scripts/with-postgres.sh` creates and removes a disposable PostgreSQL cluster. No existing database or live provider is needed.
- Use repository-scoped Git, respect each sibling repository's instructions, and never read or copy credential files such as `.env.local`.
- Unpublished sibling libraries are Git dependencies with `ref = "main"`, and each project's `manifest.toml` is the lock. Move one by hand with `gleam update <package>`; no job does it. Oracle comparisons fetch hash-pinned inputs lazily into the Nix store, never on shell entry.
- `nix fmt -- PATH...` formats named files through treefmt. Avoid whole-repository formatting during a scoped change. The pre-commit hook formats staged files, and `nix flake check` validates formatting.

## Validation commands

- Run only the checks relevant to the changed contract, and report exactly what was executed. A documentation change does not require every runtime gate.
- Quality: `nix flake check`.
- One application: `nix develop --command bash scripts/test-applications.sh <name>` (for example `checkout`, `session_replay`, `financial_recovery`, `email_portal`).
- Retained experiments: `nix develop --command bash scripts/test-experiments.sh`. Fabric record compatibility is the one experiment outside this profile; run it by hand from a Fabric checkout with Git history (see its README).
- All applications: `nix develop --command bash scripts/test-applications.sh`.
- Shared design validation: `nix run .#design-gate-check -- docs/design`.
- Unpublished sibling changes: `nix develop --command python3 -B scripts/local_sources.py --output <new-directory>`, then run the consumer from the copy.
- Optional design tools: `nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf` and `nix run .#design-gate-context -- docs/design --estimate`.

## References

- [docs/ORACLE.md](docs/ORACLE.md) pins each external reference the experiments compare against (the pinned MCP schema, published JSON Blueprint releases, the older Fabric reader and the recorded Relay baseline), states what each comparison covers and how to run it, and states the limits of each claim.
- This repository has no `BENCHMARKS.md`: it owns no benchmark workload ([ADR 0019](docs/adr/0019-qualify-composition-through-validation-profiles.md)). Benchmarks belong to the library that owns each workload; find the libraries in the [README](README.md#libraries).

<!-- agent-skills:begin -->
<!-- framework-commit: cab7c0590036edaa66d8430cc5016399a9fd2c71 origin: git@github.com:lostbean/skills.git -->

(Repository validation policy overrides the framework defaults below.)

## Agent skills

**Design layer** — `docs/CONTEXT-MAP.md` indexes the design documents:
the root design is `docs/design/design.typ`, each context has its own
`design.typ` and `CONTEXT.typ` under `docs/design/<context>/`, and
`docs/adr/` records decision rationale. The layer renders to one
`docs/design/design-layer.pdf`. `docs/COVERAGE.md` maps repository parts to
their design owners.

**Tracker** — local markdown under `issues/`: one directory per feature
(`issues/<feature-slug>/`), the PRD at `issues/<feature-slug>/PRD.md`, issue
files at `issues/<feature-slug>/issues/<NN>-<slug>.md` numbered from 01. Each
issue file carries two header lines near the top — `Status: <state>`,
`Category: <category>`. Conversation appends to the bottom
of the file under a `## Comments` heading. Labels (canonical strings, adopted
verbatim): states `needs-triage`, `needs-info`, `ready-for-agent`,
`ready-for-human`, `in-progress`, `done`, `wontfix`; categories `bug`,
`enhancement`.

**AI disclaimer** — AI-authored tracker comments start with
`AI-assisted contribution.`

**Design tools** — rendering and context export are optional authoring tools:
`nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf` and
`nix run .#design-gate-context -- docs/design --estimate`.
Validation requires formatting, compilation and behavioral unit/integration tests.
Run the pinned shared design validator with `nix run .#design-gate-check -- docs/design`.
Do not implement repository-local shape, documentation equality or checker self-tests.

**Staleness** — source changes since the design last changed require a
conformance review before the layer is treated as current.

<!-- agent-skills:end -->

## README snippets

Keep README Gleam examples in compiled example or consumer source. Use named
`snips-start` / `snips-end` regions (or include a whole example module), and retain
Prettier ignore ranges around generated README blocks. Format the source first,
then run `nix run .#snips -- --commands deny README.md apps/financial_recovery/README.md`. CI runs
`nix run .#snips -- --check --commands deny README.md apps/financial_recovery/README.md` using the shared pinned
package. Snips checks synchronization; existing example tests check behavior.

## Commit messages

Use a concise subject and an optional explanatory body. Do not add any commit
footers or trailers, including `Co-authored-by`, `Signed-off-by`, `Reviewed-by`,
`Acked-by`, or tool/AI attribution. Do not use `git commit --signoff` or let an
automated tool append a footer. Tracker-comment attribution rules apply only to
tracker comments, never to commit messages.
