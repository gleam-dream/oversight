# API control acceptance evidence

The [contract](contract.md) describes the authorized scope. This report records
the assembled local checkouts under `/private/tmp/gleam-dream-api-control-20260922`
on 22 September 2026. No package was published, pushed, or committed. The
verified changes were then applied to the original checkouts under
`/code/gleam-dream`. All 106 delivered paths matched the assembled copies.
Branches and HEAD commits remained unchanged. Format, check, build, all 10
pilot tests, and the executable example passed again against the original
package paths.

| Package                 | Observed checks                                                                                                                                                                                                                                                                                          |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Blueprint               | `gleam format --check src test`, `gleam check`, `gleam build`, `gleam test` (151 passed), and `gleam test --target javascript` (150 passed).                                                                                                                                                             |
| Sinal                   | Format, check, `gleam build --warnings-as-errors`, `gleam test` (62 passed), `nix flake check`, and `git diff --check`.                                                                                                                                                                                  |
| Relay                   | Format, check, `gleam build --warnings-as-errors`, `gleam test` (137 passed), and `git diff --check` after the exact discovered-call argument change. The final assembled run also passed negative fixtures, frozen schema checks, checksum verification, 109 conformance checks, and `nix flake check`. |
| LLM Wire                | Format, check, build, `gleam test` (156 passed), external package boundary script, Nix formatting gate, and `git diff --check` on the assembled provider/control revision.                                                                                                                               |
| Separate consumer pilot | Format, check, build, `gleam test` (10 passed), `gleam run`, and `git diff --check`. The run printed `A-100 has 7 Ada Lovelace notebooks.`                                                                                                                                                               |
| Oversight               | `nix flake check` after the design, migration, and pilot document updates.                                                                                                                                                                                                                               |

The original seven pilot scenarios remain. Three added scenarios exercise a
discovered finite input schema admitted into LLM Wire without a fabricated
native type, a dynamic Relay call whose exact Blueprint arguments are forwarded
from the model response, heterogeneous Sinal observation in one scope, and an
application-defined fourth provider with its own HTTP/SSE reducer and replay.
The fourth provider test also verifies the shared text byte bound and retry
evidence. Relay's additional large structured-response regression proves the
configured client response bound reaches Blueprint's parser above its ordinary
10 MiB default. Its exact-decimal regression checks that a discovered call
preserves an argument beyond binary64 precision.

The source review found two policy seams and resolved them in the package APIs.
Relay's structured parser now derives its byte bound from the admitted client
response limit. LLM Wire's schema-only `tool_from_contract` now accepts an
already admitted Blueprint `RuntimeContract`; provider-specific projection
accepts or rejects its schema during preparation. The pilot exposed the need
for a lossless discovered-call input: `client.call_discovered` now takes exact
Blueprint `Value`, which the application can parse from provider JSON and
forward without decoding a known field. These changes are covered by package
tests and the separate consumer.

The pilot uses local scripted providers and a local Relay HTTP listener. It
does not establish live commercial-provider behavior, authorization, TLS, or
acceptance of arbitrary remote JSON Schema. Relay checks that dynamic
arguments are an object; the remote server owns full input schema validation.
The LLM declaration validates its admitted finite schema before the pilot
forwards arguments. Copyable prepared calls and continuations do not provide
duplicate-effect protection; an application owner must supply that policy.
