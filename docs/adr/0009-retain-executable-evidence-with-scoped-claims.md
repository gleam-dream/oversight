# ADR 0009: Retain executable evidence with scoped claims

<a id="adr-0009"></a>

## Decision

- Keep composition applications, compiler probes, scripted transports, database fixtures, pinned oracle inputs, and their useful running instructions.
- Distinguish compilation, pure behavior, native-runtime behavior, storage fault behavior, protocol conformance, and live-provider qualification.
- Preserve source revision and license provenance where a fixture or oracle depends on it. A comparator is not a production dependency merely because it informed a contract.

## Alternatives and consequences

- Keeping every historical test transcript as a current design authority obscures what the checkout can reproduce. Removing executable evidence would discard the strongest way to challenge the design.
- Test counts and one-time passing output are not timeless guarantees. The design states the scenario and boundary; commands and fixtures make it reproducible.
- A stubbed or unfinished operation does not prove its intended behavior merely because its type compiles. A public consumer must reach the capability without importing private modules.
- Proprietary features require an original contract or licensed oracle; public marketing descriptions do not establish source parity.

## Provenance

- The [host JSON probe receipt](../../playground/interface_lab/oracles/numbers/host-json-probes.txt) is retained byte-for-byte from `research/blueprint-number-host-probes.txt`. It records the original host-parser commands and observations; it does not establish the exact-number behavior of JSON Blueprint. Its former explanatory research prose is consolidated into the owning numerical design and ADRs.

- The retained directories are `apps/` and `playground/`; `docs/COVERAGE.md` names their design owners.
- Historical sources include [API coverage](https://github.com/gleam-dream/oversight/blob/3baff70/API-COVERAGE.md), [interface experiments](https://github.com/gleam-dream/oversight/tree/3baff70/playground/interface_lab), and [implementation reviews](https://github.com/gleam-dream/oversight/tree/3baff70/docs/implementation).
- This ADR consolidates the evidence discipline present in those sources. It does not attribute an unknown original acceptance date or claim that every retained experiment was rerun during documentation cleanup.
