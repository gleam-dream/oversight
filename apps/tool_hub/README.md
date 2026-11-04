# tool_hub

[![CI](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

MCP in both directions, built from public package APIs only. An `inventory` Relay server
exposes three typed tools, a Fabric agent mounts them through the Relay client and answers
with a scripted LLM provider, and a second Relay server exposes that agent as the MCP tool
`ask_assistant`. Everything runs on loopback, and no provider key is used.

A question is untrusted model input, so the agent's policy runs only the tools the
inventory declares read-only. `reserve_stock` waits for the operator: `ask_assistant`
answers `awaiting_approval` with the run id, the operator reads the exact arguments with
`tool_hub.pending` and answers with `tool_hub.approve` or `tool_hub.reject`, and the
caller repeats its keyed call to read the answer. The operator credential is generated at
boot and no MCP route carries it; a deployment verifies an access token's scope instead,
as `support_desk` does.

## Run

From this directory, inside the Oversight shell:

```sh
gleam run
gleam test
```

The app owns four compiled recipes: `relay_tools`, `relay_discovery`, `relay_serve` and
`relay_run`. The [protocol pilot](../../playground/ecosystem_pilot/README.md) covers Relay
and LLM Wire without an agent. The [composition contract](../../docs/design/design-layer.pdf)
describes discovery, invocation identity and cancellation.
