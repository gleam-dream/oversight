# LLM Wire Wave 2 work order: usable calls, continuation and production transports

## Assignment

Work only in `/code/gleam-dream/llm_wire`. Use a fresh external `agy`
conversation with `--sandbox --dangerously-skip-permissions`, the configured
default model, no model override, and
`/etc/profiles/per-user/edgar/bin/agent-lsp`. Read `llm-design.md`,
`PUBLIC-API.md`, the standalone-LLM rows in `API-COVERAGE.md`, Wave 1's
order/report and `COMPLETION-PLAN.md`. Preserve the current Blueprint and Sinal
path dependencies unchanged. No GitHub, remote, publish, credentials or live
provider calls.

Start from checkpoint `e5b7b0b` and read the repository's `REVIEW-STATUS.md` and
oversight's `docs/implementation/relay-llm-wire/llm-wire-review.md`. Convert
every finding to a failing regression, resolve it, rerun the Wave 1 gate, and
record the proof. Reviewer cure labels are suggestions; choose the smallest
sound repair inside the authorized design without pausing for routine choices.
New capability work cannot conceal an unresolved correctness, ownership,
bound, security or public-claim finding.

## Mandatory Wave 1 correction

The current tool completion is only JSON-syntax completion. Replace it with
Blueprint-backed admission: a configured tool retains its name, input codec,
schema and provider-admission result; argument fragments remain incomplete
until the provider block closes; a completed call is emitted only after exact
`CallId` correlation, JSON parsing, schema validation and native decode succeed.
Unknown, duplicate, incomplete, invalid and over-limit calls are typed terminal
or protocol failures and never executable tool calls.

Audit stream invariants end to end. Separate provider routing coordinates from
application identities, require matching starts/deltas/stops, preserve all
interleaved blocks, use first accepted terminal precedence, reject input after
terminal, count memory before growth, and make every cleanup path idempotent.
Add deterministic regression tests for each review finding and every corrected
claim in `DESIGN-COVERAGE.md`.

Before facade expansion, close the other review findings explicitly: use one
bounded outstanding transport-read credit; bound mailbox bytes and counts;
enforce SSE line/event and HTTP header limits before growth; remove timed-out
pending reads; monitor/link owner, consumer and transport lifetimes; terminate
them on every terminal/close race; reject duplicate or contradictory OpenAI
routing and incomplete blocks; require Anthropic delta/block agreement; retain
the first accepted terminal even when its final progress meets a full queue;
classify hosted or ambiguously delivered effects as `EffectUnknown`; and carry
one remaining overall deadline through connect, headers and stream. Expand the
oracle inventory and coverage ledger to match the tests that actually exist.

## Public product surface

Deliver a usable standalone facade rather than decoder-only entry points:

- validated provider configuration, model, endpoint, credentials, headers,
  request options, messages/content, tools and optional structured output;
- `prepare` that performs local capability and Blueprint schema admission before
  transport and returns a provider-bound prepared call;
- `run`/buffered execution returning typed text, tool calls, refusal, usage,
  provider stop, output limit or typed failure;
- `stream` returning the owned bounded stream used by buffered execution;
- provider-bound continuation retaining response/conversation state and exact
  outstanding call identities;
- `continue` accepting exactly one result per outstanding call, rejecting
  missing, duplicate, extra, wrong-provider and stale results before transport;
- Blueprint-validated structured output with a native decoded result and a
  distinct invalid-output failure;
- configured capabilities that reject unsupported options rather than dropping
  them silently.

The facade must work directly without Fabric. Fabric remains the owner of tool
execution, approvals, loop budgets and agent continuation; LLM Wire only
prepares provider interactions and correlates tool results.

## Provider and transport delivery

Keep request encoding, response decoding, SSE parsing, provider reduction,
Blueprint admission, continuation and turn state as pure sans-I/O functions.
Put processes, clocks, sockets and TLS only in the OTP owner and one named
transport adapter. First run the design's narrow `anthropic_gleam` `0.1.1`
reuse experiment against the common Anthropic fixtures through its public
sans-I/O `build_streaming_request`, `new_streaming_state`, `process_chunk` and
`finalize_stream` surface; reject it if bounds or semantics require internal
imports or contract weakening.

