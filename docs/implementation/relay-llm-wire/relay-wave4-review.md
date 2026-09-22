# Relay Wave 4 independent review

## Verdict

- **FAIL — the focused Wave 4 delivery is not accepted yet.** The `_json` compatibility split and ordinary-JSON list transport follow the work order, and the stdio happy path works, but the authorization seam grants configured permissions instead of verified permissions, the typed declarations reject or erase valid frozen-schema fields, and the stdio subscription implementation does not preserve ordered bounded lifetime semantics.
- This review targets the complete dirty Relay tree against checkpoint `c293b53`. It judges the delivered Wave 4 subset rather than requiring deferred cryptography, protected HTTP middleware, client OAuth, legacy compatibility, Tasks/Apps, or full test-kit work.
- The Wave 3 accepted subset remains accepted. The defects below are confined to the new Wave 4 surfaces.

## Findings

### HIGH · Admission fabricates grant authority and protected dispatch does not recheck it

- **Adherence and spec · `src/relay/authorization.gleam:63-83,124-165,182-216` ·** The verifier returns only `principal`. After it succeeds, `admit` copies `ProtectionConfig.resource` and `ProtectionConfig.required_scopes` into the grant as though the token attested them.
- Relay therefore cannot check the token's actual audiences or scopes, reject an additional audience, or retain extra attested scopes. A verifier configured for one resource can also be passed a different `ProtectionConfig` because the verifier callback does not receive the configuration and returns no attestation.
- `dispatch_granted` never reads `ProtectedRegistry.protection`. A grant created for resource A or a weaker endpoint scope set can enter a registry configured for resource B or stronger scopes before visibility, execution policy, decoding, and handler invocation.
- This contradicts `relay-design.md` sections 2.7 and 3.1 and `research/relay-resource-authorization-contract.md`'s executable pure boundary. Those contracts require a verifier attestation containing principal, audiences, and actual scopes; exact admission checks; retained actual scopes; and registry-specific rechecks.
- The two authorization tests prove only that a principal-returning callback succeeds or fails. No test constructs a protected registry, dispatches through it, filters listing visibility, rejects a wrong audience or missing scope, rejects cross-resource grant reuse, or proves denial precedes decoding and handler execution.
- Proposed **`(in-place-fix, now)`**: implement the already-designed `VerifierAttestation`, `AdmissionError`, and grant-use checks; retain actual attested scopes; add `visible_declarations`; and test the decisive pure cases recorded in the authorization contract. Keep HTTP extraction, challenges, cryptographic verification, and transport routing deferred and unclaimed.

### HIGH · Typed declaration models diverge from the frozen declaration schema

- **Spec · `src/relay/client.gleam:86-136,1208-1231,1436-1539` ·** `Prompt.arguments` is optional in the frozen `2026-07-28` schema, but `decode_prompt_declaration` requires the field. A conforming peer that returns `{ "name": "prompt" }` is rejected.
- `Tool.annotations` uses `content.Annotations`, which models audience and priority. The frozen `ToolAnnotations` type instead carries `title`, `readOnlyHint`, `destructiveHint`, `idempotentHint`, and `openWorldHint`; the decoder silently drops the four behavior hints.
- Resource annotations use the same `content.Annotations`, but the frozen generic `Annotations` carries `audience`, `priority`, and `lastModified`. Relay drops `lastModified` and exposes unrelated `title` and `description` fields.
- All four frozen declaration types can carry `icons`, but the new typed declarations omit icons entirely. The live test checks only name or URI fields from Relay's own peer, so it cannot detect these schema mismatches.
- Proposed **`(in-place-fix, now)`**: model the frozen `Icon`, generic `Annotations`, and `ToolAnnotations` types separately; decode optional prompt arguments as `[]` or an explicit option; preserve every current declaration field; and add fixture cases copied from the frozen schema shapes. Ordinary peer JSON may remain `json.Json` for arbitrary `inputSchema`, `outputSchema`, and `_meta`; this does not require moving protocol envelopes back to Blueprint.

### HIGH · Closing a stdio subscription performs no protocol action

- **Spec and robustness · `src/relay/client.gleam:157-170,600-719` ·** `close_subscription` promises to cancel one stream without closing other requests. Its `StdioSubscription` branch returns `Nil` without sending `notifications/cancelled`, marking the subscription closed, or removing buffered notifications.
- The frozen schema defines `notifications/cancelled` as the client notification that cancels a previously issued request, and Relay's server already handles cancellation of `StreamExchange` records at `src/relay/server.gleam:1250-1291`. The stdio client does not encode or send that existing contract.
- A closed subscription object therefore remains usable, and its server continues producing notifications on the shared child until the entire client closes or the buffer fails. The only new stdio subscription test calls `close_subscription`, but the fixture exits after two frames, so the no-op is not observed.
- Proposed **`(in-place-fix, now)`**: send a correlated `notifications/cancelled` frame through the owned stdio actor, record the subscription as closed, discard only its buffered notifications, and make repeated close idempotent. Add a fixture that remains alive, observes the cancellation frame, and proves other stdio requests still work.

