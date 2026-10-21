# Gleam Dream

Gleam libraries for HTTP, JSON, background jobs, workflows, email, authentication and
agents, plus application session recording and replay. Oversight contains the ecosystem design and runnable applications that
combine the libraries.

## Libraries

Each library owns its API, design and runtime. Applications choose the libraries
they need and supply domain types and policies.

| Library                                                         | Purpose                                                                                                       |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| [Sinal](https://github.com/gleam-dream/sinal)                   | Typed telemetry and correlation                                                                               |
| [JSON Blueprint](https://github.com/gleam-dream/json_blueprint) | JSON codecs, schemas and runtime contracts                                                                    |
| [HTTP Gun](https://github.com/gleam-dream/http_gun)             | HTTP client, streaming, redaction and cassettes                                                               |
| [Saga](https://github.com/gleam-dream/saga)                     | Compensating workflows, with a PostgreSQL adapter                                                             |
| [Grind](https://github.com/gleam-dream/grind)                   | PostgreSQL job queue                                                                                          |
| [LLM Wire](https://github.com/gleam-dream/llm_wire)             | Model-provider protocols and classification                                                                   |
| [Relay](https://github.com/gleam-dream/relay)                   | MCP server and client                                                                                         |
| [Warden](https://github.com/gleam-dream/warden)                 | OIDC/OAuth client and access-token validation, with a PostgreSQL adapter                                      |
| [Correio](https://github.com/gleam-dream/correio)               | Transactional email and passwordless verification, with PostgreSQL, Postmark and development mailbox adapters |
| [Fabric](https://github.com/gleam-dream/fabric)                 | Agents, durable graphs and approvals, with a PostgreSQL adapter                                               |
| [Retrace](https://github.com/gleam-dream/retrace)               | Typed session recording and replay: portable core, browser/Tauri frontend and PostgreSQL server               |

Each package README links its detailed design. The Retrace release is experimental and installs through Git dependencies.

## Run an example

The applications and experiments are the usage examples: each compiles and runs
against the libraries' public APIs, and a gate fails when an API change breaks one.
Enter the Oversight shell and run an application. Gleam fetches the libraries
from their recorded immutable Git revisions:

```sh
nix develop
cd apps/tool_hub
gleam test
gleam run
```

[Tool Hub](apps/tool_hub/README.md) runs an agent that calls MCP tools and is
itself served as an MCP tool. The [application catalog](apps/README.md) lists the
other applications, which use scripted services and disposable PostgreSQL and need
no provider credentials.

## Design and experiments

- The [ecosystem design](docs/design/design.typ) explains package responsibilities, resource ownership and composition. Its three contexts are [composition](docs/design/composition/design.typ), [applications](docs/design/applications/design.typ) and [evidence](docs/design/evidence/design.typ).
- The [context map](docs/CONTEXT-MAP.md), [coverage map](docs/COVERAGE.md) and [ADRs](docs/adr/) record vocabulary ownership, repository coverage and decisions.
- Retained experiments answer narrower questions: [relay admission](playground/relay_admission/README.md), [interface laboratory](playground/interface_lab/README.md), [Blueprint compatibility](playground/blueprint_compatibility/README.md), [protocol pilot](playground/ecosystem_pilot/README.md), [archive release](playground/archive_release/README.md), [instrument replay](playground/instrument_replay/README.md), [erasure campaign](playground/erasure_campaign/README.md) and [Fabric record compatibility](playground/fabric_record_compatibility/README.md).
- The [oracle reference](docs/ORACLE.md) pins every external reference the experiments compare against, states what each comparison covers and how to run it, and states where each claim ends.
- Package benchmarks belong to the package that owns each workload; see each library's README.

## Development

The Nix shell supplies Gleam, Erlang/OTP, Elixir, Python and PostgreSQL. Run the
complete consumer gate with:

```sh
nix flake check
nix run .#design-gate-check -- docs/design
nix develop --command bash scripts/test-applications.sh
nix develop --command bash scripts/test-experiments.sh
```

[AGENTS.md](AGENTS.md) lists the individual validation commands and optional design-rendering commands.
