# Adopt Fabric's builder `agent.build`

Status: ready-for-agent
Category: enhancement

AI-assisted contribution.

## Problem

`agent.build` returns a built agent, and Fabric copies it whole into every
runner it starts. On JSON Blueprint 2.2.0 the applications' agents copy in
9 to 33 kB per run (tool_hub 32,560 bytes, research_agent 11,104, payout_desk
9,328; each `copy_cost_test` bounds them). Fabric's
[ADR 0023](https://github.com/gleam-dream/fabric/blob/main/docs/adr/0023-build-the-agent-in-each-process-from-its-builder.md)
makes `agent.build(spec: fn() -> Spec(..))` take a builder, which it keeps and
runs in each process that runs the agent; the form that took a built spec is
removed (the builder form was first named `agent.build_with`).

## Releases

Fabric 0.5.0 makes `agent.build` take a builder and adds the `fabric.Error` variant
`AgentUnbuildable`; the `fabric_postgres-v0.4.0` tag goes with it. Every
application pins `fabric >= 0.4.0 and < 0.5.0`.

## What to do

- Widen the `fabric` requirement in payout_desk, research_agent,
  support_desk and tool_hub, move `fabric_postgres` to the matching tag, and
  reconcile each manifest through Gleam.
- Pass a builder to every `agent.build` call (tool_hub
  `assistant.gleam`, support_desk `desk.gleam`, payout_desk `agent.gleam`,
  research_agent `researcher.gleam` and `test/history_delivery.gleam`). The
  old form no longer compiles, so all move together.
- Handle `AgentUnbuildable` wherever a `fabric.Error` is matched exhaustively.
- Keep each builder's captures small and make subjects outside it, as the
  ADR states.
- Update the agent entries in each `copy_cost_test`, which then measure the
  builder, and the README sentence that accepts the agent copy.

## Done when

Every application passes a builder to `agent.build`, the agents' copy-cost bounds are set from
the new measurements, and all application checks pass.
