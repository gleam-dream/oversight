# tool_hub

MCP in both directions, built from public package APIs only:

1. **inventory**, a Relay MCP server, exposes three typed tools:
   `search_products`, `get_stock` (both read-only) and `reserve_stock`.
2. A **fabric agent** mounts those tools through the Relay client and answers
   questions with a scripted LLM provider (llm_wire over an http_gun client).
3. A second Relay server exposes that agent as the MCP tool **`ask_assistant`**,
   so any MCP client can call the agent.

Everything runs on loopback. The LLM provider is a small mist server that
speaks llm_wire's scripted wire format (`llm_wire/testing.config()`), so no
provider key or external service is used. The [ecosystem design](../../docs/design/design-layer.pdf) records the composition contract.

## Run

From this directory, inside the oversight dev shell:

```sh
gleam run
gleam test
```

## Modules

| Module                  | Role                                                                                                 |
| ----------------------- | ---------------------------------------------------------------------------------------------------- |
| `tool_hub/inventory`    | Domain, Blueprint codecs, Relay definitions and the inventory server                                 |
| `tool_hub/assistant`    | The typed-answer fabric agent and `ask_assistant` on a second Relay server (`relay_serve.serve`)     |
| `tool_hub/scripted_llm` | Loopback LLM provider for the scripted wire format, with a "hold the stream open" step               |
| `tool_hub/telemetry`    | Sinal handlers for relay, fabric, llm_wire, http_gun and sinal events; joins one run across packages |
| `tool_hub`              | Wiring (`start`/`stop`), the demo script and `main`                                                  |

## What the tests cover

- Calling through both MCP servers with one Blueprint codec for each value.
- Discovering tools from runtime schemas without inventing native input types.
- Returning remote tool errors to the model and preserving unknown outcomes
  when a mutating call loses its reply.
- Rejecting invalid model arguments before they reach the tool server.
- Cancelling an unkeyed invocation when its client disconnects or times out,
  including closing the model stream.
- Keeping a keyed invocation alive across a disconnect and returning the same
  run when its caller retries.
- Following correlation through both protocol directions.

The [tests](test/) exercise local HTTP. The
[protocol pilot](../../playground/ecosystem_pilot/) covers Relay and LLM Wire
without an intervening agent.

## Consumer recipes

The app owns four compiled recipes: `relay_tools`, `relay_discovery`,
`relay_serve`, and `relay_run`. The same recipes are compiled in Fabric's unpublished
[`consumers/relay_tools`](../../../fabric/consumers/relay_tools/) package.
`fabric/invoke` owns request/run lifecycle; Relay owns MCP and delivery
information. The app has no bridge package dependency.

The demo correlates its listing and question. The tests inspect the observation
trail across both protocol directions.
