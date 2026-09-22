# LLM Wire Wave 4 independent review

## Scope and result

This review targets the complete dirty LLM Wire tree against baseline
`188c70b`. It checks the delivered Wave 4 subset against
`wave4-work-order.md`, `llm-design.md`, the package reports and coverage
ledger, the pinned ReqLLM v1.24.0 sources, and the current provider contracts.
It does not turn the wider retained package scope into acceptance criteria for
this one slice.

The delivered subset is **partially accepted**. The exact Google
function-call `thoughtSignature` round trip, the named image encodings, the
provider-scoped cache fields, and the pool state-shape repair are sound within
their exercised paths. Wave 4 as reported is not accepted yet because the
three claimed upstream ports do not retain the named upstream assertions, and
the Google reducer rejects valid signed non-tool parts. The pool repair also
lacks a deterministic regression for the callback path it changes.

The installed `review-implementation` skill could not run its prescribed
four-axis process because all four mandatory primitive files it names are
absent (`conformance-probe.md`, `lens-board.md`, `communicate.md`, and
`clausative.md`). This report therefore uses a direct source, contract, and
gate audit and does not invent the missing rubric.

## Findings

### P1 — Google continuation does not preserve all valid thought signatures

`src/llm_wire/google.gleam:288-306` retains a `thoughtSignature` only when the
same part contains `functionCall`. A signature on a text or other non-tool part
terminates the stream with `ProtocolError`. This is valid provider output:
Gemini 3 may attach a signature to any part, Gemini 2.5 may place the signature
on the first part regardless of type, and Google says signed parts must be
returned without merging or repositioning them. In particular, a signed text
part before a later function call cannot be rejected or reconstructed as a
different part. The current representation stores state only on `ToolCall`, so
it cannot preserve that positional transcript.

The same locus silently treats a present non-string `thoughtSignature` as
absent because both missing-field and wrong-type errors flow through
`option.from_result`. That bypasses the otherwise explicit malformed-provider
boundary and may continue without required opaque state.

