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

No database, frontend toolchain or service is needed. The manifest pins Retrace
at an immutable Git revision; a sibling checkout is not needed to run the example.

## Read the code

- [Application](src/session_replay.gleam): accept a cart transition, record its
  message with elapsed time, then replay using the same pure reducer.
- [Tests](test/session_replay_test.gleam): matching state, continuation from a
  checkpoint, recovery after a missing event, incompatible contract refusal and
  application-native reducer failure without advancing the player.

The sample has fixed identities and timestamps to make it reproducible. Real
applications supply unique session IDs, monotonic elapsed time and safe data.
A checkpoint remains an in-memory value here; the example does not implement
persistence, transport, viewport rendering or a replay UI.

For those layers, use Retrace's maintained
[basic browser example](https://github.com/gleam-dream/retrace/tree/v0.1.0/examples/basic),
[advanced Tauri example](https://github.com/gleam-dream/retrace/tree/v0.1.0/examples/advanced)
and [adoption guide](https://github.com/gleam-dream/retrace/blob/v0.1.0/docs/adopting-lustre.md).
The frontend and server packages are tracked in Oversight's package inventory;
this consumer exercises only the portable core. The release remains experimental.

## Evidence boundary

The tests execute reconstruction and refusal/recovery through public APIs on the
BEAM. They do not establish browser, native-mobile, database, S3 or crash-durability
behavior. CI runs this consumer without PostgreSQL:

```sh
nix develop --command python3 -B scripts/ci.py application session_replay
```

See the [owning composition contract](../../docs/design/design.typ#session-replay).
