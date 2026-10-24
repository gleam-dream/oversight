# Bound owned work with explicit policy

<a id="adr-0005"></a>

## Decision

- Libraries provide finite defaults for the resources and work they own. Configuration names the limit and permits a deliberate larger or unbounded value where the domain supports it.
- A caller's per-request settings must reach the transport without an unrelated inner default silently shortening the promised interval.
- Execution, admission, settlement, cleanup, and durable waiting are separate intervals. A timeout documents which interval it bounds.
- Session eviction and unavailable model-token accounting remain application policy: Warden does not impose a session-per-identity cap, and Fabric token budgets are opt-in.

## Alternatives and consequences

- Unbounded work by default makes a small facade hide operational cost. Arbitrary caps can instead impose application policy; session eviction is an example.
- One universal deadline type would not by itself align the distinct intervals. Consumers need explicit propagation and enough remaining time for cleanup.
- Approval and graph waits default to seven days for new runs. Previously persisted records without deadlines retain no deadline; applying a new default retroactively would change durable behavior.
- The owning package documents actual numerical defaults and setters. Oversight does not duplicate a table that can silently drift.

## Provenance

- Accepted default policy and numerical baseline: [decision 5](https://github.com/gleam-dream/oversight/blob/3baff70/docs/release-api/DECISIONS.md). The recorded 3 October 2026 follow-up distinguishes new waits from stored records.
- Current source determines implemented values. Later review found that Relay admission callbacks precede dispatch timeout and Saga cleanup follows its drive wait; their designs retain those boundaries and unresolved contract questions.