Primary reuse evidence: [`anthropic_gleam` 0.1.1's streaming handler](https://hexdocs.pm/anthropic_gleam/anthropic/streaming/handler.html)
documents those functions as public sans-I/O incremental APIs. It accumulates
events in its published state, so fixture tests must prove bounded use before
adoption; its buffering convenience functions are excluded.

Replace the development raw-TCP HTTP path with a maintained streaming HTTP/TLS
dependency, not a home-grown HTTP parser. Prefer a thin Gun 2.x adapter: stream
references, request `flow`/`update_flow`, `cancel`, `reply_to`, connection reuse
and TLS map directly to the ownership contract. A narrow Erlang FFI may translate
Gun calls/messages/errors into typed transport events; it must not parse JSON,
SSE or provider semantics and no foreign terms may escape the internal adapter.
If another published library is chosen, prove equivalent pull/credit flow,
cancel, TLS verification, deadlines, owner-death cleanup and connection reuse,
and record the evidence. Deliver OpenAI Responses and Anthropic Messages with HTTPS validation,
hostname verification, bounded headers/body/chunks, connection and overall/idle
deadlines, redirect policy, decompression limits, status and retry hints,
streaming backpressure, cancellation and exact cleanup. Test all behavior with
local HTTP and TLS peers and pinned certificates; never contact a live provider.

Implement both buffered and streaming request encoders/decoders for the common
facade, including text, interleaved tool calls, usage, refusal/error, provider
continuation data and supported reasoning deltas. Provider-native fields stay
behind adapters; checked bounded extension data may be retained for diagnosis.

[Gun 2.2](https://ninenines.eu/docs/en/gun/2.2/manual/) is the verified default
candidate. Its asynchronous per-stream messages, explicit flow credit,
`update_flow`, `cancel`, `reply_to`, TLS and connection reuse fit the owner
contract. `gleam_httpc` is unsuitable for this path because its public API
returns a complete buffered response; it may remain a test/comparator only.

Assess Google against the completed seams after OpenAI and Anthropic are green.
Implement Google in this wave only if its buffered/streaming API reuses the same
HTTP/TLS owner, semantic events, Blueprint admission and continuation contracts
without weakening them. Otherwise record the exact incompatible transport or
continuation evidence and leave Google as the first mandatory slice of Wave 3.
Preference or schedule alone is not justification for deferral.

Add typed Sinal observations for prepared, request sent, first progress,
terminal, cancelled, deadline and cleanup outcomes. Emit after state changes;
never include API keys, authorization headers, full prompts, tool arguments or
provider bodies.

## Tests and acceptance

- Red-green-refactor through public consumers. Buffered execution must consume
  the same semantic stream and bounds as streaming.
- Exercise every representative byte split, malformed UTF-8/JSON/SSE, duplicate
  routing key, incomplete block, concurrent tool calls, wrong result identity,
  structured-output mismatch, queue saturation, caller/transport death,
  cancellation and deadline race.
- Test retry classification separately from progress. No automatic retry after
  response bytes, semantic progress, provider-hosted effects or ambiguous
  request delivery unless the caller opts into a proven idempotency contract.
- Use local TLS peers to prove certificate/hostname failures, timeout, oversized
  headers/body, redirect refusal, early disconnect and cleanup. Mocks may cover
  only true external time/randomness boundaries.
- Update the oracle and design-coverage ledgers. Each claim must point to a
  public test; every deferred capability must name Wave 3–5.

The gate is:

```text
nix develop --command gleam format --check src test
nix develop --command gleam check --target erlang
nix develop --command gleam test --target erlang
nix flake check
git diff --check
```

Return `WAVE-2-REPORT.md` with exact results, review closure, public API examples,
provider/TLS evidence, Google decision evidence and the complete capability
ledger. Every retained design row must point to implementation evidence, its
exact Wave 3–5 owner, or a genuine contract collision requiring a user scope
decision. Report implementer friction and distinguish improvements actually
applied from those merely proposed or rejected. Stop only for a genuine
contract collision; resolve routine dependency, library, module and fixture
choices within the approved design.
