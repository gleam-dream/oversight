# Share correlation without owning tracing

<a id="adr-0006"></a>

## Decision

- Sinal owns the shared validated correlation value: an opaque string of at most 128 bytes.
- A W3C trace identifier is an admissible value, but correlation does not implement a full trace context or authenticated identity.
- Applications choose ingress, propagation, redaction, and export policy. Package operations emit facts at the lifecycle boundaries they own.

## Alternatives and consequences

- Independent nearly identical correlation types required repeated conversion with no useful difference in semantics.
- A complete tracing framework would add parent/span/export and baggage policy beyond the shared observation need. A separate causation field was deferred pending a concrete tracing consumer.
- Native telemetry dispatch is synchronous. Bounded forwarding is an explicit Sinal route, not an assumed property of every observation call.
- Correlation reuse does not give one library authority over another library's execution, retry, principal, or persistence policy.

## Provenance

- Accepted in [release decision 3](https://github.com/gleam-dream/oversight/blob/3baff70/docs/release-api/DECISIONS.md); the source does not separately date the initial acceptance.
- The [shared-foundation research](https://github.com/gleam-dream/oversight/blob/3baff70/research/shared-foundations.md) motivated independent typed observation and JSON foundations. The Sinal repository owns native dispatch and forwarding details.
