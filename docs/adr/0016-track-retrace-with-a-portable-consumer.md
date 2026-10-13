# Track Retrace with a portable consumer

<a id="adr-0016"></a>

## Decision

Track the Retrace repository alongside the existing ecosystem repositories.
Its three packages share a source revision: portable `retrace`, JavaScript
`retrace_frontend`, and BEAM `retrace_server`. Their detailed contracts remain
in Retrace's design layer. This extends the inventory in
[ADR 0014](0014-include-warden-postgres-in-package-composition.md#adr-0014).

Retain a small cart recording/reconstruction consumer in `apps/session_replay`,
pinned to an immutable published Git commit and included in the application
CI inventory. It uses only public core APIs and owns its model, messages,
reducer, contract identity and elapsed times.

## Rationale and consequences

A portable consumer makes the recording/replay boundary easy to run without
installing a frontend toolchain or operating a database. It demonstrates native
types, checkpoint continuation and typed failure recovery. These checks do not
establish browser presentation, mobile persistence, S3 archival or durability.

The maintained browser and Tauri examples remain in Retrace rather than being
copied into Oversight. Sinal continues to own typed observation and correlation;
Retrace owns reconstruction of selected application state. Neither package gains
a dependency on the other merely because an application may use both.

The sibling checkout action and compatibility pin selection include Retrace's
`main` branch. Required CI continues to use immutable commits. No package is
published by Oversight's workflows.

## Provenance

Requested by the repository owner on 13 October 2026 after publication of
[Retrace v0.1.0](https://github.com/gleam-dream/retrace/releases/tag/v0.1.0).
