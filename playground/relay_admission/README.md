# Relay request deadline consumer

[![CI](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

A separate consumer that checks Relay's admitted request deadline through public APIs. The deadline
covers context creation, token verification, execution and finite response waits. The consumer exercises
buffered mounting and a real loopback listener, and its Erlang fixture uses process monitors and TCP sockets
without importing Relay or Mist internals. Client tests also cover dynamic headers, request budgets,
cancellation and subscription opening against real loopback peers. Verification is scripted and needs no
credentials, identity provider or database.

## Run

From Oversight, against the immutable Git dependencies:

```sh
nix develop --command sh -c 'cd playground/relay_admission && ERL_FLAGS="+S 4:4" gleam test'
```

`deadline_contract` is a diagnostic runner that prints observations from eight deadline scenarios before
asserting the contract that the normal suite also asserts. For unpublished coordinated changes, run the
consumer from a local-source capture (`python3 -B scripts/local_sources.py --output <new-directory>`); its
results do not qualify the locked sources.

Relay owns the contract in its design. The [evidence design](../../docs/design/design-layer.pdf)
states the behavior and [ADR 0022](../../docs/adr/0022-retain-relay-admission-evidence-against-its-baseline.md)
records the baseline and findings. The [oracle reference](../../docs/ORACLE.md) lists the baseline among the
pinned references, and `bash scripts/test-experiments.sh` runs this consumer against the recorded revisions.
