# Cross-package integration pilot

This consumer composes the public APIs of JSON Blueprint, Relay, LLM Wire, and
Sinal. It looks up a synthetic inventory record through Relay and continues an
OpenAI Responses turn against a scripted local provider. It also compiles an
application-defined fourth HTTP/SSE provider in `src/fourth_provider.gleam`.
Provider keys are placeholders; no request leaves loopback.

From this directory, run the example with:

```sh
nix develop --command gleam run
```

It prints:

```text
A-100 has 7 Ada Lovelace notebooks.
```

The simple path owns `Lookup` and `InventoryItem`. Blueprint builds the latter
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

The discovery path lists a Relay tool, parses its advertised finite input
schema into a Blueprint `RuntimeContract`, and creates an LLM declaration with
`types.tool_from_contract`. The model's arguments are parsed to exact Blueprint
`Value` and feed `client.call_discovered` without a native input type;
the application sends the structured result into `session.prepare_continue`.
This path requires no native type invented for the remote schema. A mixed
`sinal.SubscriptionPlan` observes Relay and LLM events in one scope.

The fourth provider uses public `provider.Spec`, `Reducer`, and `Replay` APIs.
Its scripted server verifies the provider-authored assistant text and call ID
on continuation. A separate scenario checks that the shared runtime rejects
text over an admitted byte bound.

Run the ten real transport scenarios with:

```sh
nix develop --command gleam test
```

The original seven tests cover success, invalid arguments, a rendered application error and
provider continuation, cancellation during a partial response, provider
disconnect without retry, a stable generic application error, and an explicitly
JSON-text-rendered application error. The last path binds the same admitted
definition with an error renderer, preserving the JSON string over HTTP without
an extra error codec. Three more tests cover discovery with mixed scoped
observation, fourth-provider text and replay, and fourth-provider limits. See
[REPORT.md](REPORT.md) for observed
package heads, results, and limits.
