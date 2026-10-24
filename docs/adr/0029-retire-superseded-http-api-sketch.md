# Retire the superseded HTTP API sketch

<a id="adr-0029"></a>

## Decision

- Retire `playground/http_gun_interface` and its invocation from the experiment gate.
- HTTP Gun's ordinary consumer owns the implemented examples for requests, streaming, configuration, offline playback and recording. Its separate-package compiler probes reject a forged client and a string body where bytes are required.
- Retain the interface laboratory and other experiments whose unique questions have not been shown to be covered by production consumers.

## Alternatives and consequences

- Keeping a declaration-only copy of an implemented API adds maintenance without validating the current package. The sketch used different signatures and external functions with no runtime implementation.
- This narrows the retention decision in [ADR 0009](0009-retain-executable-evidence-with-scoped-claims.md#adr-0009): useful evidence remains with its owning implementation, while a superseded sketch can leave the current tree.
- Compilation proves public type composition and rejection. HTTP Gun's runtime tests own transport, lifecycle and recording behavior; the retired sketch never established those guarantees.

## Provenance

- The [retired sketch](https://github.com/gleam-dream/oversight/tree/83a48d8/playground/http_gun_interface) remains available at its historical revision.
- Replacement evidence is maintained in [HTTP Gun's ordinary consumer](https://github.com/gleam-dream/http_gun/tree/141f5a3/examples/ordinary) and [consumer gate](https://github.com/gleam-dream/http_gun/blob/141f5a3/dev/consumers).
