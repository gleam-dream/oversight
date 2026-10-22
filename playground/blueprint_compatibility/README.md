# Blueprint compatibility playground

Tests whether an existing JSON Blueprint decoder can participate in the laboratory codec boundary
while preserving its wire format and exposing the limits of its schema. It uses published upstream
code in a separate Gleam project: JSON Blueprint 1.7.1 (with JSON 3.1.0 and stdlib 1.0.5) and a
separate 1.1.0 project (with JSON 2.3.0 and stdlib 0.51.0), each pinned by its manifest.

## Run

From the repository root:

```sh
nix develop --command python3 playground/blueprint_compatibility/scripts/check.py
```

The integration runner uses the committed dependency locks, runs both projects, validates the emitted schemas
independently, and requires each of two compiler negatives to fail with one intended diagnostic.
A source-copy script imports the current laboratory modules; generated copies and fetched
dependency output are not version controlled.

The [evidence design](../../docs/design/design-layer.pdf)
states the limits. [ADR 0025](../../docs/adr/0025-treat-legacy-decoders-and-their-schemas-separately.md)
records the findings, and the JSON Blueprint repository owns the compatibility contract and migration guidance.
The [oracle reference](../../docs/ORACLE.md) lists the pinned release checksums and the independent Draft 7 validation.
