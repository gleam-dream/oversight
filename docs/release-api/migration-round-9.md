# Round 9 migration: ports and compiled recipes

The planned published set changes from **14 to 11**: nine core packages plus
`saga_postgres` and `fabric_postgres`. Those PostgreSQL adapters retain their
infrastructure role. Cross-library composition is a small consumer-owned
module, compiled verbatim and compared to README and module documentation.
The aim is independent, bounded, ergonomic capabilities with explicit wiring.

## Classification

```gleam
// Before: fabric_typesafe
let client = client.new(http, key)
let decision = fabric_typesafe.decision(...)
// After: llm_wire classification; the key is a reveal closure.
let provider = classify.typesafe(fn() { key })
let decision = graph_classify.decision(...)
```

Use `llm_wire/classify` and `classify/question` for `noul`, native-label
`choice`, rubric `score`, `ask` and heterogeneous `combine`. The family owns
requests, outcomes and receipt codecs, typed `Failure` and error advice,
Duration bounds, http_gun transport and correlated observations. TypeSafe is
the first wire, not the family name. Confidence is concentration evidence.
See llm_wire's and fabric's Round 9 migration sections for exact signatures
and all configuration/accessor changes. Decision and writing consumers moved;
fixtures written by the old implementation prove old receipts and graphs read.
One live TypeSafe call produced a redacted replay cassette; key scans passed.

## Saga tools

```gleam
// Before
fabric_saga.tool(definition, workflow, config, input:, explain:, rollback_within:)
// After: copy src/saga_tool.gleam from fabric's README.
saga_tool.tool(definition, workflow, config, input:, explain:, rollback_within:)
```

`saga/outcome` owns completed/compensated/unresolved classification and held
step evidence. `saga/reporting.run_owned` owns the receiver surviving caller
cancellation. The 47-line recipe only binds those capabilities to fabric's
settlement API and correlation. Support desk and fabric's app consumer own
verbatim copies. The 43 former bridge tests remain in saga and the consumer.

## Relay calls and serving

```gleam
// Before
fabric_relay.tool(definition, peer:)
fabric_relay.discover(peer, peer:)
// After: copy relay_tools and relay_discovery from fabric's README.
relay_tools.tool(definition, peer:)
let assert Ok(declarations) = client.list_tools(peer)
list.try_map(declarations, relay_discovery.discovered(_, peer:))
```

```gleam
// Before
fabric_relay.service(definition, runs:, agent:, start:)
  |> fabric_relay.with_wait(wait) |> fabric_relay.serve
// After
let service = invoke.agent(tool.name(definition), runs, agent)
  |> invoke.with_wait(wait)
relay_serve.serve(definition, service, fn(call, input) {
  Ok(invoke.request(context, input.question)
    |> invoke.with_principal(tool.context(call).subject))
})
```

`start`/`refuse` become `Ok(invoke.request(...))`/`Error(tool_error)`.
`with_principal` and `with_wait` belong to invoke; `run_id` becomes
`invoke.keyed_id(service, principal, key)` and `run_of` the 12-line `relay_run`
recipe. Typed calling is 40 lines, discovery 50, serving 41; the unused-in-apps
graph operation variant is retained at 28 lines and tested. All 23 former
bridge tests remain. Relay's `client/output` and `tool.complete_with_meta`
are independently useful ports, with no fabric import.

For HTTP or jobs, call `invoke.call(service, request)` directly. Requests
carry context/input plus optional key, principal, correlation and cancellation
selector. Services default to a 25-second finite wait. Read `answer`, `id`,
`response_kind`, `code`, `describe_response` and `details`. `invoke.graph`
supports native graph state/answers; `graph.await_with` is interruptible and
`graph.matches_initial` compares the original state for idempotency.

**Identity migration:** framed tuples replace ambiguous hyphen joins for
principal/key and external action keys. Finish or reconcile old keyed runs
and interrupted remote calls before reissuing keys under the new mapping,
or retain an application mapping to original ids and remote keys. Records
remain readable by their old ids; no serialization shape changed.

## App effects

- support_desk: source +52/−5, 47-line saga recipe; 21 tests; demo still has
  0 of 267 events unattributed. Manifests +1/−4 and test comments +3/−3.
- tool_hub: source +172/−24, tests +30/−6, manifests +0/−3. Four recipes total
  143 lines; 16 tests. Listing and question share one correlation, with zero
  unjoined Relay or llm_wire events in the demo.
- research_agent: historical documentation references only; source/tests 0/0.
- Other apps retain their public composition. Final gate results are recorded
  in PLAN.md; all eight pass together with the final package heads.

Application code grows where it now owns wiring. Canonical recipe gates do
not automatically update every app copy. Keep drift and synchronized upgrades
visible; promote a recipe only when observed maintenance cost warrants it.

## Round 9 review follow-up

The approved follow-up preserves four existing guarantees: invocation results
retain unresolved effect evidence, classification parsing honors configured
byte budgets, discovered replies preserve structured-content presence, and
saga reporting returns a bounded startup failure instead of asserting success.
Invocation, classification and saga startup signatures stay unchanged.

The discovered-call output changes from `ToolResult(Value)` to
`ToolResult(Option(Value))`. Continuations preserve that same output type.

```gleam
// Before: output schemas guessed whether Null meant content-only output.
client.call_discovered(peer, declaration, arguments)
  |> output.require_discovered(declaration)
// After: the decoded reply determines whether structured content is absent.
client.call_discovered(peer, declaration, arguments)
  |> output.require_discovered
```

Direct discovered callers match `None` for absent structured content and
`Some(value.Null)` for explicit null. Every present structured value remains
unchanged; only `None` projects the content blocks to text. Typed `client.call`,
content blocks, metadata and submission evidence remain unchanged. Tool_hub
refreshes one line in its 50-line discovery recipe; tests and manifests do not
change. Relay's migration guide lists the exact signatures.

Fresh-context classification configuration, a normalized provider-neutral wire
contract, typed operational causes in saga reporting, and complete saga outcome
summaries remain deferred review findings. They are not part of these fixes.
All nine package gates and all eight app gates passed, with fabric passing its
full gate twice consecutively. The demos retain zero of 267 unattributed
support_desk events and zero unjoined tool_hub events.
The [review results](PLAN.md#round-9-review-follow-up) record the package and
app counts.
