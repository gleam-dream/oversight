# Consume published ecosystem packages from Hex

<a id="adr-0031"></a>

Recorded on 2026-10-27. Supersedes the library source selection in
[ADR 0015](0015-resolve-composition-consumers-from-locked-git-sources.md#adr-0015)
and the Retrace source selection in
[ADR 0016](0016-track-retrace-with-a-portable-consumer.md#adr-0016).

## Decision

Current applications and runtime experiments consume published ecosystem
libraries from Hex. JSON Blueprint uses the 2.x codec release; the other library
requirements admit their 0.1.x releases. Gleam regenerates each affected manifest,
which records the exact package versions and checksums.

The six unpublished adapters retain Git dependencies with package paths and
verified immutable commits. Their parent library requirements resolve from Hex.
Historical JSON Blueprint comparisons, the older Fabric reader, protocol schema
pins and recorded oracle baselines keep their existing inputs.

## Rationale and consequences

The owner published the libraries and all three Retrace packages to Hex. Using
their normal distribution exercises the graph an external application installs
and avoids conflicting Git and Hex sources for the same parent library.

Explicit local-source captures still qualify unpublished coordinated changes.
They replace current library requirements in the disposable copy while retaining
exact historical Hex oracle versions and unrelated external sources. Their
results do not qualify the ordinary locked package graph.

Oversight publishes no package. Existing compilation, application tests,
disposable database checks and retained experiments qualify the updated graph;
publication alone adds no runtime or security guarantee.
