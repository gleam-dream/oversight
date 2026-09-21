# LLM Wire initial implementation work order

## Assignment and stop point

- Build the first substantial `llm_wire` implementation in
  `/code/gleam-dream/llm_wire`.
- Treat `llm_wire` as an independent package. It must not depend on `relay`.
  A host may compose the two packages when it exposes an LLM tool through MCP.
- Target Erlang/OTP first. Do not imply JavaScript support from portable Gleam
  source while the owner and transport are Erlang-only.
- End this run with a compiler-checked typed facade and one tested streaming
  vertical from arbitrary transport bytes through an owned semantic stream.
- Support OpenAI Responses and Anthropic Messages in that vertical. Keep Google
  as a required provider in the complete design backlog without inventing
  parity in this run.
- Use only local deterministic fixtures and a local fake HTTP server. Do not use
  credentials, paid APIs, or live provider calls.
- Do not create a GitHub repository, add a remote, commit, push, publish, or
  access secrets. Stop for independent Sol Medium review.

The implementation baseline is oversight commit
`e1ed8cffd3c90cb0b86b81666b72b7c523195a00`:

- [`llm-design.md`](../../../llm-design.md)
- [`research/llm-provider-boundary.md`](../../../research/llm-provider-boundary.md)
- [`research/llm-streaming-contract.md`](../../../research/llm-streaming-contract.md)
- [`research/llm-stream-ownership-contract.md`](../../../research/llm-stream-ownership-contract.md)
- [`playground/interface_lab/src/lab/llm.gleam`](../../../playground/interface_lab/src/lab/llm.gleam)
- [`playground/interface_lab/src/lab/llm_turn.gleam`](../../../playground/interface_lab/src/lab/llm_turn.gleam)
- [`playground/interface_lab/src/lab/llm_stream_events.gleam`](../../../playground/interface_lab/src/lab/llm_stream_events.gleam)
- [`playground/interface_lab/src/lab/llm_stream_owner.gleam`](../../../playground/interface_lab/src/lab/llm_stream_owner.gleam)
- [`playground/interface_lab/src/lab/llm_structured.gleam`](../../../playground/interface_lab/src/lab/llm_structured.gleam)
- [`playground/interface_lab/STREAM-PROGRESS.md`](../../../playground/interface_lab/STREAM-PROGRESS.md)
- [`playground/interface_lab/STREAM-OWNERSHIP.md`](../../../playground/interface_lab/STREAM-OWNERSHIP.md)
- [`playground/interface_lab/PROVIDER-STRUCTURED-TURNS.md`](../../../playground/interface_lab/PROVIDER-STRUCTURED-TURNS.md)

These laboratory modules are contract evidence. They do not prove live HTTP,
socket ownership, cancellation, supervision, or backpressure behavior.

## Research addendum: Jido AI and ReqLLM

### Frozen source facts

