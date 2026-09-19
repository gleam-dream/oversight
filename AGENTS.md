# Agent Instructions

## About this repo

`oversight` holds the design docs for the [gleam-dream](https://github.com/gleam-dream)
organization's packages — production-grade, composable Gleam libraries. Each
`*-design.md` file is the design for one package:

| Design doc         | Package  | Ports/wraps                            |
| ------------------ | -------- | -------------------------------------- |
| `grind-design.md`  | `grind`  | Oban (job queue)                       |
| `sinal-design.md`  | `sinal`  | `:telemetry`                           |
| `saga-design.md`   | `saga`   | Reactor (saga/DAG)                     |
| `relay-design.md`  | `relay`  | MCP                                    |
| `warden-design.md` | `warden` | OIDC / OAuth 2.0                       |
| `fabric-design.md` | `fabric` | BeamWeaver-style agent stack (partial) |

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
