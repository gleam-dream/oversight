# LLM Wire Wave 2 implementation review

Baseline: `e5b7b0b`. Target: the complete staged, unstaged, and untracked Wave
2 tree in `/code/gleam-dream/llm_wire`.

## Verdict

**Changes required; do not accept Wave 2 against its work order.** The tree is
a substantial checkpoint: the reported 76 tests are real, Blueprint runtime and
native decoding now guard each closed tool block, the owner uses one Gun flow
credit, local TLS behavior is exercised, and the report is candid about several
unfinished requirements. The green gate does not cover the critical schema,
terminal-tool, continuation, or public transport bypasses below.

## Blocking findings

### P0 — transmitted tool schemas disagree with their Blueprint contracts

`src/llm_wire/schema.gleam:48-73,87` omits
`additionalProperties: false` for `ObjectSchema` and renders
`FieldSchema(name, inner)` as only `inner`. Blueprint normalizes `FieldSchema`
to a required, closed one-property object, and its codec decodes that object.
Every Wave 2 tool fixture and the published example use `codec.field`, so the
provider receives a primitive string/integer schema while local validation
requires an object such as `{"x": 42}`. A provider following the transmitted
schema will produce a call LLM Wire rejects. Tests at
`test/llm_wire_api_test.gleam:12-32` assert only generic substrings and miss the
structural mismatch. Emit the exact closed object schema and compare the
transmitted schema structurally with the admitted Blueprint contract.
`(in-place-fix, now)`

The same serializer also exposes an incorrect public numeric representation:
`schema.gleam:98-103` writes exact-number range bounds as JSON strings instead
of JSON numbers. Current provider profiles reject `NumberRangeSchema`, so this
does not reach tool preparation, but `codec_schema_to_json` itself is public
and incorrect. `(in-place-fix, now)`

### P0 — streaming publishes tool calls before the terminal batch is safe

OpenAI at `src/llm_wire/openai.gleam:593-615` and Anthropic at
`src/llm_wire/anthropic.gleam:663-693` emit public
`StreamProgress.ToolCallCompleted(ToolCall)` when one argument block closes.
Another interleaved call can later fail schema decoding or remain incomplete,
after the first dispatchable `ToolCall` has escaped. This contradicts
`llm-design.md:82`: one completed block must not publish executable work; the
terminal tool-request turn must prove every declared call complete and decoded.
Withhold `ToolCall` values until `CompletedToolCalls`, or expose only explicitly
non-executable argument progress before terminal. `(design-change, now)`

### P0 — continuation provenance is forgeable and cross-call swappable

`src/llm_wire/types.gleam:434-458` publicly exposes continuation factories,
including `new_tool_continuation(provider, model, source_calls, conversation,
response_id)`. `api.prepare_continue` at `src/llm_wire/api.gleam:323-377`
checks only provider/model, internal list agreement, and compatibility with the
current tool catalog. It has no originating prepared-call identity. A caller
can invent calls and conversation, or substitute a real continuation from a
different call using the same provider/model/tools. The claimed continuation
tests at `test/llm_wire_api_test.gleam:82-173` construct the continuation by
hand and therefore demonstrate the bypass rather than provider-origin
retention. Remove public fabrication and bind the opaque continuation to the
originating prepared interaction while preserving the separately documented
host-owned replay limitation. `(design-change, now)`

### P0 — public lower-level calls bypass HTTPS and preparation

`src/llm_wire/client.gleam:7-29,58-80` exports OpenAI and Anthropic entry points
that always choose `transport.Plaintext` for any caller-supplied host and API
key. The variants at `:32-56,83-107` accept arbitrary `TlsMode`, including
plaintext. Because Gleam package modules are public, these functions bypass the
facade's loopback-only HTTP check, provider request construction, schema
admission, and header validation; they can transmit credentials to a remote
host without TLS. Make these adapter seams internal or enforce the same secure
admission at every exported boundary. `(design-change, now)`

### P1 — provider terminal states are reported as success or local cancellation

Anthropic handles only `max_tokens` and `tool_use` explicitly at
`src/llm_wire/anthropic.gleam:828-835`; every other stop reason falls through
to `CompletedText` or `CompletedToolCalls`. A refusal is consequently reported
as successful text. A successful `server_tool_use` / `pause_turn` block is
excluded from `all_calls` and can become empty `CompletedText`, losing the
provider-hosted effect and required continuation state. The current hosted-tool
test covers only a later error. OpenAI maps provider status `cancelled` to
`StreamCancelledLocally` at `src/llm_wire/openai.gleam:714-737`, falsely
attributing cancellation to the local owner. Add distinct refusal, provider
stop, and hosted-effect handling, or reject unsupported terminal states without
manufacturing success or local ownership. `(design-change, now)`

### P1 — read timeout cancellation can discard accepted progress

`owner.next` returns `ReadTimeout` and asynchronously sends a PID-only cancel at
`src/llm_wire/owner.gleam:229-234`. If a transport chunk is processed before
that cancel, `dispatch_or_queue_progress` sends progress to the abandoned reply
subject and clears the parked read (`:598-603`); the caller's next read never
sees the item. The deterministic timeout tests only prove sequential cleanup,
not this cross-sender race. Give each read a request identity and complete
timeout cancellation through an owner acknowledgement/arbitration so either
the result or cancellation wins observably. `(design-change, now)`

### P1 — the documented root facade cannot construct a call

`src/llm_wire.gleam` aliases `ProviderConfig`, `Message`, and `ToolResult`, but
does not expose `openai_config`, `anthropic_config`, message constructors, or a
tool-result constructor. An external project importing only `llm_wire` fails to
compile `llm_wire.openai_config(...)` and `llm_wire.UserMessage(...)`. The Wave
2 report's “facade” example quietly imports `llm_wire/types`. Complete the root
facade or describe the supported multi-module API accurately and provide a
compile-checked public consumer. `(in-place-fix, now)`

## Explicit unfinished work-order requirements

The report honestly retains these gaps, but they prevent full Wave 2
acceptance: OpenAI refusal and reasoning-summary reduction, a strict
pre-allocation response-header cap, connection reuse, representative every-split
coverage, cancellation/deadline race coverage, and complete selected-oracle
inventory. `RunRefusal` and `StructuredRefusal` remain unreachable. Google may
remain the first mandatory Wave 3 slice because the report identifies the
specific optional-call-ID collision and a viable Gemini 3 profile decision;
that is the deferral the work order permits. The other listed items were direct
Wave 2 delivery or acceptance requirements rather than optional release polish.

## Independent checks and limits

The following commands passed independently on Erlang/OTP 28:

- `gleam format --check src test`
- `gleam check --target erlang`
- `gleam test --target erlang`: 76 passed
- `nix flake check`: one formatting check
- `git diff --check e5b7b0b`

A separate path-dependent consumer probe reproduced the root-facade compile
failure. I inspected the generated provider request paths, reducers, owner, Gun
FFI, local TLS fixtures, coverage ledger, and report. I did not contact a live
provider, independently measure Gun's transient header allocation, or prove
behavior on a runtime other than the reported Erlang/OTP 28 host. The
implementation-review skill's referenced `primitives/*.md` files were absent
from the installed skill tree, so this review used the frozen work order,
design, repository instructions, and direct evidence rather than that missing
auxiliary rubric.
