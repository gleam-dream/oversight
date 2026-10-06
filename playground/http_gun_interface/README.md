# HTTP Gun API compiler experiment

This disposable declaration package tests a candidate public shape from a separate consumer. It is not the HTTP Gun implementation and must not be published or used as runtime code.

The examples cover ordinary and advanced configuration, streaming, application
types, playback and recording. Negative fixtures must reject an opaque client constructor and a String body passed to a byte request operation.

Run from Oversight:

```sh
nix develop -c sh playground/http_gun_interface/check.sh
```

The script works in a temporary directory and removes it afterward. Gleam may resolve ordinary public dependencies; no application HTTP request is sent.

The library deliberately declares external functions with no supplied implementation. This establishes syntax/type composition only. It proves no configuration validation, network behavior, cleanup, concurrency, storage, cassette fidelity or memory bound. Its simplified error/settings types are not the production error or settings inventory.

The [HTTP Gun design](../../../http_gun/docs/design/design.typ) owns the
implemented contract. This sketch remains a compiler experiment; its candidate
signatures are not the production API or evidence of runtime guarantees.
