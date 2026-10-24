# Session replay

A small, portable consumer of [Retrace](https://github.com/gleam-dream/retrace).
The cart owns its `Cart`, `Message` and `CartError` types and a pure reducer.
Retrace records accepted messages and reconstructs the same state from them.

## Run

From Oversight:

```sh
nix develop
cd apps/session_replay
gleam test
gleam run
```

The output is:

```text
Recorded cart: 2
Replayed cart: 2
Gap refused: expected event 1, received 2
```

No database, frontend toolchain or service is needed, and the manifest pins Retrace
at an immutable Git revision. The [application](src/session_replay.gleam) accepts a
cart transition, records its message and replays it with the same reducer; the
[tests](test/session_replay_test.gleam) cover checkpoint continuation, a missing
event, an incompatible contract and a refused reducer step.

Retrace's repository holds the browser and Tauri examples that cover the frontend
and server layers. The [composition contract](../../docs/design/design-layer.pdf)
states what this consumer does and does not establish.
