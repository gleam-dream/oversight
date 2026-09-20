# Wave 2 work order: native telemetry and exact numbers

Run the two repository scopes independently. Each run may choose several
coherent red-green increments when that reduces setup cost or improves evidence.
Reach a substantial reviewable milestone, not merely one passing test. Do not
change the approved public design to make implementation easier. Report a
material mismatch before changing an owning signature or behavior.

## Common cold start and operating rules

1. Confirm the named repository, branch, clean status, and exact baseline below.
   Preserve user changes if the tree is unexpectedly dirty. Do not commit, push,
   publish, read secrets, or print environment/configuration dumps.
2. Before editing, read this work order, [`review-1.md`](review-1.md), the
   package's root design, and the current package sources/tests. In the final
   report, name the oversight files actually read and one constraint that
   affected the implementation.
3. Discover available tools. Probe the configured Gleam LSP against one real
   source file before editing; report the tool and result, or the exact
   unavailability and compiler fallback. Separately inventory **web search** and
   **URL fetch/browser** capability. Use an available fetch/browser or a small
   HTTP request to read one official oracle source: the pinned telemetry source
   for Sinal, or JSON Schema Draft 2020-12 for Blueprint. State which capability
   worked; an HTTP fetch is not evidence of web search. Do not install tools.
4. Immediately record these probes in
   `test/oracle/wave-2-capabilities.md`: baseline/branch, oversight paths read,
   LSP result, web-search availability, fetch/browser or HTTP result and URL,
   and any fallback. Keep it brief and free of secrets or tool configuration.
5. Use public-contract TDD. Preserve a historical red record, then make the
   smallest coherent implementation green. No skip, expected-failure marker,
   commented assertion, unconditional pass, forged opaque value, or false
   generic default may hide unfinished behavior. Keep unsupported paths as
   descriptive Gleam todos.
6. Reuse accepted baseline and provenance evidence. Rerun gates affected by the
   changes and any focused oracle needed to substantiate a claim; do not spend
   the wave repeating unrelated oversight suites. Await every command or child
   job you start. A checkpoint report must not return while work is still
   running.

## Sinal repository scope

**Repository:** `/code/gleam-dream/sinal`

**Branch and baseline:** `master` at
`35c83e11e1d58f1ee9e3185112842e7ab75c666e`

Implement the native `telemetry` 1.4.2 adapter through the existing public
facade. The accepted milestone covers `emit`, `attach`, same-shaped
`attach_many`, retained-origin `detach`, callback decoding, and callback-failure
removal. Keep trusted BEAM atom names and atom-keyed native maps; do not add
Blueprint, JSON conversion, a private registry, actor dispatch, or runtime atom
creation.

Required observable behavior:

- Encoding completes before `telemetry:execute/3`; encoding failure invokes no
  native dispatch. Successful emit runs selected callbacks synchronously in the
  emitting process and returns only after they finish.
- `attach` and `attach_many` use the global native registry and retain the
  originating identifier/detach operation in `Attachment`. Duplicate public
  handler IDs map to `AlreadyExists`; a second detach reports `NotAttached`.
  Existing duplicate native event-name rejection remains pre-registration.
- A multi-event callback resolves the exact selected descriptor by native name
  before decoding its measurement and metadata fields.
- Malformed measurements, malformed metadata, and `HandlerReturned(e)` remain
  distinct. The failure observer receives the selected descriptor and typed
  failure. The raw callback then follows native telemetry failure behavior so
  the handler is removed and the upstream handler-failure event occurs.
  Unexpected callback error/exit/throw must not be converted into the handler's
  typed `e`.
- Exercise real native maps and raw foreign emission in tests. Cover successful
  synchronous delivery and PID identity, attach-many selection, duplicate ID,
  detach/repeated detach, encode refusal, both decode-failure classes, returned
  handler error, removal after failure, and failure-event evidence. Do not claim
  callback ordering because upstream provides none.