### HIGH · The bounded stdio queues reverse, lose, and orphan data at their boundaries

- **Craft and robustness · `src/relay/transport/stdio_client.gleam:329-383,480-605` ·** `enqueue_notification` prepends each frame, while `take_notification` reads from the head. Notifications retained while a request is waiting are therefore delivered in reverse arrival order.
- `await_notification` consumes port messages into a derived state, but `AwaitError` carries no state. On timeout, `NextNotification` resumes the original state at lines 329-344, so nonmatching notifications received during the wait are lost even though their port messages have already been consumed.
- When an idle `ClientPortMessage` produces more than 256 buffered frames, `append_frames` fails and the actor sets `port_owner` to `None` at lines 371-381 without calling `ffi_close_stdio_client_port`. Relay loses the handle while the child process can remain alive.
- The 256-frame constant therefore bounds retained lists but does not establish ordered delivery or terminal overflow cleanup. The single acknowledgement-plus-notification fixture exercises neither multiple queued notifications, cross-subscription timeout retention, nor overflow.
- Proposed **`(in-place-fix, now)`**: use a FIFO queue representation, return the evolved state with timeout errors, and close the retained port before clearing it on every overflow path. Add deterministic fixtures for two notifications received during another request, a timed-out wait for subscription A while subscription B receives data, and a 257-frame burst with child-exit evidence.

## Accepted delivered evidence

### JSON and Blueprint boundary

- List-page envelope parsing and `_json` compatibility methods now use ordinary Gleam JSON, which follows the Wave 4 direction. Arbitrary peer `inputSchema`, `outputSchema`, and `_meta` values remain ordinary `json.Json` rather than a duplicate strict JSON layer.
- Structured tool input/output continues to use Blueprint codecs and values. The Wave 4 list refactor does not introduce a second schema DSL or replace the server registry's codec-derived schemas.

### Stdio happy path

- The stdio actor serializes requests and subscription reads on one owned child. The direct fixture proves one batch containing an acknowledgement followed by one list-change notification is split, correlated by subscription ID, and decoded in that order.
- Frame byte limits, the 256-frame list checks, request-ID rejection, timeout handling, child-exit handling during an active wait, and shared client close remain present. The finding concerns queue semantics, per-subscription close, and overflow cleanup rather than the basic handshake.

### Honest deferrals

- `WAVE-4-REPORT.md` does not claim JWT/JWKS, introspection, RFC 9728 metadata or challenges, protected HTTP middleware, client OAuth, `2025-11-25`, Tasks/Apps, or release readiness. Those substantial subsystems remain correctly deferred.
- The new authorization code is not connected to HTTP or server routing, so it cannot support a protected deployment. The report describes it as a pure seam; this review rejects the seam's current authority semantics without converting the deferred transport work into an additional finding.
- The test-kit constructors no longer contain crashing TODOs. They remain markers rather than a full paired transport or configurable authorization server, and the report states that limitation.

## Independent gates

- `nix develop -c gleam test --target erlang` passed: **102 tests, 0 failures**. Expected untrusted-CA and broken-child diagnostics appeared.
- `nix develop -c python3 scripts/relay_schema_check.py` passed: **17** messages matched the frozen schema and **40** malformed single-field mutations were rejected. This corpus validates protocol messages, not the new client declaration decoders.
- `./scripts/conformance/run-server-suite.sh` passed: **109 emitted checks across 40 scenarios, 0 failed**. `input-required-result-missing-input-response` emitted zero checks. The suite exercises the unprotected HTTP server, not Wave 4 authorization or stdio client behavior.
- `git diff --check c293b53` passed.

## Acceptance boundary

- Accepted as additive partial work: ordinary-JSON declaration transport and `_json` compatibility naming; retention of Blueprint for schema-bearing structured tool values; the stdio subscription acknowledgement and one-notification happy path; constructible verifier and grant vocabulary; and noncrashing minimal test-kit markers.
- Rejected pending repair: the authorization grant and registry authority checks; exact frozen-schema typed declarations; stdio per-subscription close; ordered notification retention; timeout preservation; and overflow child cleanup.
- Still deferred rather than newly defective: protected transport integration, bearer extraction, challenge and metadata mapping, JWT/JWKS or introspection, client authorization, legacy compatibility, official direct TS/Python client fixtures, full paired transport and authorization server helpers, owner/process-count coverage, Tasks/Apps, logging, target matrices, soak/fuzz, and release hardening.
