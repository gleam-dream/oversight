# `llm_wire` Wave 3 correction rereview

Date: 2026-09-21  
Baseline: `e643755` plus the current staged, unstaged, and untracked correction set  
Scope: focused rereview of the six findings in `llm-wire-wave3-review.md`

## Verdict

The six findings are corrected in the current recovery set. The credential accessor is gone, Google's tool schema and stop limit match its request contract, missing Google provider IDs no longer leak synthetic application IDs into continuations, and ordinary provider JSON now uses the standard Gleam parser and decoders without a separate strict JSON abstraction. The pool now stops a parked owner when a remote Gun connection dies, and every pool test observes the fallible stop result.

This verdict applies only to the delivered subset. It does not accept the broader Wave 3 capability scope as complete. The strict response-header preallocation requirement also remains unresolved by the current Gun dependency and still needs an explicit contract decision rather than a weakened implementation claim.

## Corrected resource finding

### [P1] Stop the owner worker when its Gun connection dies — corrected

`src/llm_wire_gun_pool.erl` now calls `stop_owner(Entry#conn_entry.owner_pid)` in the Gun monitor `DOWN` branch before removing the `conn_entry`. The successful connector worker has already transferred the connection, been demonitor'ed by the pool, and then waits only for `stop` in `keep_connection_owner/1`; the explicit stop closes this terminal path.

Other removal paths already demonstrate the same invariant: unhealthy checkout, pruning, client death, check-in of a dead connection, pool termination, and late connector cleanup all stop the owner. The remote-connection regression closes a pooled peer, waits for the pool to remove the dead connection, and then verifies a fresh pooled request can proceed. All eight pool tests that stop a pool now assert `Ok(Nil)`, including the seven previously ignored results.

Treatment: **in-place fix applied; ready for focused review**.

## Closed findings

1. **Prepared-call credential exposure:** closed. `api.prepared_headers` has been removed. The dependent-package negative probe attempts that accessor and requires the compiler's unknown-value diagnostic; the probe passes. The execution path still consumes the opaque prepared call internally.

2. **Google tool schema dialect:** closed for the delivered schema subset. Google encoding now uses the provider-specific schema admission function and emits `parametersJsonSchema`, while OpenAI and Anthropic retain their existing fields. Tests cover the emitted field, admitted nullable/list structure, `additionalProperties`, and rejection of an unsupported numeric range.

3. **Google continuation identity:** closed. Parsed calls preserve the optional provider ID separately from the required application call ID. When Google omits its ID, the public event may use a synthetic application ID, but continuation encoding omits `functionResponse.id` instead of retransmitting that synthetic value. The facade's public `ToolCall` remains the three-field provider-neutral shape. The loopback test proves `call_0` is absent from the continuation request.

4. **Duplicate-member JSON complexity and API breadth:** closed by simplification. The broad `wire_json` helper, strict JSON module, and strict JSON FFI are gone. Provider envelopes, requests, responses, and continuation arguments use the standard Gleam JSON parser and decoders. Duplicate-member rejection is not a package contract; Blueprint remains limited to schema-bearing values, tool schemas, structured schemas, and validation.

5. **Google stop-sequence limit:** closed. Preparation rejects more than five Google stop sequences and accepts five. The boundary is exercised in the Google request test.

The pool's original blocking-connect concern is corrected in the delivered subset. Connection establishment now occurs in monitored workers, reservations include both established and connecting entries, unrelated pool messages can proceed during connect, timed-out/dead clients do not receive late results, and `stop` returns an explicit `Result`.

## Scope and contract decision

The updated Wave 3 report correctly describes the broader provider capability matrix as partial. Acceptance of this correction subset should not be restated as completion of all Wave 3 provider behavior, terminal tool-stream behavior, or backpressure coverage.

For response headers, retain the strict contract: success metadata must be captured before body consumption and must not be reconstructed later from Gun state. Current Gun does not expose the needed headers at the required point. The concrete decision remains to patch or pin a Gun interface that exposes them before body processing, or to mark the capability unavailable. Do not silently weaken the contract to fit the dependency.

## Verification

- `nix develop --command gleam test --target erlang`: **pass**, 122 tests, no failures or unused stop-result warnings.
- `nix develop --command sh test/external_package_boundary.sh`: **pass**, including the negative `prepared_headers` compile probe.
- `nix develop --command gleam check --target erlang`: **pass**, with no unused stop-result warnings.
- `nix develop --command gleam format --check src test`: **pass**.
- `nix flake check`: **pass** for the host system; incompatible systems were omitted by Nix.
- `git diff --check` and `git diff --cached --check`: **pass**.
- No strict-JSON scaling probe is retained because the separate strict parser and duplicate-member guarantee were removed by the authoritative JSON boundary decision.

The current recovery set changed the source and tests described above; no commit was created.
