# HTTP Gun API compiler experiment

A disposable declaration package that tests a candidate public shape from a separate consumer. It
is not the HTTP Gun implementation and must not be published or used as runtime code. Its external
functions have no implementation, so it establishes syntax and type composition only. Negative
fixtures must reject an opaque client constructor and a `String` body passed to a byte request operation.

## Run

From Oversight:

```sh
nix develop -c sh playground/http_gun_interface/check.sh
```

The script works in a temporary directory and removes it afterward. Gleam may resolve public
dependencies; no HTTP request is sent.

The [evidence design](../../docs/design/evidence/design.typ#experiments-and-acceptance-evidence)
states the limits. The HTTP Gun repository owns the implemented contract.
