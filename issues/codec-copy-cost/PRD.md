# PRD: Codec copy cost in the applications

Status: ready-for-agent
Category: enhancement

AI-assisted contribution.

## Summary

The applications follow JSON Blueprint's
[codec practice guide](https://github.com/gleam-dream/json_blueprint/blob/main/docs/CODEC-PRACTICE.md)
([ADR 0041](../../docs/adr/0041-follow-the-blueprint-codec-practice-in-the-applications.md)).
Fabric 0.6 builds each agent inside the processes that run it from the
builder an application passes to `agent.build`. Building generated codecs under the plain warnings-as-errors gate
came with JSON Blueprint 2.2.0.

## Issues

- [01: Adopt Fabric's builder `agent.build`](issues/01-adopt-fabric-agent-build.md)
- [02: Build generated codecs with warnings as errors](issues/02-build-generated-codecs-with-warnings-as-errors.md)
