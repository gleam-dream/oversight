# Relay Wave 3 focused re-review

## Verdict

- **FAIL — the subscription-establishment repair is not accepted yet.** The two prior race cases now behave correctly in the tested path, but the repair introduces an unbounded tool-change journal in the long-lived HTTP hub. Each accepted registration or removal retains another entry, including registered tool closures, and each later subscription scans the complete journal.
- This review targets the repair for the two HIGH findings in `relay-wave3-review.md` within the complete dirty Relay tree against checkpoint `20ad8af`. It is a subset verdict rather than full Wave 3 or package acceptance.
- The previously accepted Wave 3 subset remains accepted. The deferred package work listed in `WAVE-3-REPORT.md` remains outside this focused verdict.

## Finding

### HIGH · Race reconciliation retains unbounded history and can silently miss hub activation

- **Craft · `src/relay/transport/http.gleam:80-85,108-124,151-183,199-210,943-949` ·** `HubState.changes` starts empty and prepends every successful registration and removal without any truncation, acknowledgement, active-admission watermark, or retention limit. `tool_changes_since` filters the entire list and reverses its result for every new subscription, even when `since_revision` is the latest revision.
- The journal therefore grows with server lifetime rather than with the number of subscription admissions currently crossing the snapshot boundary. It also retains complete `ContextTool` values and their handler closures after later removal. Long-running dynamic-registry churn causes unbounded memory retention and an O(total historical changes) serialized hub operation for each subscription.
- The HTTP handler waits only 1,000 ms for `RegisterSubscription` and discards the receive result. A sufficiently long journal scan, a stopped hub, or a failed hub can therefore leave a client with an already-written subscription acknowledgement while the stream was never added to `state.subscriptions`. This turns the journal's resource defect into the same externally visible lost-notification behavior that the repair is intended to remove.
- Proposed `(in-place-fix, now)`: retain reconciliation state only for admissions that can still present an older snapshot, or replace the journal with a bounded atomic registration/snapshot protocol. Handle registration failure or timeout explicitly, close the stream, and add churn/retention plus failed-registration regressions. The repair must preserve ordered replay without storing lifetime history.

## Prior finding closure

### Empty dynamic registry

- The original capability error is closed. `src/relay/server.gleam:981-990` now treats tool list-change support as a server capability independent of current registry contents. The empty-registry regression at `test/relay/client_test.gleam:713-721` uses the same deterministic helper as the populated case and asserts the acknowledged filter, `ToolsListChanged`, and the subsequent tool listing.

### Snapshot-to-registration race

- The original ordinary-path race is closed. `HubGetServer` returns the authoritative server with its revision. `RegisterSubscription` replays changes with greater revisions in ascending order before adding the subscription. The hub actor serializes registration against later mutations, so a mutation processed before registration is replayed and one processed afterward is sent through the active subscription.
- The runtime receives each replayed registry mutation before its corresponding notification from the same hub process. BEAM sender ordering therefore preserves replay order at that runtime mailbox. The hub uses asynchronous sends for replay and does not wait on the runtime, so this path introduces no cyclic wait or direct deadlock.
- The deterministic helper at `test/relay/client_test.gleam:728-844` blocks request context after the hub snapshot, performs `register_tool`, then releases admission. It runs against empty and populated initial registries. Both cases passed in the independent 96-test run.

## Independent gates

- `nix develop --command gleam check --target erlang` passed with only the recorded Wave 4 authorization and Wave 5 test-kit TODO/unused-constructor warnings.
- `nix develop --command gleam test --target erlang` passed: **96 tests, 0 failures**. Expected untrusted-CA and broken-child diagnostics appeared.
- `nix develop --command python3 scripts/relay_schema_check.py` passed: **17** messages matched the frozen schema and **40** malformed mutations were rejected.
- `nix develop --command python3 scripts/check_negative_fixtures.py` passed **1/1**; `nix develop --command ./scripts/verify_checksums.sh` passed; `nix develop --command gleam format --check` passed; and `git diff --check 20ad8af` passed.
- `./scripts/conformance/run-server-suite.sh` passed: **109 emitted checks across 40 scenarios, 0 failed**. `input-required-result-missing-input-response` emitted zero checks and is not an independently asserted scenario pass.

## Acceptance boundary

- Accepted as closure evidence: empty registries retain `toolsListChanged`; a tool change forced between snapshot and activation is replayed in order; a later list observes the registered tool; and the ordinary replay path has no cyclic wait.
- Rejected pending repair: using a server-lifetime journal as the reconciliation mechanism and ignoring the hub-registration receive result. Passing functional and conformance suites do not exercise journal retention, churn-dependent establishment latency, or hub-registration failure.
- Not reassessed as new defects: typed stdio subscriptions, comprehensive owner/process cleanup, official-peer client fixtures, remaining modern families, authorization, compatibility, public test kit, target matrices, soak/fuzz, and release hardening. These remain declared completion gaps.
