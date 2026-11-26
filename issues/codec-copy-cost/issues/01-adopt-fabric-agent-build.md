# Adopt Fabric's builder `agent.build`

Status: ready-for-agent
Category: enhancement

AI-assisted contribution.

## Problem

A built Fabric agent holds its tools and their codecs. Fabric copies a value
it sends to another process whole, so an application that handed Fabric a
built agent paid that copy in every runner and tool task. On JSON Blueprint
2.2.0 the applications' agents copied in 9 to 33 kB per run (tool_hub 32,560
bytes, research_agent 11,104, payout_desk 9,328). Fabric's
[ADR 0023](https://github.com/gleam-dream/fabric/blob/main/docs/adr/0023-build-the-agent-in-each-process-from-its-builder.md)
makes `agent.build(spec: fn() -> Spec(..))` take a builder, which Fabric keeps
and runs in each process that runs the agent.

## Releases

Fabric 0.6.0 removes the form of `agent.build` that took a built spec; the
only `agent.build` takes a builder. `fabric.Error` has the variant
`AgentUnbuildable` for an agent whose builder fails in a process. The
`fabric_postgres` adapter for Fabric 0.6 has no release tag yet, so an
application that uses it pins the Fabric core and the adapter to one Fabric
commit.

## Current state

Every `agent.build` call passes a builder (tool_hub `assistant.gleam`,
support_desk `desk.gleam`, payout_desk `agent.gleam`, research_agent
`researcher.gleam` and `test/history_delivery.gleam`). support_desk and
tool_hub require Fabric 0.6 from Hex; research_agent uses the Fabric 0.6
commit that also holds `fabric_postgres`. payout_desk still uses the earlier
Fabric integration commit: its Decisions packages require JSON Blueprint
below 3.0 and Sinal below 0.2, so it cannot resolve the released libraries.

## What to do

- When a Decisions release accepts JSON Blueprint 3 and Sinal 0.2, move
  payout_desk to Fabric 0.6 with the other released libraries, and reconcile
  its manifest through Gleam.
- Set payout_desk's `fabric agent` entry in `copy_cost_test` from a new
  measurement.
- When `fabric_postgres` has a release tag for Fabric 0.6, require Fabric from
  Hex in payout_desk, research_agent and the archive_release experiment, and
  pin `fabric_postgres` to that tag.

## Done when

Every application passes a builder to `agent.build` on a released Fabric, the
agents' copy-cost bounds are set from measurements on that release, and all
application checks pass.
