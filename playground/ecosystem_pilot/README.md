# MCP and model-provider example

A consumer that composes JSON Blueprint, Relay, LLM Wire, HTTP Gun and Sinal through their public
APIs. It looks up a synthetic inventory record over MCP and continues a model turn against a
scripted local provider. All transports use loopback, and no provider account is needed.
`src/fourth_provider.gleam` implements a small HTTP/SSE provider through `llm_wire/provider`.

## Run

From Oversight:

```sh
nix develop --command sh -c 'cd playground/ecosystem_pilot && gleam run'
nix develop --command sh -c 'cd playground/ecosystem_pilot && gleam test'
```

The example prints `A-100 has 7 Ada Lovelace notebooks.`

The [evidence design](../../docs/design/evidence/design.typ#experiments-and-acceptance-evidence)
states the evidence boundary. Package designs own the full protocol and resource guarantees.
