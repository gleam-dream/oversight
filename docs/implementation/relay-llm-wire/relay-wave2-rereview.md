# Relay Wave 2 independent rereview

## Verdict

- **FAIL — the corrected checkpoint is not accepted as a correct delivered subset.** The five findings in the first Wave 2 review are closed, and the recorded partial-scope boundary is substantially accurate. The local HTTP subset still claims response backpressure and prompt termination on disconnect that do not hold when a handler produces progress faster than the socket consumes it.
- The target is the dirty Relay working tree against checkpoint `ce718db`. This review judges the delivered Wave 2 subset rather than the retained full Wave 2 scope. The required single-reviewer procedure was used because the assignment prohibited subagents; the four review axes below were run serially.

## Adherence

- **HIGH · HTTP semantic backpressure does not reach the progress producer.** The Wave 2 work order requires bounded response streaming and semantic backpressure. The runtime progress callback only sends `WorkerProgress` to the runtime actor and immediately returns ([`src/relay/runtime.gleam:335`](/code/gleam-dream/relay/src/relay/runtime.gleam:335)), so a fast handler can enqueue an unbounded number of progress messages before the Mist writer acknowledges one frame. The transport broker serializes socket writes, but it does not bound the upstream runtime mailbox. This is divergent from the work order and from the implemented claim in [`WAVE-2-REPORT.md:52`](/code/gleam-dream/relay/WAVE-2-REPORT.md:52). Proposed `(in-place-fix, now)`.
- The five prior blockers conform to their corrected acceptance boundary. The six service families emit schema-valid modern fields; logging is request metadata without a legacy route or advertised emitter; idle-stdin broken stdout terminates the child; duplicate exchange replay does not consume live capacity; and continuation fields are retained for tool/prompt handlers or rejected for unsupported resource reads.
- The explicit incomplete rows remain intentional work rather than false acceptance: subscriptions/listen, change notifications, dynamic registry changes, typed tool declarations, client stdio and subscription methods, local TLS evidence, interoperability fixtures, broader cleanup evidence, authorization, legacy compatibility, and the public test kit remain open.

## Spec

- **HIGH · Disconnect cancellation can be delayed behind queued progress frames.** An SSE probe reports disconnect and stops its actor ([`src/relay/transport/http.gleam:639`](/code/gleam-dream/relay/src/relay/transport/http.gleam:639)), while the broker retains that actor subject and waits up to the full request timeout for delivery acknowledgements ([`src/relay/transport/http.gleam:712`](/code/gleam-dream/relay/src/relay/transport/http.gleam:712)). `runtime.close` and `runtime.stop` are ordinary messages sent after the disconnect signal, so progress already queued in the runtime actor can delay cancellation; each delivery to the dead SSE actor can consume another timeout. The current regression emits one progress value and then sleeps ([`test/relay/http_test.gleam:395`](/code/gleam-dream/relay/test/relay/http_test.gleam:395)), so it does not exercise queued progress. This does not satisfy the work order's disconnect, cleanup, bounded-mailbox, and semantic-backpressure obligations for the claimed local HTTP subset. Proposed `(in-place-fix, now)`.
- No other delivered-slice spec defect was found. The pinned server suite passed all emitted checks, but its clean result does not cover the progress-producer queue described above.

## Standards

- No documented repository-standard violation was found. Formatting, type checking, tests, frozen-schema validation, negative compilation, provenance verification, flake checks, and `git diff --check` passed under the repository's declared commands.
- The report keeps the automatic-review decision intact: no public logging emitter was restored, and no alternate path sends handler-provided log JSON to a client.

## Craft

- **HIGH · robustness · malformed-load probe fails.** A handler that calls `report_progress` repeatedly can allocate runtime mailbox work independently of socket progress. The repair must make progress submission bounded or acknowledgement-driven through the runtime-to-handler boundary, mark the broker disconnected without waiting repeatedly on a dead actor, and let close/cancel pre-empt queued progress. Recommendation strength: `strong`. Proposed `(in-place-fix, now)`.
- **Test smell · the disconnect regression proves only a single-progress case.** Add a real loopback regression whose handler floods progress, disconnect the TCP peer after response headers, and assert bounded queue/process behavior plus prompt handler termination. The test must fail without the repair and must not infer boundedness only from successful socket delivery. Recommendation strength: `strong`. Proposed `(in-place-fix, now)`.
- The modeling, depth, composition, state, and invariant lenses found no additional blocker within the delivered slice. Public incompleteness remains visible rather than being hidden by stubs in the claimed surface.

## Independent evidence

- `nix develop --command gleam format --check src test` passed.
- `nix develop --command gleam check --target erlang` passed with the recorded authorization/test-kit TODO and unused-constructor warnings.
- `nix develop --command gleam test --target erlang` passed: **86 passed, 0 failed**.
- `nix develop --command python3 scripts/relay_schema_check.py` passed: **11 wire messages** matched the frozen schema and **34 malformed mutations** were rejected.
- `nix develop --command python3 scripts/check_negative_fixtures.py` passed: **1 negative compiler fixture** was rejected as expected.
- `nix develop --command ./scripts/verify_checksums.sh` passed for the frozen MCP schema and exact Blueprint/Sinal pins.
- `nix flake check` passed on `aarch64-darwin`; Nix omitted the three incompatible systems recorded in the implementation report.
- `git diff --check ce718db` passed.
- `scripts/conformance/run-server-suite.sh` passed against the local HTTP endpoint: **40 scenarios, 106 checks passed, 0 failed**. `input-required-result-missing-input-response` emitted no checks for this revision, so the run is not 40 independently asserted scenario passes.

## Acceptance boundary

- Accepted evidence: the five prior Wave 2 findings are fixed; the schema gate covers all six delivered service-result families; the frozen server HTTP suite is integrated and passes every emitted check; the delivered typed HTTP client basics preserve exact structured numbers and distinguish tool outcomes; the implementation and README correctly withhold full Wave 2 and full-conformance claims.
- Rejected claim: worker-driven progress, response backpressure, and disconnect cancellation are not accepted as a correct local HTTP subset until the producer boundary is bounded and a progress-flood disconnect regression passes.
- Full Wave 2 remains unaccepted for the incomplete rows already listed in `WAVE-2-REPORT.md`. Those rows are retained scope and are not additional rereview findings.

## Routing

- Adherence finding: `(in-place-fix, now)`.
- Spec finding: `(in-place-fix, now)`.
- Craft finding and regression: `(in-place-fix, now)`.
- Frontdesk routing is not invoked by this review.