The function-call-only case is correct: `src/llm_wire/api.gleam:1246-1273`
returns the signature as a sibling of the original `functionCall`, and the
loopback test checks both that signature and the provider call ID. Acceptance
must stay limited to that case until the reducer retains signed non-tool parts
and rejects malformed signature types distinctly. Provider evidence:
[Google thought signatures](https://ai.google.dev/gemini-api/docs/generate-content/thought-signatures)
and [GenerateContent `Part`](https://ai.google.dev/api/generate-content).

### P1 — the three advertised ReqLLM ports do not port the selected behavior

The revision and license provenance are accurate: the local tag object is
`29f855513c327ec5630a16215531ad2d459ae56e`, it resolves to
`fd9e079fddf253e9b719b2d2c6920f4306592809`, and the checkout carries
Apache-2.0. The behavioral mapping is not faithful:

- Upstream `test/req_llm/images_test.exs` checks that image generation rejects
  a context with no user text. The local
  `req_llm_images_test_accepts_inline_multimodal_content_port` instead accepts
  an OpenAI Responses chat input containing text and an inline image. It uses a
  different endpoint, condition, and expected outcome.
- Upstream `test/req_llm/cache_test.exs` checks that ReqLLM separates cache
  options from request options. The local cache case checks that Gemini emits a
  `cachedContent` request field. These are unrelated cache contracts.
- Upstream `context_tool_continuation_test.exs` asserts that the complete
  appended context is JSON serializable and contains no live process state.
  The local case only checks an in-memory reducer field. The report separately
  and correctly says durable serialization remains open, so this test cannot
  be presented as a port of the serializability assertion.

`test/oracle/README.md:22-26`, `WAVE-4-REPORT.md:45-64`, and
`test/llm_wire_wave4_oracle_test.gleam:15-67` therefore overstate executable
oracle reuse. These cases are valid local tests and should remain as such, but
the Wave 4 oracle obligation needs three cases whose trigger and observable
assertion actually survive adaptation. Replace the mappings or label them
local-only; do not weaken the upstream assertion into a related substring
check.

### P1 — schema JSON still has two authorities

The current direction requires Blueprint's codec projection to be the single
source for schema-bearing tool and structured-output values, while ordinary
provider envelopes remain ordinary Gleam JSON. `src/llm_wire/schema.gleam:15-127`
recursively reimplements `codec.Schema` projection into `gleam/json`, even
though the pinned Blueprint exposes the canonical projection as
`codec.schema_value` (`json/blueprint/codec.gleam:1420-1495`). The same module
then contains separate recursive strict-output projections. Tests compare the
copies with Blueprint, but comparison does not make Blueprint authoritative;
new codec constructors or projection changes can still diverge until a test is
added.

This is pre-existing rather than introduced by the Wave 4 diff, so it does not
invalidate the new ordinary wire JSON work. It remains a current-tree blocker
to the latest single-source direction. Keep provider subset admission and
strict-profile checks local, but derive the admitted base schema value from
Blueprint rather than maintaining a second full renderer. No strict provider
envelope abstraction is called for.

### P2 — the pool state-shape fix has no regression for its failing path

The code repair in `src/llm_wire_gun_pool.erl:376-403,446-462` is correct by
inspection: `handle_call` wraps `start_connector_state/6` in the required
`{noreply, State}` return, while `maybe_serve_waiter/1` receives the bare state
record. This prevents a nested `{noreply, State}` tuple from becoming GenServer
state.

No Wave 4 test change drives a queued waiter through the branch that creates a
new connector after a connection-result or cleanup callback. The existing
waiter regression in `test/llm_wire_pool_test.gleam:374-439` serves a waiter
from a checked-in reusable connection, which does not prove the corrected
branch. The Google continuation loopback does not use the pool. Add one
deterministic regression that establishes a waiter, frees connector capacity
without producing a reusable idle connection, and proves the waiter completes
while the pool remains callable.

## Accepted delivered subset

- A Google `thoughtSignature` attached to a `functionCall` is retained
  separately from application and provider call IDs and is echoed on the exact
  function-call part during continuation. The local two-request peer verifies
  the signature and provider ID before returning the final answer.
- OpenAI encodes text, URL images, and inline data-URI images as Responses
  content. Anthropic and Google encode the tested inline base64 forms exactly.
  Their unadmitted URL combinations fail during preparation rather than being
  dropped. The provider-neutral `AssistantContent` and malformed/empty media
  values do not yet have a complete provider admission matrix, so acceptance
  is limited to the tested user-content forms.
- OpenAI `prompt_cache_key` and Google `cachedContent` use the correct request
  field names, survive continuation option copying, and reject cross-provider
  variants before transport. Anthropic caching is explicitly rejected and
  remains open. The Anthropic provider now supports URL image sources, so the
  current error saying Anthropic itself does not support image URLs should be
  narrowed to this profile's admitted subset or the small provider encoding
  should be added.
- The pool helper split returns the right Erlang state shape. Its behavioral
  acceptance remains conditional on the focused regression above.
- The implementation keeps ordinary provider wire data on `gleam/json`; it
  does not restore the removed strict JSON envelope abstraction.

## Verification

Independent commands completed successfully:

- `nix develop --command gleam test --target erlang` — **126 passed, no
  failures**. Expected negative TLS fixture notices were emitted.
- `nix develop --command sh test/external_package_boundary.sh` — passed; the
  root-facade consumer compiled and raw prepared-call/transport use failed at
  the intended boundary.
- `nix flake check` — passed the available `aarch64-darwin` formatting check;
  Nix reported the other systems as incompatible and omitted them.
- `git diff --check 188c70b` and `git diff --cached --check` — passed.

These gates establish the reported local build and boundary state. They do not
repair the oracle mismatch or expand the provider contracts.

## Remaining scope and acceptance boundary

Before accepting this Wave 4 report, preserve valid signed Google parts across
tool continuation, distinguish malformed signatures from absence, replace the
three oracle mappings with faithful ports, and add the focused pool waiter
regression. Make Blueprint the single schema projection authority in the
current tree or keep that conflict explicitly open against the latest user
direction.

The report otherwise keeps the larger boundary honest: embeddings, Anthropic
content-block caching, full provider option/usage/reasoning/stop matrices,
durable versioned continuation, replay-safe bounded retry, lifecycle
observations, batch/background operations, remote cancellation, realtime, and
release hardening remain incomplete. Anthropic URL images, media-value
admission, and signed non-tool Google parts should be named explicitly under
multimodal/provider parity rather than hidden inside a general phrase.

The strict response-header pre-allocation bound remains the already-recorded
dependency decision. The Wave 4 investigation correctly distinguishes Gun's
post-parse adapter rejection from a pre-allocation guarantee. This review does
not recommend a fork, second parser, or invented numerical requirement.
