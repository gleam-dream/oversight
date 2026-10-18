# Keep oracle references in a linked document and usage in compiled examples

<a id="adr-0027"></a>

## Decision

- Usage is shown by the compiled and executed applications under `apps/` and experiments under `playground/`. Each keeps a short README that says what it shows and how to run it, and no standalone prose usage guide exists.
- Every pinned reference that an experiment compares against is recorded in [`docs/ORACLE.md`](../ORACLE.md): its pin, what is compared, how the outcome is classified, how to run the comparison and where the claim ends.
- Agent instructions and the repository README link to that document, and the evidence design links to it where it defines how oracles are named.
- Oversight owns no benchmark workload, so it keeps no `BENCHMARKS.md`. Each library repository owns the benchmarks and upstream comparisons for its own workload.

## Rationale and alternatives

- A prose usage guide drifts from the public API without any check noticing. A program that must compile and run fails the gate when the API changes, so the examples are the usage documentation.
- [ADR 0026](0026-divide-the-design-layer-into-three-contexts.md#adr-0026) folded oracle provenance into short directory READMEs. Those READMEs scatter revisions, hashes and limits across several directories, and a reader judging how far a comparison can be trusted needs them together. The design states the rule once and links to the reference rather than repeating the pins.
- Keeping the pins only in each experiment's source leaves the limits of a claim without a home. Copying them into the design would make the timeless design carry values that change when a reference is repinned.

## Consequences

- `playground/relay_admission` joins the `experiments` profile, because it passes against the recorded revisions and so belongs with the other retained experiments. `playground/fabric_record_compatibility` stays a manual run: it needs the old Fabric commit and the sibling commits pinned in that reader's own revision file, and continuous-integration checkouts carry a single revision each.
- Repinning a reference updates `docs/ORACLE.md` in the same change as the pin.
- The owner directed this arrangement on 17 October 2026, revising part of the second documentation cleanup recorded in ADR 0026.
