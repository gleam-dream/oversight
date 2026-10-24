# Separate transport failure from contract failure in replayed acquisition

<a id="adr-0023"></a>

## Decision

- On 7 October 2026 the repository retained an instrument replay experiment. HTTP Gun owns transport, recording, redaction and client lifetime, JSON Blueprint owns bounded parsing, codecs and schema validation, and Sinal owns typed observations. The application owns pagination, run identity, schema selection and recovery policy.
- The acquisition function accepts one client for both live capture and offline replay.
- The application keeps four distinct budgets: HTTP collection, JSON admission, cassette capture and waiting.
- Independent runs replay one immutable capture through independent playback cursors. Correlation is observation metadata and does not participate in request matching.

## Rationale and alternatives

- A schema error cannot replace HTTP submission evidence, so the application's admission failure keeps the underlying transport, parse, schema or decode failure for retry or review decisions.
- A shared cassette queue is not a request router. Redacting a token deliberately removes it from request identity, so a token that selects different data needs another distinguishing request field.
- Validation witnesses carry the schema that admitted them, which stops a new decoder from reinterpreting an old witness.

## Consequences

- All seven planned cases passed: two-page acquisition over loopback, offline replay with the server stopped, contract evolution, failure separation, redaction and identity, concurrent correlation, and ownership with cancellation. No package defect was found.
- Cleanup evidence covers completed and refused operations, recorder publication and local stop. It does not establish crash durability, filesystem-failure cleanup, active-request cancellation settlement or arbitrary concurrent cassette recording.
- The fixture is authored synthetic data, and the experiment claims no scientific accuracy, live-provider qualification or upstream conformance. Development failures were consumer and environment issues and not package defects.
