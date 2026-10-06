# Gleam Dream

Gleam libraries for HTTP, JSON, background jobs, workflows, authentication and
agents. Oversight contains the ecosystem design and runnable applications that
combine the libraries.

## Libraries

Each library owns its API, design and runtime. Applications choose the libraries
they need and supply domain types and policies.

| Library                                       | Purpose                                         |
| --------------------------------------------- | ----------------------------------------------- |
| [Sinal](../sinal/README.md)                   | Typed telemetry and correlation                 |
| [JSON Blueprint](../json_blueprint/README.md) | JSON codecs, schemas and runtime contracts      |
| [HTTP Gun](../http_gun/README.md)             | HTTP client, streaming, redaction and cassettes |
| [Saga](../saga/README.md)                     | Compensating workflows                          |
| [Grind](../grind/README.md)                   | PostgreSQL job queue                            |
| [LLM Wire](../llm_wire/README.md)             | Model-provider protocols and classification     |
| [Relay](../relay/README.md)                   | MCP server and client                           |
| [Warden](../warden/README.md)                 | OIDC/OAuth client and access-token validation   |
| [Fabric](../fabric/README.md)                 | Agents, durable graphs and approvals            |

[Saga's PostgreSQL adapter](../saga/integrations/saga_postgres/README.md) and
[Fabric's PostgreSQL adapter](../fabric/integrations/fabric_postgres/README.md)
provide persistent storage. Each package README links its detailed design.

## Run an example

Keep the repositories side by side, enter the Oversight shell, and run an
application:

```sh
nix develop
cd apps/tool_hub
gleam test
gleam run
```

[Tool Hub](apps/tool_hub/README.md) runs an agent that calls MCP tools and is
itself served as an MCP tool. Its model provider and tools run locally.

The [application catalog](apps/README.md) also covers checkout, webhooks,
document extraction, approvals, login and crash recovery. Applications use
scripted services and disposable PostgreSQL; no provider credentials are needed.

## Design and experiments

The [ecosystem design](docs/design/design-layer.pdf) explains package
responsibilities, resource ownership and composition. Its
[source](docs/design/design.typ), [vocabulary](docs/design/CONTEXT.typ) and
[coverage map](docs/COVERAGE.md) live here. [ADRs](docs/adr/) record decisions and
their rationale.

Retained experiments answer narrower questions:

- [Interface laboratory](playground/interface_lab/README.md): candidate typed
  APIs, with explicit limits on what compilation proves.
- [Blueprint compatibility](playground/blueprint_compatibility/README.md):
  decoding and schema behavior in pinned published releases.
- [Protocol pilot](playground/ecosystem_pilot/README.md): MCP and model-provider
  calls over local HTTP.
- [HTTP API probe](playground/http_gun_interface/README.md): a declaration-only
  consumer experiment.

## Benchmarks

Package benchmark guides record measured workloads, environments and limits.

| Package                                                          | Measurements                                        |
| ---------------------------------------------------------------- | --------------------------------------------------- |
| [Sinal](../sinal/docs/benchmarks/README.md)                      | Event emission, field codecs and spans              |
| [JSON Blueprint](../json_blueprint/docs/benchmarks.md)           | Parsing, validation, codecs and memory observations |
| [HTTP Gun](../http_gun/examples/comparison/README.md)            | Local HTTP requests and streaming                   |
| [Saga](../saga/bench/README.md)                                  | Workflow construction and execution                 |
| [Grind](../grind/bench/README.md)                                | PostgreSQL job throughput and latency               |
| [LLM Wire](../llm_wire/docs/benchmarks.md)                       | Local HTTP/2 concurrency, latency and VM memory     |
| [Warden](../warden/docs/BENCHMARKS.md)                           | Token validation, key refresh and cache allocation  |
| [Fabric](../fabric/consumers/writing/README.md#retained-timings) | Review-call latency in a graph application          |

These are separate workloads, so their numbers are not an ecosystem ranking.

## Development

The Nix shell supplies Gleam, Erlang/OTP, Elixir, Python and PostgreSQL. Run the
checks for the application or contract you change. See [AGENTS.md](AGENTS.md)
for repository instructions.

To rebuild and check the design document:

```sh
nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf
nix run .#design-gate-check -- docs/design .
nix run .#design-gate-context -- docs/design --estimate
```
