# Embargoed archive release

Tests whether authentication, protocol admission and durable approval can bind a release to an exact
document revision, its original requester and current permission. It composes Warden's local HTTPS fixture
issuer, Relay's public authorization admission, Fabric's typed tool and approval, and `fabric_postgres` over
a disposable PostgreSQL cluster, with JSON Blueprint encoding the native values and a deterministic Fabric
model requesting one release.

## Run

From this directory:

```sh
nix develop ../.. --command bash run.sh
```

`run.sh` checks formatting, builds with `--warnings-as-errors`, compiles the fixture FFI with `erlc -Werror`
and runs `gleam test` through `../../apps/scripts/with-postgres.sh`, which creates and removes a private
cluster. Tests fail when `DATABASE_URL` is absent. `evidence/` holds the retained verification receipt, the
requester regression record and the provenance receipt; `provenance.sh` prints a fresh receipt without
overwriting the retained one.

The [evidence design](../../docs/design/evidence/design.typ#authorization-and-approval) states the behavior and
[ADR 0021](../../docs/adr/0021-bind-release-approval-to-requester-and-revision.md) records the findings.
