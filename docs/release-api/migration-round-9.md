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
// After: a pure protocol and fresh live settings.
let wire = classify.typesafe()
let config = classify.config(fn() { key })
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
cancellation. The current 59-line recipe binds those capabilities to fabric's
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

## Initial migration app effects

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

The first review follow-up deferred fresh-context classification, typed
classification wires, typed reporting errors and complete outcome summaries.
The owner subsequently authorized the implementation described below.
All nine package gates and all eight app gates passed, with fabric passing its
full gate twice consecutively. The demos retain zero of 267 unattributed
support_desk events and zero unjoined tool_hub events.
The [review results](PLAN.md#round-9-review-follow-up) record the package and
app counts.

## Round 9 typed composition follow-up

Classification now separates the versioned protocol from live configuration:

```gleam
// Before: configuration owns both protocol and live credentials.
let config = classify.typesafe(reveal)
let prepared = classify.prepare(config, request)
let receipt = classify.receipt_codec(config, questions)
// After: the operation version owns the wire; a call owns live settings.
let wire = classify.typesafe()
let config = classify.config(reveal)
let prepared = classify.prepare(wire, config, request)
let receipt = classify.receipt_codec(wire, questions)
```

Custom wires encode typed `protocol.QuestionView` values and decode typed
`protocol.Answer` candidates. Shared admission validates ids, kinds, labels,
distributions and numeric evidence. Custom headers move from the wire to
`classify.with_headers(config, headers)`; the closure replaces bearer
authentication. `Choice.confidence` and `Score.confidence` change from `Float`
to `Option(Float)`, and classification usage changes to `Option(message.Usage)`.
TypeSafe retains its required wire fields; other wires can explicitly report
unavailable confidence or usage.

Graph `decision` receives a fixed wire where it previously received config.
Its request callback now constructs `graph_classify.call(http, config, model, state)`
from the current approved context. Credentials and limits can change
after approval or recovery without changing receipt decoding. Existing graph
and receipt formats remain readable under their compatible definitions.

The wire's `with_receipt_request_limit` and `with_receipt_response_limit` set
stable evidence bounds. Live `with_request_limit` and `with_response_limit`
remain call settings; exceeding a receipt bound fails preparation before
credential access or I/O. Increasing a limit above 1 MiB requires increasing
both explicit bounds. Decreasing live limits does not narrow stored readers.

Saga reporting now returns the authoritative execution report:

```gleam
// Before: both return and callback contain the classified application result.
reporting.run_owned(workflow, input, config, explain, on_stopped, rollback_within)
// After: return and callback contain Result(execution.Outcome(...), reporting.Error).
reporting.run_owned(workflow, input, config, on_stopped, rollback_within)
```

The callback no longer receives a separate summary argument. For `Ok(report)`,
call `outcome.classify(report, explain)` and `outcome.summary(report)` explicitly.
`Ok` means a report was obtained, including a report of failed or cancelled
work. Operational errors retain typed causes through reporting accessors,
stable `error_kind`, safe `describe_error` and `effect_status`.

The Fabric recipe maps `NotStarted` reporting errors to `Explain` and
`Unknown` to `Uncertain`. Workflow classification retains its existing
completed/compensated/unresolved meanings. Safe summaries now include held,
not-undoable, undo/cleanup failure, interrupted, sibling and unknown-action
evidence without application or crash payloads. Retry policy remains with
the application.

The full Saga recipe grows from 47 to 59 formatted lines. Its gate permits
60 lines; the other recipes retain their 50-line limit. The additional mapping
preserves the distinction between execution reports and reporting errors without
adding another public report model. Support desk and Fabric's app consumer each
add 37 source lines and remove 25; their business behavior remains unchanged.

Validation also fixes test lifecycle assumptions in Fabric and Warden. Fabric
waits for runner exits before asserting an idle shutdown. Warden settles a test
discovery request and stops its owning supervisor before later telemetry tests.
Neither change requires a public API or application migration.

## Round 9 provider fetch ownership

Warden's background discovery, metadata reload and signing-key refresh now
belong to the cache process that started them. Previously, a fetch could
survive cache restart and deliver its old keys to the replacement process's
registered name. A local key-rotation regression reproduced rejection of an
old token followed by acceptance after that stale completion.

After this change, completion targets the original process, and owner exit
cancels its fetch. Unexpected worker exit releases waiting refresh callers
through the existing snapshot/failure behavior. Cached validation stays
available during a refresh. No caller changes are required:

```gleam
// Before and after: clients keep the same lifecycle and validation API.
let assert Ok(client) = warden.new(config)
supervisor.new(supervisor.OneForOne)
|> supervisor.add(warden.supervised(client))
|> supervisor.start
resource.verify(resource.new(client, audience), token)
```

Each active fetch gains one short-lived lifecycle process. Idle clients and
cached validation gain no process. Clients remain independent; no shared
fetch lock or public cancellation setting is added. A cache restart discards
its previous work, so a replacement may need another provider request.
`warden.stop` still requests shutdown and waits up to five seconds for the
client supervisor to exit. Worker exit notifications may arrive afterward
as owner monitoring cancels them.

A full-gate failure also exposed a whole-tree restart race. Previously, a
parent could start the replacement before the old HTTP pool released its
registered name, exhausting the parent's restart allowance. Startup now waits
for the previous client-owned processes to exit before replacing them.
Application-owned stores remain outside that wait.

`config.with_startup_timeout` keeps its signature and default of 15 seconds.
For manual startup, discovery and previous-process cleanup share one absolute
deadline. For supervised startup, this bound applies to local startup cleanup;
background discovery retains its independent retry behavior. A process that
does not exit in time produces the existing startup-timeout failure. No new
configuration or application wiring is required.

This wait is synchronous within child startup. A held previous child can
delay its parent's supervisor management work up to the configured bound;
existing request actors continue serving independently. Startup adds at most
five temporary monitors and removes them on success or expiry.
