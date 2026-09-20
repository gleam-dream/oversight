# Agent Instructions

## About this repo

`oversight` holds the design docs for the [gleam-dream](https://github.com/gleam-dream)
organization's packages — production-grade, composable Gleam libraries. Each
`*-design.md` file records one package's full scope, initial facade, and
reference evidence:

| Design doc                                 | Package               | Main reference or oracle                                                                  |
| ------------------------------------------ | --------------------- | ----------------------------------------------------------------------------------------- |
| [blueprint-design.md](blueprint-design.md) | `blueprint`           | JSON Schema Draft 2020-12; `jsonschema` 4.26.0; `json_blueprint` 1.1.0/1.7.1 comparators  |
| [llm-design.md](llm-design.md)             | Standalone LLM client | OpenAI Responses and Anthropic Messages; Google remains a baseline target                 |
| [fabric-design.md](fabric-design.md)       | `fabric`              | BeamWeaver partial behavioral oracle                                                      |
| [grind-design.md](grind-design.md)         | `grind`               | Oban 2.24.1 open-source behavior; Pro features need separate contracts or licensed oracle |
| [relay-design.md](relay-design.md)         | `relay`               | MCP 2026-07-28 frozen schema/requirements; 2025-11-25 compatibility separately            |
| [saga-design.md](saga-design.md)           | `saga`                | Reactor v1.0.6 behavioral oracle                                                          |
| [sinal-design.md](sinal-design.md)         | `sinal`               | `:telemetry` 1.4.2 native behavior                                                        |
| [warden-design.md](warden-design.md)       | `warden`              | `oidcc` 3.9.0 with OIDC/OAuth requirements and security oracles                           |

This repo also hosts throwaway prototypes, evals, and tests written against
these designs before a design is promoted to its own `gleam-dream/<name>`
repo — the dev shell carries both Gleam's own runtime (Erlang/OTP + rebar3)
and Elixir/mix, so an upstream library (Oban, Reactor, oidcc, ...) can run
side by side with a Gleam prototype for direct behavioral comparison.

## Tooling

- `nix develop` (or direnv): dev shell with `lefthook`, `gleam`,
  Erlang/OTP 28 + `rebar3` (Gleam's own runtime), and Elixir (for running
  upstream libraries directly, to compare against while prototyping).
- `nix fmt`: formats the whole repo via treefmt (`gleam format`,
  `mix format`, `nixfmt`, `prettier`).
- `lefthook`: pre-commit hook formats staged files and re-stages them.
- `nix flake check`: fails iff the tree is not formatted (plus any existing checks).
