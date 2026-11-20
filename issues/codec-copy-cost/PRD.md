# PRD: Codec copy cost in the applications

Status: needs-info
Category: enhancement

AI-assisted contribution.

## Summary

The applications follow JSON Blueprint's
[codec practice guide](https://github.com/lostbean/json_blueprint/blob/main/docs/CODEC-PRACTICE.md)
([ADR 0041](../../docs/adr/0041-follow-the-blueprint-codec-practice-in-the-applications.md)).
Two steps wait on upstream releases: building Fabric agents inside the
processes that run them, and building generated codecs under the plain
warnings-as-errors gate.

## Issues

- [01: Adopt Fabric's `agent.build_with`](issues/01-adopt-fabric-agent-build-with.md)
- [02: Build generated codecs with warnings as errors](issues/02-build-generated-codecs-with-warnings-as-errors.md)
