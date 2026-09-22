# Integration pilot review

## Verdict

The focused Relay application-error follow-up is ready to commit. Relay now sends the exact JSON value produced by the declared error codec in an MCP `isError` text block. The public client retains that text; the pilot decodes it with the same codec and continues the OpenAI tool call under `call_1`. An error-codec encoding failure still produces a sanitized JSON-RPC internal error. The change uses public package APIs and does not introduce another error schema or transport.

The runnable pilot crosses real loopback HTTP boundaries for Relay and LLM Wire. The scripted provider validates the expected tool schema, request, single correlated continuation result, and final response. The invalid-arguments scenario now starts with a malformed provider tool call and proves Blueprint rejects it before the Relay handler runs. The example exits unsuccessfully if its interaction fails, after cleaning up its local resources.

## Evidence

- Reviewed Relay's `server.gleam` change and the HTTP client regression for an object-valued application error plus an error-codec encoding failure.
- Reviewed the pilot's five scenarios, provider fixture, consumer API calls, and report against `integration-pilot.md`.
- Independently ran the pilot suite: **5 passed, no failures**. The sandbox initially denied local socket creation; the same suite passed with loopback socket permission.
- The implementing agent separately reported green Relay and pilot suites, pilot type and format checks, and the runnable example. This review did not independently rerun those other gates.

## Remaining limits

- Cancellation proves LLM Wire stream closure, provider socket closure, lifecycle events, and no handler message. It does not run a host dispatch loop after cancellation.
- The provider-disconnect scenario proves a typed transport error and no retry during its 1.6-second observation window. It disconnects before any tool call, so it does not prove duplicate-effect protection after tool execution.
- Test teardown is explicit after assertions. An early assertion failure can skip cleanup of the unlinked scripted-provider worker and Sinal attachments.
- No live provider, external network, credential, TLS, rate-limit, or model behavior was tested. The observed path dependencies do not pin Git commits.

These limits do not block the focused error-propagation fix. They bound what the pilot establishes and should remain visible in its report; the pilot is not evidence of production readiness.
