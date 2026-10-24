# Validate behavior without repository policy gates

<a id="adr-0028"></a>

## Decision

Required validation consists of standard formatting, compilation, and behavioral unit and integration tests. Public consumer builds, compiler-negative cases, real services and independent protocol comparisons remain behavioral evidence.

Remove documentation equality, repository-shape enforcement, custom evidence requirements and checker self-tests. Formatting runs directly through Nix/treefmt. The pinned external design-layer validator runs through its imported Nix app; its implementation and tests belong upstream. Local scripts only arrange application builds, behavioral tests and required service fixtures. Test failures still propagate, and temporary resources are cleaned up.

This supersedes the validation-policy portions of [0019](0019-qualify-composition-through-validation-profiles.md) and earlier requirements for repository-local policy checking. Runtime contracts and behavioral test scenarios are unchanged.

## Rationale and consequences

The owner chose a smaller validation surface on 20 October 2026. The owner clarified on 21 October 2026 that shared external validation remains welcome. Review owns application architecture conventions; the imported design validator owns its document checks. CI output supplies diagnostics without a custom evidence receipt. This accepts loss of bespoke README equality and repository inventory enforcement in exchange for less maintenance of tooling that tests other tooling.
