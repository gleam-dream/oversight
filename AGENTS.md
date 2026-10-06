# Agent instructions

## Repository responsibility

- Oversight owns ecosystem composition contracts and executable consumer evidence.
  The nine core libraries and two PostgreSQL adapters own their detailed designs
  in their respective repositories.
- Read [the ecosystem design](docs/design/design.typ), its
  [vocabulary](docs/design/CONTEXT.typ), [coverage](docs/COVERAGE.md), and relevant
  [ADRs](docs/adr/0001-own-designs-in-package-repositories.md) before changing a
  composition boundary. The README links each package's design owner.
- Keep current design timeless. Put rationale, alternatives, migration history,
  and attributable dates in ADRs. Do not restore review plans or status reports
  as competing current authorities.
- Preserve intended capabilities without presenting unbuilt features as working
  behavior. Use the owning design's native pending entries for genuine unresolved
  requirements; chronology belongs in ADRs.
- Before proposing or changing a public facade, exercise ordinary use, distinct
  advanced configuration, application-native types, and recovery from a separate
  consumer. Preserve the full capability scope and explicit runtime ownership.
- Keep compiler evidence, scripted behavior, native runtime checks, database
  fault tests, and upstream conformance claims distinct. Preserve executable
  inputs and oracle revision/license provenance.

## Tooling and workspace

- `nix develop` supplies Gleam, Erlang/OTP 28, rebar3, Elixir, Python with
  jsonschema, PostgreSQL 16, and lefthook. Run each experiment from its documented
  consumer directory in this shell.
- Use `apps/scripts/with-postgres.sh` for disposable local database experiments.
  No existing database or live provider is needed for the retained consumers.
- Use repository-scoped Git. Respect each sibling repository's instructions and
  existing work. Never read or copy credential files such as `.env.local`.
- `nix fmt -- PATH...` formats named files through treefmt. Avoid whole-repository
  formatting during a scoped change. The pre-commit hook formats staged files;
  `nix flake check` includes formatting validation.
- Run only checks relevant to the changed contract. A documentation change does
  not require every ecosystem runtime gate. Report exactly what was executed.

<!-- agent-skills:begin -->
<!-- framework-commit: cab7c0590036edaa66d8430cc5016399a9fd2c71 origin: git@github.com:lostbean/skills.git -->

(machine-owned; do not edit inside this fence — re-run setup to refresh)

## Agent skills

**Design layer** — `docs/design/design.typ` describes the design,
`docs/design/CONTEXT.typ` defines its vocabulary, and `docs/adr/` records
decision rationale. The rendered document is `docs/design/design-layer.pdf`.
`docs/COVERAGE.md` maps repository parts to their design owners.

**Tracker** — GitHub issues in `gleam-dream/oversight`, accessed with
`gh issue list --repo gleam-dream/oversight` and `gh issue view NUMBER --repo gleam-dream/oversight`.
Labels bind roles as follows: `needs-triage` → `needs-triage`,
`needs-info` → `question`, `ready-for-agent` → `ready-for-agent`,
`ready-for-human` → `ready-for-human`, `in-progress` → `in-progress`,
`done` → `done`, `wontfix` → `wontfix`, `bug` → `bug`,
and `enhancement` → `enhancement`.

**AI disclaimer** — AI-authored tracker comments start with
`AI-assisted contribution.`

**Design gate** — `nix run .#design-gate-check -- docs/design .` checks render freshness,
vocabulary references and layer integrity (exit 0 clean, 1 violation, 2 error).
The gate is supplied by the pinned `design-layer` flake input.
`nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf`
rebuilds the rendered document. `nix run .#design-gate-context -- docs/design --estimate`
estimates agent context; the same command without `--estimate` emits ephemeral
Markdown. `--manifest`, `--preview`, and `--section PATH --expect-digest DIGEST`
support loading selected sections. A bare Typst compilation does not run the gate.

**Context verification** — use native semantic blocks for lists, tables,
models and behavior. After authoring, verify context estimation and a selected
section export as well as rendering and the design gate.
Run these commands sequentially for each layer; they share its generated
`.render` workspace.

**Staleness** — source changes since the design last changed require a
conformance review before the layer is treated as current.

<!-- agent-skills:end -->
