# Relay Wave 3 independent review

## Verdict

- **FAIL — the delivered Wave 3 subset is not accepted yet.** Typed stdio request/response, explicit-CA TLS, expanded protocol corpus, revision pinning, and the retained Wave 2 backpressure path conform to their stated partial boundary. The new HTTP subscription and dynamic-registry subset has two correctness blockers at subscription establishment.
- This review targets the complete dirty Relay working tree against checkpoint `20ad8af`. It judges the delivered subset rather than requiring unsupported retained scope.
- Full Wave 3 and package completion remain unclaimed. Typed stdio subscriptions, owner-death and comprehensive process-count cleanup, official-peer client interoperability, remaining modern families, authorization, compatibility, the public test kit, target matrices, soak/fuzz, and release hardening remain deferred as recorded in `WAVE-3-REPORT.md`.

## Findings

### HIGH · Empty dynamic registries reject the notification they can later produce

`subscriptions/listen` treats current collection contents as the server's lasting notification capability. In `src/relay/server.gleam`, admission computes `has_tools` from `tool.declarations(reg, context) != []` and passes it to `subscriptions.filter_supported`. An empty tool registry therefore acknowledges `toolsListChanged: false`, even though the same live HTTP server publicly supports `register_tool` and will later update that stream runtime.

The later registration reaches the authoritative hub and active runtime, but `handle_register_tool` emits only to streams whose already-honored filter retained `tools_list_changed`. A subscriber that opened against an empty registry can never observe the first registration or any later tool-list change. The integration regression starts with more than 100 tools, so it does not exercise this case.

This violates the work order's live dynamic-registry and list-change notification requirement and the report's claim that accepted tool changes update open streams and emit the notification. Proposed `(in-place-fix, now)`: negotiate against the server's supported mutation/notification capability rather than whether the current collection is nonempty, and add an empty-registry → listen → first-registration regression.

### HIGH · Subscription establishment is not atomic with hub updates

The HTTP handler obtains `HubGetServer` before building the request runtime. It then starts the SSE machinery, admits `subscriptions/listen`, writes the acknowledgement, and only afterward sends `RegisterSubscription` to the hub. A `HubRegisterTool` or notification message handled between the initial snapshot and registration updates the authoritative hub but cannot update or notify the still-unregistered stream runtime.

This creates an observable lost-update interval. It is especially damaging with an initially empty snapshot because the stale runtime also permanently filters out `toolsListChanged`; with a nonempty registry it can still acknowledge a subscription and miss the change that occurred during establishment. The integration test calls `register_tool` after the client receives the acknowledgement, but the acknowledgement is written before hub registration, so the test does not force or exclude the adverse hub ordering.

This violates owner-bound live subscription semantics and the report's claim that open streams follow the authoritative registry. Proposed `(in-place-fix, now)`: establish the stream against the hub atomically, or carry a hub revision through admission and reconcile every update after registration before exposing successful establishment. Add a deterministic barrier regression that performs a registry update between snapshot/admission and active registration and proves both the notification and subsequent stream state.

## Accepted delivered evidence

### Typed stdio subset

The stdio client launches a resolved executable directly with an argument vector, without a shell fallback. Its owning actor serializes request/response work, uses string request IDs, discards valid no-ID notifications while awaiting a response, rejects unrelated or malformed response IDs, frames newline-delimited replies with a configured limit, applies a bounded wait, and closes the child on timeout, protocol failure, explicit close, or actor-owner death. Close uses a monitor, so repeated and concurrent close do not depend on an acknowledgement from an already-dead actor.

The request/response subset is accepted. Typed stdio `subscriptions/listen`, notification consumption, direct creator-owner-death evidence, comprehensive process-count cleanup, and official-peer fixtures remain outside the accepted subset and are correctly reported as unfinished.

### HTTP client and TLS subset

The typed HTTP client now traverses tool, resource, resource-template, and prompt pages through the shared checked request path. The explicit CA connection passes the CA file to Gun with `verify_peer`; Gun 2.6.0's `ensure_tls_opts` adds HTTPS hostname matching and SNI when absent. The local test proves default system trust rejects the test CA and explicit trust succeeds. The subscription client correlates the acknowledgement and subsequent notifications by subscription request ID and bounds its buffered SSE data.

### Revision and schema semantics

The modern codec admits only `2026-07-28` request metadata and reports that revision in discovery. No legacy handshake or compatibility path was introduced. The reported `ping` discrepancy is visible rather than silently implemented against a frozen schema that has no matching request/response definitions.

The protocol corpus now emits 17 actual Relay messages, including the listen request, acknowledgement, resource update, and three list-change notifications. All 17 validate against named frozen-schema definitions, and 40 malformed single-field mutations are rejected. This is meaningful additional coverage, but it validates wire shapes rather than the two establishment behaviors above.

### Retained backpressure and lifecycle behavior

The synchronous handler-progress → runtime → broker → Mist writer chain is retained. The held-writer mailbox and real burst-disconnect regressions remain in the 94-test suite, and no new path bypasses the status-returning SSE writer. The new subscription notifications use the same runtime writer and broker, so transport failure closes that subscription runtime and the hub removes the active stream after receiving the terminal control signal.

## Independent evidence

- `nix develop --command gleam test --target erlang` passed twice during review: **94 passed, 0 failed** on each run. Expected untrusted-CA and broken-child diagnostics appeared.
- `nix develop --command python3 scripts/relay_schema_check.py` passed: **17 wire messages** matched the frozen schema and **40 malformed mutations** were rejected.
- `scripts/conformance/run-server-suite.sh` passed: **40 scenarios, 109 emitted checks passed, 0 failed**. `input-required-result-missing-input-response` emitted **0 checks**, so it is not an independently asserted scenario pass.
- `nix develop --command gleam format --check` passed.
- `nix develop --command gleam check` passed with the already-recorded authorization/test-kit TODO and unused-constructor warnings.
- `nix develop --command python3 scripts/check_negative_fixtures.py` passed: **1/1** negative compiler fixture was rejected with expected diagnostics.
- `nix develop --command ./scripts/verify_checksums.sh` passed for the frozen schema and exact Blueprint/Sinal pins.
- `git diff --check 20ad8af` passed.

## Acceptance boundary

Accepted as a correct partial subset: typed stdio request/response methods with correlation, bounds, deadline and close behavior; explicit-CA HTTPS with peer and hostname verification supplied by Gun; the expanded modern wire corpus; the retained local HTTP response-backpressure and disconnect-cancellation path; and strict `2026-07-28` codec behavior.

Rejected pending repair: the claim that HTTP `subscriptions/listen` and dynamic tool registration provide reliable live list-change delivery. Empty registries suppress the capability, and the snapshot-to-registration interval can lose an update.

Not assessed as defects: typed stdio subscriptions, comprehensive owner/process cleanup, official-peer client fixtures, and the other rows explicitly retained for later work. Those remain package-completion gaps, not additional blockers in this review.
