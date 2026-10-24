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
cluster. Tests fail when `DATABASE_URL` is absent. `provenance.sh` prints a fresh provenance receipt to standard
output. The accepted verification receipt, requester regression record and provenance receipt are in repository history
at commit `26422a6`.

The [evidence design](../../docs/design/design-layer.pdf) states the behavior and
[ADR 0021](../../docs/adr/0021-bind-release-approval-to-requester-and-revision.md) records the findings.
