# Synthetic data erasure campaign

Tests whether Saga, Grind and HTTP Gun can express reversible preparation followed by irreversible effects while
preserving uncertainty, resumability and cancellation truth. Saga owns the freeze and plan preparation, Grind owns
per-target delivery, cancellation intent and attributed resolution, HTTP Gun owns transport, and the application owns
identities, target policy, receipts and forward reconciliation. Only synthetic data is erased, and no live provider is used.

## Run

From this directory:

```sh
nix develop ../.. --command bash run.sh
```

The runner checks formatting, builds with warnings as errors, starts a loopback HTTP fixture, and runs one integration
test with seven named behavioral checks against the disposable PostgreSQL helper. It removes the fixture and database on
success or failure and writes ignored `.artifacts/latest.log` and `.artifacts/provenance.txt`, which record the run and
the revisions and toolchain it used. The accepted run's log and provenance are in repository history at commit `26422a6`.

The [evidence design](../../docs/design/design-layer.pdf) states the behavior and
[ADR 0020](../../docs/adr/0020-record-evidence-before-irreversible-effects.md) records the expectations, findings and limits.
