# Instrument replay experiment

[![CI](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

Tests whether an application can capture bounded HTTP acquisition once, replay it with the instrument unavailable,
and evaluate two schema policies with native observations while keeping transport and contract failures distinct.
HTTP Gun owns transport, cassettes and redaction, JSON Blueprint owns parsing and validation, Sinal owns observations,
and the application owns pagination, run identity and recovery. The instrument and measurements are authored synthetic fixtures.

## Run

From this directory:

```sh
nix develop ../.. --command python3 -B run.py
nix develop ../.. --command ruff check run.py
nix develop ../.. --command ruff format --check run.py
```

`run.py` checks formatting, builds with warnings as errors, compiles the small environment-variable FFI with `erlc -Werror`,
then starts the fixture, captures, stops the fixture, probes the closed port and replays from the compiled application.
Each run writes its receipt and provenance to ignored `.artifacts/`. The accepted capture and replay logs, cassette,
receipt and provenance are in repository history at commit `26422a6`.

The [evidence design](../../docs/design/design-layer.pdf) states the behavior and
[ADR 0023](../../docs/adr/0023-separate-transport-failure-from-contract-failure-in-replay.md) records the findings.
