# MCP and model-provider example

This consumer composes JSON Blueprint, Relay, LLM Wire, HTTP Gun and Sinal
through their public APIs. It looks up a synthetic inventory record over MCP
and continues a model turn against a scripted local provider. All transport
fixtures use loopback; no provider account is needed.

From Oversight, run:

```sh
nix develop --command sh -c 'cd playground/ecosystem_pilot && gleam run'
nix develop --command sh -c 'cd playground/ecosystem_pilot && gleam test'
```

The example prints `A-100 has 7 Ada Lovelace notebooks.`

The application owns `Lookup` and `InventoryItem`. Blueprint codecs define
their JSON contracts. A Relay definition holds the tool name, metadata and
codecs; the server binds its handler and the client calls the same definition.
The application derives an LLM tool declaration from that definition. A second
path discovers the tool over MCP and loads its advertised schema without
inventing a native input type for remote data.

The caller starts and stops its HTTP Gun client, restricted to loopback. It
keeps the model configuration and conversation, appends the returned assistant
turn and correlated tool results, and prepares the next request. Relay owns
its listener and client until the application closes them. Sinal subscriptions
are detached explicitly or scoped with `with_subscriptions`.

`src/fourth_provider.gleam` implements a small HTTP/SSE provider through
`llm_wire/provider`. Its encoder reads replay text and call IDs from the
application's conversation; its reducer handles text, tools, refusal and limits.
Rich content is represented by placeholders in this fixture. This is a protocol
exercise, not a production adapter for images or documents.

The tests cover native and discovered tools, typed observations, invalid
arguments before handler invocation, application errors, tool continuation,
provider replay, common text limits, cancellation during partial output, and
disconnect uncertainty without retry. They verify generic and explicitly
rendered application errors over HTTP.

The [ecosystem design](../../docs/design/design-layer.pdf) states the evidence
boundary. Package designs own the full protocol and resource guarantees.
