# Cross-package integration pilot

## Question

Can a small consumer compose the actual public APIs of Blueprint, Relay, LLM Wire and Sinal to perform a complete typed tool interaction, including failure and cancellation, without reaching into package internals or duplicating codecs?

## Scope

- Build a runnable Gleam consumer at `playground/ecosystem_pilot` in Oversight. Use sibling path dependencies: Relay `6574f38`, LLM Wire `cdfb38a`, and the current pinned Blueprint/Sinal revisions. Record observed exact heads.
- Use a small checked-in synthetic inventory/order dataset. Expose one read-only lookup tool with typed input and output. Blueprint codecs define the tool schemas and encode/decode values once; ordinary provider and MCP envelopes use Gleam JSON.
- A host application prepares an LLM Wire interaction. A local scripted provider returns a realistic complete tool-request turn. The host executes the tool through a real Relay client/server transport, submits the typed result through LLM Wire continuation, then receives a final answer. The host, not the LLM client, owns tool execution.
- Use the supported OpenAI Responses adapter initially, retaining explicit provider scope. Prefer real stdio for Relay if its launcher is straightforward; otherwise loopback HTTP is acceptable. Use actual transport boundaries, not direct handler shortcuts.
- Attach real Sinal handlers and capture typed lifecycle evidence without recording raw prompts, tool arguments or credentials. Clean up attachments, sockets and child processes.
- Use existing pinned provider/MCP fixtures and provenance where helpful. Mock only the external provider service; do not mock our own four packages. The local server must validate actual requests and continuation content, not return success regardless of what the consumer sends.

## Required scenarios

- Valid lookup: typed input, correct dataset result, exact call/result correlation, provider final answer and observable lifecycle.
- Invalid tool arguments: typed rejection before invoking the tool; prove no handler execution.
- Tool failure: a deliberate missing record produces the declared tool error and preserves continuation/correlation policy.
- Cancellation while provider response is in progress: prompt cleanup, no subsequent tool invocation and no leaked test-owned process.
- Provider error/disconnect: clear error outcome and no hidden retry or duplicated tool effect.

## Simplicity and boundaries

- Use public package APIs only. No internal module imports, foreign representation casts, copied production code, duplicate schema definitions, custom JSON parser or new general framework.
- Keep the dataset and scenario small. This is an integration consumer, not Fabric, Saga, a UI or a new workflow engine.
- If composition requires awkward glue, record the exact call-site friction and minimal suggested package change. Do not modify sibling packages during this pilot; report a blocker and continue independent scenarios.
- No live provider calls, paid requests, real credentials or external data transmission. Provide a documented future live-run path only if it is straightforward; do not execute it.
- No commits/push/publication by implementer. Preserve unrelated Oversight work. Main orchestrates; Luna 6 Max implements; Sol 6 XHigh reviews.

## Authorized follow-up

The user authorized fixing the application-error propagation gap discovered by
the pilot and committing the reviewed result. This follow-up may modify Relay
and the consumer's error assertion. Preserve the declared application error
across the MCP boundary using the existing codec contract where practical;
unexpected internal failures must remain distinct. Keep the change focused and
verify the full missing-record continuation over HTTP.

## Delivery

- Write PROGRESS.md within the pilot immediately, then update at milestones.
- Provide a runnable example, one documented test command, meaningful integration tests and deterministic resource cleanup. Reuse the root development shell rather than adding infrastructure unnecessarily.
- Run formatting, compiler, consumer suite and applicable repository checks synchronously. Record exact checks and limitations.
- REPORT.md must distinguish what composes cleanly, actual blockers, optional ergonomic improvements, and what remains unproved about live provider operation. Include exact dependency heads, fixture provenance, scenario results and complexity avoided.
- Success means all named scenarios run through actual public boundaries. Passing individual package suites does not establish pilot acceptance.
