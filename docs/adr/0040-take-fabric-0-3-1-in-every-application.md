# Take fabric 0.3.1 in every application

<a id="adr-0040"></a>

Recorded on 2026-11-17. Supersedes the last sentence of the dependencies
decision in
[ADR 0039](0039-hand-the-payout-call-over-and-tell-it-in-a-follow-on-run.md#adr-0039),
which kept the other applications on `fabric` 0.2.0.

## Decision

- `apps/tool_hub`, `apps/support_desk`, `apps/research_agent` and `playground/archive_release` require `fabric >= 0.3.1 and < 0.4.0` from Hex and lock 0.3.1.
- `apps/research_agent` and `playground/archive_release` pin `fabric_postgres` at commit `b0cf82c6785309df0266648da53d5b76c90046ec` of [gleam-dream/fabric](https://github.com/gleam-dream/fabric), tagged `fabric_postgres-v0.2.0`. This is the commit `apps/payout_desk` pins.
- `nix/git-sources.nix` no longer registers commit `54a23bc7bcff1fd1018a349b5ac4f5ec2164c3bd`, which nothing pins any more.
- No application handles the handover that `fabric` 0.3 added. Each place that reads how a run ended keeps its catch-all, so a handed-over run is reported as a run that ended without an answer.

## Rationale and consequences

- `fabric` 0.2.0 crashes a process that waits for a run when its store stops during the wait, and crashes the store's sentinel when a script-owned store shuts down with its starter. `fabric` 0.3.1 fixes both. No release of the 0.2 line does, and none is planned: consumers move to the 0.3 line.
- The lower bound is 0.3.1, not 0.3.0, because 0.3.0 has the same two crashes.
- No source changed. No application builds the `HandOver` decision or matches on `policy.Decision` or `input.InputError`, the two types whose new variants break an exhaustive match.
- The adapter's source and SQL migrations are the same at the old and the new commit, so no schema changes.
- `fabric` 0.3 writes agent records in version 10, which a `fabric` 0.2 reader cannot read. An application that stores runs through `fabric_postgres` must not share a database with a node still on 0.2.
