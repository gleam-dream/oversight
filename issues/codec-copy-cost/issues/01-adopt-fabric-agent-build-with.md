# Adopt Fabric's `agent.build_with`

Status: ready-for-agent
Category: enhancement

AI-assisted contribution.

## Problem

`agent.build` returns a built agent, and Fabric copies it whole into every
runner it starts. On JSON Blueprint 2.2.0 the applications' agents copy in
9 to 33 kB per run (tool_hub 32,560 bytes, research_agent 11,104, payout_desk
9,328; each `copy_cost_test` bounds them). Fabric's
[ADR 0023](https://github.com/gleam-dream/fabric/blob/main/docs/adr/0023-build-the-agent-in-each-process-from-its-builder.md)
adds `agent.build_with(spec: fn() -> Spec(..))`, which keeps the builder and
builds the agent in each process that runs it, and deprecates `agent.build`.

## Releases

Fabric 0.5.0 adds `agent.build_with` and the `fabric.Error` variant
`AgentUnbuildable`; the `fabric_postgres-v0.4.0` tag goes with it. Every
application pins `fabric >= 0.4.0 and < 0.5.0`.

## What to do

- Widen the `fabric` requirement in payout_desk, research_agent,
  support_desk and tool_hub, move `fabric_postgres` to the matching tag, and
  reconcile each manifest through Gleam.
- Replace every `agent.build` with `agent.build_with` (tool_hub
  `assistant.gleam`, support_desk `desk.gleam`, payout_desk `agent.gleam`,
  research_agent `researcher.gleam` and `test/history_delivery.gleam`). The
  deprecation warning fails the application gate, so all move together.
- Handle `AgentUnbuildable` wherever a `fabric.Error` is matched exhaustively.
- Keep each builder's captures small and make subjects outside it, as the
  ADR states.
- Update the agent entries in each `copy_cost_test`, which then measure the
  builder, and the README sentence that accepts the agent copy.

## Done when

No application calls `agent.build`, the agents' copy-cost bounds are set from
the new measurements, and all application checks pass.
