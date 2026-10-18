# Own designs in package repositories

<a id="adr-0001"></a>

## Decision

- Accepted by the repository owner on 6 October 2026: replace the scattered design, implementation-plan, and review corpus with package-local design layers.
- Each package owns a timeless design and canonical vocabulary. Oversight owns ecosystem composition contracts and the retained consumer applications.
- ADRs record decisions, alternatives, consequences, and attributable history. Current designs contain no review chronology or implementation diary.
- Keep operational READMEs, published upgrade instructions, executable consumers, fixtures, licenses, and reproducible oracle evidence. Retire obsolete prose after its useful requirements and rationale have an owner.
- An unresolved requirement remains visible in its owning design. Documentation consolidation does not approve a runtime change or erase intended capability scope.

## Context and alternatives

- The former corpus mixed intended facades, implementation snapshots, accepted decisions, superseded proposals, and reports of already-corrected failures. Readers had to reconstruct present behavior across contradictory documents.
- Adding more status banners would preserve that reconstruction work. Moving every old page into an archive would preserve the same competing authorities under a different directory.
- The chosen structure gives current contracts one owner while retaining decision evidence through ADRs and immutable source references.

## Consolidation ownership

| Retired material                                                                                          | Owner of surviving content                                                                                                 |
| --------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| The nine root package designs, package API coverage rows, package review cards, and package research      | Each package's `docs/design/` and `docs/adr/`                                                                              |
| `PUBLIC-API-GUIDELINES.md`, `PUBLIC-API.md`, `ECOSYSTEM-PLAN.md`, `DESIGN-DRIFT.md`, and `EXPLORATION.md` | Oversight caller contracts, responsibility map, evidence rules, and ADRs 0002–0009                                         |
| `docs/release-api/` and `docs/composition/`                                                               | Owning package contracts and ADRs; Oversight composition contracts and ADRs                                                |
| `docs/implementation/` and interface-lab contract/status notes                                            | Owning package contracts and rationale; executable experiment instructions stay beside retained consumers                  |
| Application `FEEDBACK.md` files                                                                           | Oversight application contracts and relevant package decisions; current running instructions remain in application READMEs |
| Unpublished migration-wave guides                                                                         | Current package contract and material API rationale; published-version migration guidance is retained                      |

## Consequences

- Package maintainers update design and behavior together instead of relying on a central historical report.
- A pinned renderer produces the design PDF, checks glossary/ADR links and freshness, and exposes selected agent context. Mechanical success does not prove semantic conformance.
- The renderer retains its own Nix dependency lock. Following host `nixpkgs` was tried during setup and broke exact Typst package resolution; independently pinned tooling avoids changing package runtime toolchains.
- No original acceptance date is invented where the source provides none. Such ADRs identify observed implementation evidence and explicitly distinguish reconstruction from an attributed decision.

## Provenance

- The owner's 6 October 2026 cleanup instruction authorizes the new organization, one package agent per package, and removal of obsolete documentation after consolidation.
- The starting corpus is recoverable at [Oversight revision 3baff70](https://github.com/gleam-dream/oversight/tree/3baff70). Working-tree backlog `DOCS-CLEANUP-1` asked for corrected entry points and reconciliation of the nine package reviews, composition/application feedback, earlier implementation assessments, and obsolete bridge/lifecycle claims. This migration gives those items current design owners and preserves historical evidence in ADRs. The owner's later instruction replaces the backlog's proposed status banners with consolidation into native layers.
- The design tool input is pinned in `flake.lock`; project skills record framework revision `cab7c0590036edaa66d8430cc5016399a9fd2c71` in `AGENTS.md`.
