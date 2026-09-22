# Cross-package integration pilot

This consumer composes the public APIs of JSON Blueprint, Relay, LLM Wire, and
Sinal. It looks up a synthetic inventory record through Relay and continues an
OpenAI Responses turn against a scripted local provider. The provider key is a
placeholder; no request leaves loopback.

From this directory, run the example with:

```sh
nix develop --command gleam run
```

It prints:

```text
A-100 has 7 Ada Lovelace notebooks.
```

The application owns `Lookup` and `InventoryItem`. Blueprint builds the latter
with `codec.record3` and exports their Draft 2020-12 schemas with
`codec.schema_json`. One admitted Relay definition holds the lookup name,
metadata, and codecs. The application binds its handler, reuses the definition
for `client.call_definition`, and derives an LLM Wire declaration from its
metadata and input codec. LLM Wire independently admits the provider tool name.

Relay's listener and client use composable local HTTP configuration. The
provider call uses `llm_wire/config` and `llm_wire/session`; its continuation
retains the prepared settings and provider state, so the host supplies only the
correlated `types.ToolResult`. Sinal observers capture typed lifecycle fields
and are explicitly detached.

Run the seven real transport scenarios with:

```sh
nix develop --command gleam test
```

The tests cover success, invalid arguments, a rendered application error and
provider continuation, cancellation during a partial response, provider
disconnect without retry, a stable generic application error, and an explicitly
JSON-text-rendered application error. The last path binds the same admitted
definition with an error renderer, preserving the JSON string over HTTP without
an extra error codec. See [REPORT.md](REPORT.md) for observed
package heads, results, and limits.