Port the smallest meaningful cases from the pinned upstream source and record
source URL, commit, case/function, normalization, and preserved semantic in the
oracle ledger. The already accepted 42-case upstream run may be cited; rerun it
only if the pin or adapter assumption changes. Transition
`test/focused_behavior.gleam` from its durable expected red to real green and
retain the red history.

You may include `with_attachments` in this wave only after the native adapter is
green and only if ordinary completion, attach refusal, returned cleanup error,
catchable error/exit/throw cleanup with original re-raise, cleanup-reporter
failure, nested identity, and already-removed `NotAttached` are coherently
tested. Otherwise leave its named todo and explain the deferral. Spans remain
out of scope.

Run at least formatting, `gleam check`, unit tests, the focused behavior command,
and `git diff --check` through the repo dev shell. Run `nix flake check` when the
changed tree affects its declared checks. Stop for Sol Medium review with a
cleanly formatted, uncommitted worktree.

Official capability probe URL:
`https://github.com/beam-telemetry/telemetry/blob/7baf8085e406d5ae9e43b284d7c866742ae04b28/src/telemetry.erl`.

## JSON Blueprint repository scope

**Repository:** `/code/gleam-dream/json_blueprint`

**Branch and baseline:** `implementation/schema-aware-core` at
`25d554b0bdde421bd2037f68253315ebc0ab3090`

Complete the Erlang exact `Number` kernel and exercise all 62 independent cases
from `playground/interface_lab/number_check.py` against the package's public
`json/blueprint/number` API. The package tests or a durable package test harness
must enumerate the same 62 fixtures and assert their expected results; merely
rerunning the oversight laboratory does not test the new package.

The evidence must cover JSON-number syntax and parse limits, canonical zero and
scientific rendering, mathematical comparison and integrality, checked integer
projection and its digit limit, `from_int`, exact construction from finite
binary64 values, exact float projection, and overflow/underflow/inexact
outcomes. Retain exact decimal arithmetic for parsing, comparison, and integer
behavior; do not route these through `Float` or legacy `Dynamic`. FFI may expose
the minimum native integer/IEEE-754 operations needed at the boundary. Keep the
one canonical `Number` leaf in `Value`.

Record the 62-case count, fixture families, oversight source revision/path,
normalization, and package test command in the oracle ledger. Preserve the
historical first red-to-green entry. JavaScript exact-number behavior may remain
unsupported at this milestone, but each public JavaScript path must fail only
through an explicit named Gleam todo, never a throwing FFI or fake result. Both
target checks and all 21 legacy JavaScript tests must remain green.

After the full Erlang number kernel and evidence are green, you may implement a
coherent adjacent `Value`/primitive-codec slice if it can be tested through
public behavior without weakening schema agreement: duplicate-key rejection,
then the existing string, integer, exact-number, and boolean primitive codec
contracts are the preferred boundary. Defer it if completing it would require a
whole schema engine or speculative policy. Do not add source generation, a
universal codec package, ordinary-JSON Blueprint requirements, or broad document
loading/runtime validation in this wave.

Run at least formatting, Erlang and JavaScript checks, Erlang package tests,
legacy JavaScript tests, and `git diff --check`. Rerun the frozen compatibility
check only when a legacy file or compatibility boundary changes. Stop for Sol
Medium review with a cleanly formatted, uncommitted worktree.

Official capability probe URL:
`https://json-schema.org/draft/2020-12/json-schema-core.html`.

## Required result from each run

Return one synchronous checkpoint report containing:

- repository, branch, starting HEAD, status, and changed files;
- capability evidence from `test/oracle/wave-2-capabilities.md`;
- implemented public behavior and every remaining named todo;
- red-green increments and focused tests, with exact commands and results;
- oracle cases adopted, provenance, normalization, and coverage count;
- relevant compiler, target, compatibility, formatting, and diff results;
- anything deliberately deferred and why it remains coherent;
- any design divergence or material decision, without silently changing it;
- friction encountered and concrete improvements to the work order, tooling,
  tests, or repository setup; and
- confirmation that no commit, push, publication, secret access, or unrelated
  user change occurred.

Acceptance belongs to the subsequent Sol Medium review. Passing tests alone do
not authorize the next wave or establish production completeness.