- The researched ReqLLM release is `v1.24.0`. Its annotated tag object is
  `29f855513c327ec5630a16215531ad2d459ae56e`; the tagged source commit is
  `fd9e079fddf253e9b719b2d2c6920f4306592809`; its license is Apache-2.0.
  [Hex lists the release](https://hex.pm/packages/req_llm/versions), and the
  [tagged license](https://github.com/agentjido/req_llm/blob/fd9e079fddf253e9b719b2d2c6920f4306592809/LICENSE)
  is the copying constraint.
- The researched Jido AI release is `v2.3.0`. Its annotated tag object is
  `d368f2f25228a7499030c1dea08d3d284cf6ceaa`; the tagged source commit is
  `2f83b922edcca3deb9e92b6391d198a0c14f5da3`; its license is Apache-2.0.
  Its lockfile pins ReqLLM `1.17.1`, so Jido AI `2.3.0` is not evidence for the
  later ReqLLM `1.24.0` behavior.
- ReqLLM's `StreamServer` is a single `GenServer`. Producer delivery is
  synchronous, and a decoded-chunk count with a default high-water mark of 500
  controls producer admission. One received transport chunk is decoded as one
  atomic step and may add many public chunks, while no byte bound controls the
  queue. See
  [`StreamServer` configuration](https://github.com/agentjido/req_llm/blob/fd9e079fddf253e9b719b2d2c6920f4306592809/lib/req_llm/stream_server.ex#L53-L65)
  and
  [`push_data`](https://github.com/agentjido/req_llm/blob/fd9e079fddf253e9b719b2d2c6920f4306592809/lib/req_llm/stream_server.ex#L765-L779).
- ReqLLM logs parser errors and retains the prior parser state. Its SSE parser
  also returns invalid JSON as a raw event instead of making the malformed
  provider event terminal. See
  [`parse_data`](https://github.com/agentjido/req_llm/blob/fd9e079fddf253e9b719b2d2c6920f4306592809/lib/req_llm/stream_server.ex#L989-L1000)
  and
  [`process_sse_event`](https://github.com/agentjido/req_llm/blob/fd9e079fddf253e9b719b2d2c6920f4306592809/lib/req_llm/streaming/sse.ex#L29-L41).
- ReqLLM's streaming retry path refuses a transparent retry after any response
  body data. That conservative rule avoids duplicate visible output, but it
  cannot prove that a request caused no remote effect before the first byte.
  See
  [`stream retry`](https://github.com/agentjido/req_llm/blob/fd9e079fddf253e9b719b2d2c6920f4306592809/lib/req_llm/streaming/retry.ex#L63-L92)
  and
  [`retry decision`](https://github.com/agentjido/req_llm/blob/fd9e079fddf253e9b719b2d2c6920f4306592809/lib/req_llm/streaming/retry.ex#L172-L183).
- ReqLLM has useful process mechanics: consumer monitoring, explicit cancel,
  idle and total timers, and cleanup in `after`. See
  [`consumer setup`](https://github.com/agentjido/req_llm/blob/fd9e079fddf253e9b719b2d2c6920f4306592809/lib/req_llm/stream_server.ex#L223-L252),
  [`consumer cleanup`](https://github.com/agentjido/req_llm/blob/fd9e079fddf253e9b719b2d2c6920f4306592809/lib/req_llm/stream_server.ex#L625-L699),
  and
  [`timer handling`](https://github.com/agentjido/req_llm/blob/fd9e079fddf253e9b719b2d2c6920f4306592809/lib/req_llm/stream_server.ex#L1593-L1665).
- ReqLLM's high-level `process_stream` enumerates all chunks before
  materialization. Jido AI's ReAct runner delegates streaming to ReqLLM and
  repeatedly concatenates streamed text. Those convenience paths are unsuitable
  as the bounded core contract. See
  [`StreamResponse.process_stream`](https://github.com/agentjido/req_llm/blob/fd9e079fddf253e9b719b2d2c6920f4306592809/lib/req_llm/stream_response.ex#L432-L452),
  [`Jido ReAct streaming`](https://github.com/agentjido/jido_ai/blob/2f83b922edcca3deb9e92b6391d198a0c14f5da3/lib/jido_ai/reasoning/react/runner.ex#L453-L538),
  and
  [`Jido text accumulation`](https://github.com/agentjido/jido_ai/blob/2f83b922edcca3deb9e92b6391d198a0c14f5da3/lib/jido_ai/reasoning/react/runner.ex#L1501-L1507).

### Resulting decisions

- Reuse the process strategy as a reference: one owner, monitored consumers,
  explicit close, transport cancellation, producer admission, and two deadline
  classes.
- Do not copy its weak semantics. Parser failures are typed terminal failures;
  every buffer has byte and count bounds; terminal precedence is deterministic;
  convenience materialization is outside the owner loop.
- Keep a native Gleam implementation as the initial path. A ReqLLM FFI adapter
  remains a later measured spike. It must justify Mix/release startup, exception
  translation, stream ownership, cancellation, and semantic parity before it can
  become a dependency.
- Do not enable automatic retry merely because no semantic event was accepted.
  A disconnect before the first byte can follow a remote tool or server-side
  effect. The default for an unacknowledged outcome is no retry and an explicit
  `EffectUnknown` classification.
- Derive only selected fixtures or expectations from the pinned Apache-2.0
  sources. Record source file, test case, revision, license, transformation, and
  retained semantic. Do not copy an upstream suite indiscriminately.

## Provider evidence

- OpenAI's live
  [Responses streaming guide](https://developers.openai.com/api/docs/guides/streaming-responses)
  names `response.created`, `response.output_text.delta`,
  `response.completed`, and `error` among the common events. The complete event
  vocabulary remains in the
  [streaming API reference](https://platform.openai.com/docs/api-reference/responses-streaming).
- OpenAI's live
  [function-calling guide](https://developers.openai.com/api/docs/guides/function-calling)
  distinguishes an output item's `id`, its `output_index`, and the application
  tool-call `call_id`. Argument deltas route by item ID and output index; tool
  results correlate by `call_id`.
- Anthropic's live
  [streaming guide](https://platform.claude.com/docs/en/build-with-claude/streaming)
  defines `message_start`, indexed content-block start/delta/stop,
  `message_delta`, `message_stop`, ping, and error events. Usage in
  `message_delta` is cumulative. A successful HTTP response may still carry a
  stream error. Clients should tolerate future event types.
- Anthropic's
  [fine-grained tool streaming guide](https://platform.claude.com/docs/en/agents-and-tools/tool-use/fine-grained-tool-streaming)
  says tool argument fragments may be partial or invalid JSON and may remain
  incomplete after `max_tokens`. Accumulate bounded fragments and decode only
  when their content block closes.
- Anthropic's
  [server tool guide](https://platform.claude.com/docs/en/agents-and-tools/tool-use/server-tools)
  distinguishes provider-executed server tools from application tool calls.
  A server-tool event must never become a host tool-dispatch request.
- These provider pages are live evidence observed on 2026-09-20. They are not
  immutable oracle pins. Preserve exact fixture bytes and their capture or
  derivation provenance before making a parity claim.

## Repository safety and baseline

- Planning observed `/code/gleam-dream/llm_wire` as a clean, unborn Git
  repository on `master`, with no files, commits, or remotes.
- Reinspect it before mutation. Preserve any later user work and stop on an
  unexplained change instead of recreating or resetting the repository.
- Record the exact output of:

  ```sh
  git status --short --branch
  git rev-parse --verify HEAD
  git remote -v
  git branch --show-current
  /etc/profiles/per-user/edgar/bin/agent-lsp --help
  ```

- An unborn `HEAD` failure is expected and must be reported as such. Do not
  fabricate a baseline commit.
- Initialize a Gleam package named `llm_wire` in the existing directory. Inspect
  generated metadata and remove invented repository, license, author, or release
  claims when the user has not supplied them.
- Establish the same reproducible Nix/direnv/formatting foundation used by the
  accepted sibling packages when it can be copied without false package
  metadata. Record the actual Gleam, Erlang/OTP, rebar3, and dependency versions.
- Launch language intelligence directly with the installed executable
  `/etc/profiles/per-user/edgar/bin/agent-lsp` from inside the package's dev
  environment. Use absolute paths. Do not pipe the Nix banner into its protocol
  stream and do not install a second LSP bridge.

## Current sibling-package contract

- Blueprint is clean at
  `d3f0708b61eddb4a4789c0476ab5384267814a51` on
  `implementation/schema-aware-core`. This is the user's build-time generation
  work and supersedes the older experimental pin. Do not reset or rewrite it.
- Use ordinary Gleam JSON decoders for provider envelopes. Decoding begins only
  after an SSE data field is complete, bounded, and valid UTF-8. Route the
  provider event discriminator before decoding its typed subtype so a future
  event does not masquerade as a malformed known event.
- Blueprint owns only schema-bearing tool declarations, tool arguments, and
  structured-output contracts. Keep schema admission separate from provider
  envelope decoding and do not turn Blueprint into the package's ordinary JSON
  layer.
- Preserve the current `json/blueprint/codegen` capability for a schema-bearing
  caller contract that benefits from checked-in native codecs. Read its source
  and tests before use: `codegen.compile(module_path, name, definition)` emits a
  `GeneratedModule`, and `codegen.runtime(definition)` supplies the runtime
  codec. Source generation is not required for the initial provider-stream
  vertical.
- When a schema-bearing contract does use generation, check in the emitted
  ordinary Gleam source with a freshness test over exact content or fingerprint.
  Do not hand-edit generated output.
- Do not claim that this local Blueprint revision is a published Hex release.
  Record the exact dependency mechanism. If a reproducible package dependency
  cannot express the local revision, report that exact blocker rather than
  substituting the old public release or copying generated internals.
- Sinal is clean at `dd09933e5466628f7d46fa896c389f31ba7d4cb6` on
  `master`. Read its current `Event`, `Handler`, attachment, scoped attachment,
  and field APIs before adding an integration.
- State transition correctness must not depend on observation delivery. Emit
  bounded metadata only after the transition and never include prompt bodies,
  output text, tool arguments, raw frames, credentials, or provider payloads by
  default. A Sinal adapter may follow the core vertical; it must not delay the
  streaming spine.

## Package boundary

- `llm_wire` owns one provider interaction: request preparation, provider
  translation, HTTP exchange, streaming reduction, typed terminal outcome,
  usage normalization, cancellation, and cleanup.
- The host owns model policy, tool implementation and authorization, tool-loop
  budgets, workflow durability, cross-call retry, scheduling, and MCP routing.
- A stream never executes an application tool. It emits a completed typed tool
  request only after its entire argument document passes the declared Blueprint
  contract.
- Provider-native hosted tools remain distinguishable from application tools.
  A hosted effect can make retry outcome ambiguous before any model text is
  received.
- Keep ordinary messages, provider wire envelopes, and operational errors out
  of Blueprint unless their contract actually includes JSON Schema.
- Keep observations downstream of state. A handler cannot choose the next
  stream state or turn an accepted event into a failed transition.

## Compile-green typed facade

- Add a small public facade and focused modules. Exact file names may follow
  compiler evidence, but the report must map every exported value to these
  families:
  - provider configuration and opaque validated credentials/endpoints without
    ever printing secrets;
  - `ModelId`, message roles and content, request options, tool declarations,
    tool names, and application `CallId`;
  - structured-output declaration and validation through Blueprint;
  - prepared interaction, buffered execution, streamed execution, stream
    handle, read result, explicit close, and typed terminal outcome;
  - text progress, reasoning progress when available, completed application tool
    call, provider extension, usage update, and terminal event;
  - configuration, preparation, transport, HTTP status, provider, protocol,
    resource-limit, deadline, cancellation, and output-validation failures.
- Make invalid identifiers and non-positive limits unconstructable through
  checked constructors. Do not use plain `String` where routing identity,
  application identity, or a secret-bearing value has different behavior.
- Keep provider routing coordinates separate from application identity:
  - OpenAI item ID and output index route fragments; `call_id` correlates the
    application result.
  - Anthropic content-block index routes fragments; `tool_use.id` correlates the
    application result.
- Do not expose a partial argument buffer as an executable call. A limit,
  cancellation, provider error, malformed JSON, schema error, or stream ending
  before block completion leaves no dispatchable application call.
- Use custom types and exhaustive matches. Unknown future provider event names
  become a bounded `ProviderExtension(provider, event_name)` only when they do
  not claim a state transition. They do not reset semantic idle time, create a
  tool call, change usage, or complete a stream. A malformed known event is a
  protocol failure.
- Keep usage optional and provenance-aware. Treat Anthropic cumulative usage as
  a replacement snapshot instead of summing repeated totals.
- Compile the public types before the live vertical. Honest temporary `todo`
  bodies are allowed only at this checkpoint when each warning is inventoried
  and no fake success, panic, forged opaque value, or permissive decoder hides
  the gap.

## Streaming spine

- Implement and test this one-way pipeline:

  ```text
  transport bytes
    -> bounded SSE framer
    -> bounded complete data payload
    -> provider wire event
    -> provider semantic reducer
    -> single OTP owner queue
    -> one credited consumer read
  ```

- Keep each stage pure except the transport and owner edges. A byte chunk is not
  an SSE event; an SSE event is not a provider event; a provider event is not a
  semantic event.
- Feed arbitrary `BitArray` fragments to the framer. Do not convert the
  transport chunk to `String` before the framer reconstructs a complete bounded
  event and validates UTF-8.
- Cover `LF`, `CRLF`, split `CRLF`, comment lines, `event`, `data`, `id`, and
  `retry` fields, multiple `data` lines, empty fields, blank terminators, and an
  incomplete EOF. Test every byte split for representative frames, including a
  split inside emoji and non-Latin UTF-8.
- Preserve JSON fragments exactly until the provider reducer owns them. Test
  escaped quotes, backslashes, braces inside strings, split Unicode escapes,
  split multi-byte code points, malformed UTF-8, and invalid complete JSON.
- Decode OpenAI Responses fixtures that cover text deltas, more than one
  interleaved output item, more than one interleaved function call, argument
  deltas, item completion, usage, refusal/error, incomplete/cancelled/failed
  statuses, and response completion.
- Decode Anthropic Messages fixtures that cover text deltas, more than one
  interleaved content block, tool-use argument fragments, block completion,
  cumulative usage, ping, stream error after HTTP success, `max_tokens`, and
  message completion.
- Prove routing indices can be reused across separate streams without becoming
  application IDs. Prove two simultaneous tool calls with similar names keep
  different `CallId` values and argument buffers.
- Reject duplicate starts, unknown fragment targets, mismatched routing keys,
  deltas after block completion, duplicate block completion, incomplete known
  blocks at terminal, duplicate terminal events, and semantic events after a
  terminal.
- Define terminal precedence as first accepted terminal wins. A provider failure,
  protocol failure, resource limit, deadline, cancellation, or successful
  completion atomically seals the owner. Later input cannot change the result.
- Make cleanup idempotent and observable in tests. Every terminal path attempts
  transport cancellation/close once, cancels timers, releases the producer,
  replies to pending reads, and stops the owner without leaving an orphan.

## Resource and flow contract

- Use positive checked limits for at least:
  - bytes in one received transport chunk;
  - bytes retained by the line/framing parser;
  - bytes in one SSE field line and one completed event;
  - queued semantic event count and queued semantic bytes;
  - simultaneous live output blocks and tool calls;
  - text bytes per block and across the interaction;
  - tool-argument bytes per call and across the interaction;
  - provider extension name and diagnostic bytes.
- Enforce a limit before appending the bytes that would cross it. Return a typed
  limit failure naming the limit and measured value without echoing the payload.
- Count an event conservatively from retained data. Do not assume a large
  transport chunk becomes one small semantic delta.
- Give one OTP process exclusive mutable ownership of parser state, reducer
  state, limits, queue, timers, transport handle, and terminal outcome.
- A copied Gleam stream handle identifies that same owner. It does not clone the
  connection, parser, queue, or close state.
- Allow one outstanding credited read per stream. A concurrent read gets a
  deterministic typed ownership/read conflict. Do not create implicit fan-out
  or let multiple callers race the mailbox.
- The owner requests or accepts more transport input only while queue count and
  byte credit permit it. A slow consumer must eventually stop reads from the
  fake transport, and resuming the consumer must resume input without loss.
- A convenience `collect` or buffered execution path must consume this same
  semantic stream and enforce a separate result bound. It cannot bypass the
  reducer or run inside the owner loop.

## Deadlines, cancellation, and retry evidence

- Keep the interaction's absolute overall deadline separate from its idle
  deadline and from a caller's timeout while waiting for one `next` result.
- Reset idle time only after accepted semantic progress. Transport bytes,
  comments, pings, unknown extensions, and malformed or duplicate input do not
  count as progress.
- Carry the remaining overall budget through setup and every internal action.
  No phase gets a fresh copy of the original timeout.
- Monitor the active consumer. Consumer death, explicit close, owner death,
  transport death, an idle deadline, and an overall deadline all exercise the
  same idempotent cleanup contract.
- Report local socket/task cancellation as local cancellation. Do not call it a
  provider cancellation unless a provider endpoint returns an explicit remote
  cancellation acknowledgement.
- Default automatic retries to disabled in this initial package.
- Classify retry evidence independently from semantic progress. At minimum,
  distinguish `NoRequestSent`, `RequestMayHaveReachedProvider`, and
  `EffectUnknown`; preserve whether response bytes and semantic progress were
  observed. No semantic progress does not imply retry safety.
- A disconnect after any provider-hosted effect, application tool request, body
  byte, or provider event is not automatically retryable. An explicit future
  policy may retry only when its idempotency contract covers the provider call,
  the remaining deadline permits it, and the host opted in.
- Keep provider-call retry separate from a host retry of a complete failed
  interaction. Neither path may silently replay a tool effect.

## Local fake transport tests

- Build the smallest local Erlang/OTP fake HTTP/SSE endpoint that can control
  status, headers, raw chunk boundaries, pauses, early disconnect, terminal
  event, and connection close. Bind only to loopback and choose an ephemeral
  port.
- Drive the real package transport against this endpoint. Pure decoder tests
  alone do not prove socket backpressure, process cleanup, or deadline behavior.
- Add deterministic cases for:
  - every split point of one OpenAI frame and one Anthropic tool frame;
  - several frames in one transport chunk and one frame across many chunks;
  - a slow consumer reaching both queue count and byte bounds;
  - a stall before the first byte and a stall after accepted progress;
  - caller death, explicit close, double close, close during read, and close
    racing with terminal completion;
  - HTTP error before stream setup and stream error after HTTP success;
  - disconnect before bytes, after bytes but before a semantic event, after text,
    during tool arguments, and after a provider-hosted effect marker;
  - malformed UTF-8, oversized line/event/argument, incomplete EOF, duplicate
    terminal, and data after terminal;
  - transport process death and owner process death with no surviving child.
- Assert the returned event/outcome, retry evidence, exact cleanup-attempt count,
  process termination, transport read count, and maximum observed queue bytes.
  Avoid timing-only assertions when a monitor, acknowledgement, or counter gives
  deterministic evidence.

## Oracle and coverage ledger

- Create `test/oracle/README.md` or an equivalent durable ledger with these
  columns:

  | Local case | Source URL and upstream case | Revision/tag object | License | Transformation | Retained semantic | Status |
  | ---------- | ---------------------------- | ------------------- | ------- | -------------- | ----------------- | ------ |

- Populate the ledger before deriving a fixture. `Status` is one of `ported`,
  `planned`, `excluded` with reason, or `blocked` with evidence.
- Inventory every test case in each selected source file. Comprehensive coverage
  means every selected case is accounted for; it does not mean copying every
  upstream test.
- Start with these pinned ReqLLM oracle families:
  - [`host_integration_contract_test.exs`](https://github.com/agentjido/req_llm/blob/fd9e079fddf253e9b719b2d2c6920f4306592809/test/contracts/host_integration_contract_test.exs)
  - [`context_tool_continuation_test.exs`](https://github.com/agentjido/req_llm/blob/fd9e079fddf253e9b719b2d2c6920f4306592809/test/req_llm/context_tool_continuation_test.exs)
  - [`stream_response_test.exs`](https://github.com/agentjido/req_llm/blob/fd9e079fddf253e9b719b2d2c6920f4306592809/test/req_llm/stream_response_test.exs)
  - [`retry_test.exs`](https://github.com/agentjido/req_llm/blob/fd9e079fddf253e9b719b2d2c6920f4306592809/test/req_llm/streaming/retry_test.exs)
  - [`streaming_orchestration_test.exs`](https://github.com/agentjido/req_llm/blob/fd9e079fddf253e9b719b2d2c6920f4306592809/test/req_llm/integration/streaming_orchestration_test.exs)
  - [`sse_test.exs`](https://github.com/agentjido/req_llm/blob/fd9e079fddf253e9b719b2d2c6920f4306592809/test/req_llm/streaming/sse_test.exs)
  - [`StreamServer` tests](https://github.com/agentjido/req_llm/tree/fd9e079fddf253e9b719b2d2c6920f4306592809/test/req_llm/stream_server)
  - [`chunk_accumulator_test.exs`](https://github.com/agentjido/req_llm/blob/fd9e079fddf253e9b719b2d2c6920f4306592809/test/req_llm/provider/chunk_accumulator_test.exs)
  - [`openai_responses_materialization_test.exs`](https://github.com/agentjido/req_llm/blob/fd9e079fddf253e9b719b2d2c6920f4306592809/test/req_llm/provider/openai_responses_materialization_test.exs)
- Add selected pinned Jido AI cases only where they test host cancellation or
  ReAct integration that ReqLLM does not already cover. Record that Jido's
  tested dependency was ReqLLM `1.17.1`.
- For official provider examples, store the exact original byte fixture or a
  small independently authored equivalent. Record the live page URL, observation
  date, and transformation. Do not label live documentation a frozen revision.
- Keep copied Apache notices required by the exact material used. Prefer
  independently authored small fixtures and semantic assertions over copying
  prose or large fixture corpora.
- Add a separate design coverage ledger that maps every `llm-design.md` section
  to `implemented`, `tested`, `scaffolded`, or `backlog`. Preserve all deferred
  capabilities, including Google, embeddings, multimodal content, prompt
  caching, batch APIs, WebSocket/realtime transports, FFI evaluation, and remote
  background-response cancellation. Do not delete a requirement to make the
  first milestone appear complete.

## Test-driven sequence

- Use red-green-refactor for each behavior. Record one representative failing
  assertion before the implementation and the exact passing command afterward.
- Work in this order:
  1. package/dev-shell bootstrap and baseline report;
  2. compile-green public types and constructors;
  3. pure byte/SSE fragmentation with resource limits;
  4. OpenAI wire translation and semantic reducer;
  5. Anthropic wire translation and semantic reducer;
  6. one OTP owner with credit, close, monitors, deadlines, and cleanup;
  7. real transport against the local fake endpoint;
  8. Blueprint-backed tool and structured-output validation; add generated
     native codecs and a freshness proof only for schema-bearing contracts that
     justify generation;
  9. buffered convenience over the same stream;
  10. bounded observations after state transitions if the core is already
      accepted.
- A compiler scaffold alone is not a sufficient delivery. Continue through the
  real byte-fragment and local fake-transport spine unless an evidenced toolchain
  or dependency blocker makes that impossible.
- Keep refactors inside green behavior. Do not widen the API or add another
  provider merely to make the package look complete.

## Acceptance gates

- The first review checkpoint is acceptable when:
  - the package builds on Erlang/OTP with no forged metadata or remote;
  - the public facade models the provider, identity, tool, structured-output,
    stream, terminal, error, deadline, and resource-limit boundaries;
  - arbitrary byte fragmentation produces the same semantic events at every
    tested split point;
  - OpenAI and Anthropic interleaved text/tool fixtures reduce correctly;
  - no partial or invalid tool arguments become executable calls;
  - count and byte bounds are enforced before growth and exercised through the
    local HTTP path;
  - one owner serializes reads, copied handles share state, terminal precedence
    is deterministic, and every terminal path cleans up once;
  - idle and overall deadlines have distinct deterministic tests;
  - ambiguous disconnects do not trigger automatic retry;
  - generated Blueprint codecs, if used for a schema-bearing contract, have a
    deterministic freshness gate;
  - oracle and design coverage ledgers name every implemented and deferred
    contract honestly.
- Run the actual commands supported by the finished package. At minimum, expect:

  ```sh
  nix develop --command gleam format --check src test
  nix develop --command gleam check --target erlang
  nix develop --command gleam test --target erlang
  nix flake check
  git diff --check
  git status --short --branch
  ```

- Run `nix flake check` only after the flake defines meaningful checks. Report
  what the check covers. Do not imply it ran tests that are absent from the
  derivation.
- Use the compiler and tests as the authority. LSP diagnostics support the edit
  loop and do not replace these gates.
- Do not run JavaScript gates unless the implementation actually declares that
  target. Record Erlang-only modules and the work required before a JavaScript
  claim.

## External implementation handoff

- Run from `/code/gleam-dream/llm_wire` in a fresh external agent conversation
  with its configured default model and no model override:

  ```sh
  /opt/homebrew/bin/agy \
    --sandbox \
    --dangerously-skip-permissions \
    --add-dir /code/gleam-dream/oversight \
    --add-dir /code/gleam-dream/json_blueprint \
    --add-dir /code/gleam-dream/sinal \
    --print-timeout 0 \
    --print "Implement the LLM Wire initial work order at /code/gleam-dream/oversight/docs/implementation/relay-llm-wire/llm-wire-work-order.md. Work only in /code/gleam-dream/llm_wire except for read-only evidence from the three added directories. Use the progressive-implementation, lang-gleam, and tdd skills. Continue through the substantial tested byte-to-owned-semantic-stream milestone, then stop for review. Do not commit, create a remote, push, publish, use credentials, or call a live provider."
  ```

- The implementation agent returns:
  - observed repository and toolchain baselines;
  - changed files and the exported API map;
  - the exact stream pipeline and enforced bounds;
  - provider fixture and oracle provenance ledgers;
  - one recorded red-green cycle per major behavior family;
  - exact gate commands, exit status, and meaningful coverage;
  - process/backpressure/cleanup evidence from local fake HTTP tests;
  - Blueprint and Sinal revisions and dependency mechanisms actually used;
  - remaining todos, design coverage backlog, divergences, and blockers;
  - confirmation that no commit, remote, push, publish, credential, or live API
    call occurred.
- Sol Medium reviews the uncommitted result independently. It checks the design
  boundary, public type honesty, byte-level fragmentation, UTF-8 behavior,
  bounded memory, tool-call identity, terminal precedence, cleanup, deadlines,
  ambiguous-effect retry behavior, fixture provenance, and claims against actual
  gates before any commit is authorized.
