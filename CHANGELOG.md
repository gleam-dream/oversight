# Changelog

## Unreleased

- Remove Warden's replay of initial signing keys on cache restart. Record
  fresh discovery, bounded manual startup, failure cleanup and the measured
  cost of forwarding larger key sets.
- Correct Relay's intentional listener shutdown so a linked shutdown exit
  cannot terminate the endpoint's caller. Preserve unexpected listener-failure
  propagation and record the deterministic tool_hub validation finding.

- Bind Warden discovery, metadata reload and key refresh work to its cache
  process. Late results cannot restore removed signing keys in a replacement
  cache; owner exit cancels fetch work without changing the public API.
- Sequence Warden whole-tree restarts after the previous owned processes exit.
  Reuse the startup deadline instead of racing their registered names.
- Round 9 typed composition: separate classification protocols from fresh
  live configuration, admit provider-neutral typed answers, retain optional
  confidence and usage, and reject incompatible receipt/live limits before I/O.
- Migrate support_desk to Saga's full typed execution reports and operational
  reporting errors; complete safe summaries retain every effect-evidence category.
  The readable recipe grows from 47 to 59 lines, with no business-logic change.
- Record deterministic fixture cleanup for Fabric shutdown and Warden discovery
  telemetry; retain production behavior and all correlation assertions.
- Round 9 review: migrate tool_hub to presence-preserving discovered replies;
  record the approved invocation-evidence, classification-budget and saga
  startup fixes, followed by the typed APIs and complete summaries above.
- Stabilize the Relay refused-connection and Warden expiry fixtures with
  reserved sockets and a fixed expiry/clock; production behavior is unchanged.
- Round 9: record convention 11 and the 5 October package ownership decisions;
  reduce the planned package set from 14 to 11 through ports and compiled
  recipes, retaining both PostgreSQL adapters.
- Migrate support_desk and tool_hub, preserve their integration tests and
  correlated demos, and document code cost and remaining composition friction.
- Refresh design and audit references; add the Round 9 migration guide and
  ecosystem results to the release plan.
