# HTTP Gun interface probe

## Result and limits

On 29 September 2026, a separate Gleam consumer compiled against the candidate HTTP Gun declarations. Two negative fixtures were rejected for the expected compiler diagnostics. This establishes type composition for the call sites below. It does not accept the final facade or establish runtime behavior.

The [probe](../playground/http_gun_interface/README.md) declares external functions without supplying their implementations. No network, body lifecycle, disk operation or recording implementation ran. The production assignment must replace the declarations with executable behavior and retain an independent consumer.

## Cases checked

| Case                     | Compiler evidence                                                                                                  |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| Ordinary request         | Standard Gleam HTTP request with a binary body; status and response bytes mapped to a caller-owned Download record |
| Advanced configuration   | Explicit RequireHttp2 and connection configuration passed to client startup                                        |
| Scoped streaming         | A callback consumes a body event and preserves the caller's AppError type through the scoped helper                |
| Playback selection       | A loaded fixture produces the same Client type accepted by the ordinary request function                           |
| Recording selection      | A live Client produces a recording Client and explicit Recording handle                                            |
| Opaque client negative   | Attempting to construct Client from the consumer is rejected with Unknown module value                             |
| Wrong body type negative | Passing Request(String) to the byte request operation is rejected with Type mismatch                               |

The probe uses intentionally simplified settings and error types. It does not establish settings validation, evidence fidelity, supervision, cleanup on exceptions, copied-handle arbitration, persistence or bounded memory. Nested Results preserve caller errors in this sketch; the production consumer must assess whether that remains the clearest interface.

## Reproduction

Run from Oversight:

```sh
nix develop -c sh playground/http_gun_interface/check.sh
```

The script copies the declaration library and consumer into a temporary directory, compiles the positive cases, checks each negative fixture and removes the temporary directory. Dependency resolution in the inspected run selected gleam_http 4.4.0 and gleam_stdlib 0.71.0. The local declaration package is http_gun 0.0.0 and is not publishable.

The final run completed successfully, with both negative fixtures rejected. This is compiler evidence only. All HTTP Gun runtime rows in [API coverage](../API-COVERAGE.md#http-gun) remain Open. The [implementation prompt](../docs/implementation/http-gun-prompt.md) requires executable public consumers and real transport evidence.
