# Divide the design layer into composition, applications and evidence contexts

<a id="adr-0026"></a>

## Decision

- The design layer holds three contexts: composition contracts, composition applications, and evidence and validation. A root document indexes them and carries the ecosystem map, and the context map declares their relationships and term ownership.
- Standalone guides fold into native homes. Validation commands live in agent instructions, validation and source-qualification rules live in the evidence context, and decisions and findings live in ADRs.
- The unreleased change history file is removed because the ADRs record each decision and the packages own their release notes. Example and fixture directories keep short run guides, and [ADR 0027](0027-keep-oracle-references-in-a-linked-document.md#adr-0027) keeps oracle references together in `docs/ORACLE.md`.
- Links leave the repository only as repository addresses on GitHub.

## Rationale and alternatives

- The three vocabularies are distinct. Composition names package authority, effect evidence and admission identity. Applications name business identity, reconciliation decisions and applied markers. Evidence names consumers, oracles, revision sets and profiles. One glossary mixed all three.
- Keeping validation as a standalone guide left a fourth authority beside the design. A history file for unpublished software duplicated ADR content.

## Consequences

- Behavior rules from application and experiment guides are now design clauses, so a reader finds each rule once.
- The owner approved this reorganization on 17 October 2026 as the second documentation cleanup, after the consolidation recorded in [ADR 0001](0001-own-designs-in-package-repositories.md#adr-0001).
