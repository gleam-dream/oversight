# ADR 0007: Separate definition bugs from runtime input

<a id="adr-0007"></a>

## Decision

- Invalid source-authored definitions are programmer errors. Runtime definitions and untrusted input retain typed checks and admission failures.
- Avoid propagating an expected `Result` through ordinary calls solely for an invalid static definition that callers immediately assert.
- Document when each package detects a source error. An explicit check lets applications validate definitions before exposing a boundary.

## Context and alternatives

- Typed constructor errors made normal definitions accumulate assertions. Deferring those errors into every data operation made a source bug resemble recoverable bad input.
- The accepted policy preferred an informative panic for source mistakes and typed runtime validation. It did not authorize collapsing ordinary parsing, schema rejection, or operational failures into panics.
- The old decision prose claimed construction-time rejection for both Sinal and Blueprint. Blueprint actually discovers some definition errors on first affected use; the new package layer records that implementation distinction instead of repeating the stronger claim.

## Consequences

- Public startup validation and package tests must exercise definitions that otherwise appear only on rare branches.
- Broadening schema support and improving malformed-versus-unsupported classification are separate decisions from source-definition panic policy.

## Provenance

- Accepted policy: [release decision 4](https://github.com/gleam-dream/oversight/blob/3baff70/docs/release-api/DECISIONS.md). The exact acceptance date is not stated independently in that source.
- Sinal and JSON Blueprint ADRs retain their implementation-specific evidence and rejected alternatives.
