# tool_hub

MCP in both directions, built from public package APIs only. An `inventory` Relay server
exposes three typed tools, a Fabric agent mounts them through the Relay client and answers
with a scripted LLM provider, and a second Relay server exposes that agent as the MCP tool
`ask_assistant`. Everything runs on loopback, and no provider key is used.

## Run

From this directory, inside the Oversight shell:

```sh
gleam run
gleam test
```

The app owns four compiled recipes: `relay_tools`, `relay_discovery`, `relay_serve` and
`relay_run`. The [protocol pilot](../../playground/ecosystem_pilot/README.md) covers Relay
and LLM Wire without an agent. The [composition contract](../../docs/design/applications/design.typ#tool-hub)
describes discovery, invocation identity and cancellation.
