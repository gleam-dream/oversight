# support_desk — composition feedback

## Verdict

The combination works through public imports. A fabric agent with three
typed tools runs on a scripted OpenAI Responses provider through
`fabric/llm.model` and a caller-owned http_gun client. Refunds wait for an
approver at fabric's policy gate and then run as a saga through
`fabric_saga`. Compensation, rejection, invalid input, cancellation while
waiting, and an unknown payment outcome all behave as the brief asks.
10 tests pass and `gleam run` prints five tickets and one ticket's
telemetry trail.

- The glue is about 210 lines across six seams (see the glue measure). The
  model wiring and the tool definitions needed almost none.
- One seam is honest only by explicit choice: a payment error that says
  "the refund may exist" is a known failure to saga. Without a `Hold` in the
  step's decider, `fabric_saga` hands the model a definite failure for a
  refund the provider took (SD-1).
- `fabric_saga` drops the run context (SD-2), and telemetry cannot follow a
  ticket from the tool into the saga or into model calls (SD-3).
- The typed final answer is text parsed by the app; the schema reaches the
  model only through the system prompt (SD-4).

## Answers to the brief's questions

- **Does one tool definition need separate fabric, llm_wire and Blueprint
  declarations?** No. Each tool is one `tool.define` over json_blueprint
  codecs (apps/support_desk/src/support_desk/domain.gleam:157-182). Fabric's
  adapter derives the llm_wire declaration from the codec's schema
  (fabric/src/fabric/llm.gleam:80-101); the app writes no llm_wire tool
  code. The provider received `"minimum":1` for the refund amount from
  `integer_between` (test `approved_refund_runs_the_saga_and_resolves_typed_test`).
  The policy matches the refund through the same definition with
  `tool.input` (desk.gleam:147-157). Only the typed final answer needs a
  schema wired by hand (SD-4).
- **How do saga outcomes map onto fabric tool outcomes?** `fabric_saga`
  owns the mapping, and it is sound for what saga knows: `Completed` is the
  output; a `Failed` with every completed step undone is `Explain(explain(error))`;
  `Unresolved`, any unknown effect or anything left in place is `Uncertain`
  (fabric/integrations/fabric_saga/src/fabric_saga/internal/verdict.gleam:51-80).
  The gap is upstream of it: http_gun's `MayHaveBeenSent` reaches saga as a
  returned typed error, which saga records as a known result. The app maps it
  to `saga.Hold` so that the run becomes `Unresolved` and then fabric
  `Uncertain` (SD-1).
- **Can telemetry follow agent → tool → saga → HTTP?** Agent to tool: yes,
  every fabric event carries the run id. Tool to HTTP: yes, but only where the
  tool handler receives the context and the app carries an http_gun
  correlation in it. Tool to saga, saga to HTTP, and model calls: no. In
  the demo, 22 saga events, 100 llm_wire events and every payment, notify
  and model HTTP event belong to no ticket (SD-3).

## Findings

### SD-1 A "may have happened" step error is a known failure to saga unless the author holds it

- **Packages**: saga, fabric (fabric_saga), http_gun. **Kind**: composition. **Severity**: major.
- **Evidence**:
  - The payment adapter maps http_gun's `MayHaveBeenSent` to
    `PaymentOutcomeUnknown` (apps/support_desk/src/support_desk/shop.gleam:63-88).
    The provider in fact takes the refund and answers after the client
    deadline (services.gleam, order `A-400`).
  - Saga counts any returned error as a known result; only a crash, a kill
    at a time bound or a settle-window kill is an unknown effect
    (saga/src/saga/execution.gleam:30-36). With a decider that aborts, the
    run is `Failed(StepFailed(refund_payment, PaymentOutcomeUnknown(_)))` with
    `unknown_effects == []`. Test
    `saga_reports_a_returned_unknown_payment_as_known_unless_held_test`
    (apps/support_desk/test/support_desk_test.gleam:249) asserts both facts.
  - `fabric_saga` then classifies that outcome as definite and hands the
    model `Explain` (verdict.gleam:103-105), so the run continues and a model
    could resubmit a refund that exists.
  - The honest path needs a decider that returns `saga.Hold` for that error
    (refund.gleam:46-55, 10 lines), and `fabric_saga` maps `Unresolved` to
    `Uncertain` (verdict.gleam:60). Even then
    `execution.unknown_effects(Unresolved(..))` is `[]` (same test), so the
    saga card's suggested rule ("non-empty `unknown_effects` → `Uncertain`")
    would also miss it in a hand-written mapping.
- **Proposal** (saga): let a step declare which returned errors leave an
  unknown effect, for example `saga.unknown_when(step, fn(e) -> Bool)`. A
  matching error is recorded in `unknown_effects` and held rather than
  compensated, so `execution.unknown_effects` stays the single check.
  Until then, `fabric_saga`'s module doc should say that such errors must
  be held.

### SD-2 fabric_saga discards the run context

- **Packages**: fabric (fabric_saga), saga. **Kind**: flexibility. **Severity**: major.
- **Evidence**:
  - The handler ignores the context: `fn(_context, input, settlement)`
    (fabric/integrations/fabric_saga/src/fabric_saga.gleam:60). The workflow
    input is the tool input only.
  - The workflow must therefore capture its clients and ledger when the agent
    is built (apps/support_desk/src/support_desk/desk.gleam:93-102), so every
    ticket shares one uncorrelated http_gun client (see SD-3).
  - `fabric.approve` re-runs the approved action "with exactly this context"
    (fabric/src/fabric.gleam:521-522). That is where an approver's identity
    or a per-tenant client would arrive, but the saga never sees it. The
    ledger entry cannot record its approver; the test reads the reviewer back
    from the fabric snapshot instead (support_desk_test.gleam:83-88).
- **Proposal** (fabric_saga): add a required `input: fn(context, tool_input) -> workflow_input`
  argument to `fabric_saga.tool`, so the workflow input can carry what the
  context owns. Callers that need nothing from the context pass `fn(_, input) { input }`.

### SD-3 One ticket cannot be followed from the tool into the saga or into model calls

- **Packages**: fabric, saga, http_gun, llm_wire, sinal. **Kind**: composition. **Severity**: major.
- **Evidence** (test `telemetry_follows_agent_and_tool_http_but_not_the_saga_test`, support_desk_test.gleam:218):
  - A tool handler learns neither its run id nor its action:
    `handler: fn(context, input)` (fabric/src/fabric/tool.gleam:146-148), and
    `fabric.start` mints the run id after taking the context
    (fabric/src/fabric.gleam:166). The app mints its own ticket id and an
    http_gun correlation `Id` per ticket, puts both in the context
    (desk.gleam:40-50, :159-164), and registers the pair with its collector
    (telemetry.gleam:104-105, :318-330). Lookup HTTP calls then join the
    ticket (4 events in the test).
  - Saga metadata has only `workflow` and saga's own `run: Int`
    (saga/src/saga/observation.gleam:23-25, :57-58); this is a known saga card
    concern. The new evidence: through `fabric_saga` (SD-2) there is also no
    way to carry a correlation into the steps, so payment and notify HTTP events
    are uncorrelated as well.
  - Model calls: `fabric/llm.model` binds one client per agent
    (fabric/src/fabric/llm.gleam:42-50) and `model.Request` carries no run id
    (fabric/src/fabric/model.gleam:52-58). A per-run `http_gun.with_correlation`
    view is impossible, unlike a direct llm_wire caller (extractor EXT-4).
    llm_wire's own events carry no id at all (llm_wire/src/llm_wire/telemetry.gleam:17-19).
  - Demo run: the T-1 trail has 18 events (fabric and lookup HTTP). 22 saga
    events, 100 llm_wire events and the refund, notify and model HTTP events
    are unattributable.
- **Proposal**:
  - fabric: add `run: String` to `model.Request`, so `fabric/llm` can tag
    each turn's client view with the run. Add `tool.action(settlement) -> observation.ActionRef`
    so a `bind_settling` handler (and `fabric_saga`) can learn its action.
  - http_gun: `telemetry.id_from(String)`, so a fabric run id can be the
    correlation (same as EXT-4).
  - saga: an optional caller correlation in `execution.Config`, copied
    into every event's metadata.

### SD-4 The typed final answer is parsed text; the schema reaches the model only in the prompt

- **Packages**: fabric, llm_wire, json_blueprint. **Kind**: composition. **Severity**: major (known: fabric card concern 5).
- **Evidence**:
  - `run.Completed(text: String)` (fabric/src/fabric/run.gleam:143). The app
    writes the `Resolution` schema into the system prompt and decodes the
    text with the same codec (apps/support_desk/src/support_desk/desk.gleam:185-214,
    23 lines). An answer that does not decode becomes `Untyped`.
  - The provider never receives an output format: fabric's adapter calls
    only `session.run` (fabric/src/fabric/llm.gleam:66), although llm_wire
    has `prepare_structured` and `run_structured`
    (llm_wire/src/llm_wire/session.gleam:212, :246). A real model is not
    bound to the schema.
  - A run that hits its turn limit has no answer at all
    (`a_turn_limit_ends_the_run_without_a_typed_answer_test`), which the app
    models as `Ended`.
- **Proposal** (fabric): `agent.with_answer(spec, codec.Schema)`. The
  adapter requests structured output for a final answer, and fabric checks
  the text against the schema before it records `Completed`. Callers keep
  decoding with their codec. This needs no new type parameter on `Agent`.

### SD-5 The operator reconciling an uncertain refund gets no application evidence

- **Packages**: fabric (fabric_saga), fabric. **Kind**: ergonomics. **Severity**: minor.
- **Evidence**:
  - `fabric_saga` discards `Unresolved`'s typed evidence (verdict.gleam:60),
    so the uncertain action reads "the workflow held the effects of step
    refund_payment unresolved". The operator never sees the reason, which
    here is a deadline after the request may have been sent. The summary
    excludes application data by design, but the author already vets
    `explain` output as safe for the model.
  - The reconciliation itself is a hand-written JSON string
    (apps/support_desk/src/support_desk.gleam:156) passed to
    `fabric.reconcile(run, effect, content: String)` (fabric/src/fabric.gleam:779).
    `tool.settle` is typed through the output codec (tool.gleam:214), but
    reconciliation is not.
- **Proposal** (fabric_saga): render `Hold` evidence with the existing
  `explain` callback, or with an optional `evidence: fn(error) -> String`.
  (fabric) A `tool.reconciliation(definition, Result(output, tool.Failure)) -> Result(String, codec.EncodeError)`
  helper would render reconcile content through the tool's codec.

### SD-6 Four of six records need a hand-written `record4`

- **Packages**: json_blueprint. **Kind**: ergonomics. **Severity**: minor (known: json_blueprint card concern 2).
- **Evidence**: `record2`/`record3` stop at three fields
  (json_blueprint/src/json/blueprint/codec.gleam:1271, :1298). `Order`,
  `Eligibility`, `RefundReceipt` and `Resolution` each have four, so the app
  wrote one `record4` over `combine`, `object` and a three-level nested tuple
  (apps/support_desk/src/support_desk/domain.gleam:186-208, 23 lines). It is
  written once and reused, so the cost stays contained.
- **Proposal**: as in the card, a property builder that removes the arity
  cliff.

### SD-7 Testing against a built-in provider wire means hand-writing its SSE

- **Packages**: llm_wire. **Kind**: ergonomics. **Severity**: minor.
- **Evidence**: `llm_wire/testing` lowers `text`/`tool_calls` replies only
  into its own scripted wire (llm_wire/src/llm_wire/testing.gleam:63-86,
  :364). To test fabric's adapter on the OpenAI Responses wire, the app
  writes the events itself (apps/support_desk/src/support_desk/provider.gleam:251-350,
  about 100 lines), as extractor did. Fabric's own tests use the scripted
  wire for the same reason.
- **Proposal** (llm_wire): `testing.events_for(types.Provider, Reply) -> Reply`,
  which lowers a semantic reply into each built-in wire's SSE chunks.

### SD-8 fabric, fabric_saga and saga cap gleam_stdlib below 1.0

- **Packages**: fabric, saga. **Kind**: ecosystem-interop. **Severity**: minor.
- **Evidence**: `gleam_stdlib = ">= 0.70.0 and < 1.0.0"` in fabric/gleam.toml:12,
  fabric/integrations/fabric_saga/gleam.toml:11 and saga/gleam.toml:11 (and
  llm_wire, see extractor EXT-10). The app allows `< 2.0.0` and resolved
  stdlib 0.71.0, mist 6.0.2 and gleam_otp 1.3.0 with no conflict. The only
  resolution friction was Hex rate limiting ("The rate limit for the Hex
  API has been exceeded"), which a retry after 60 s cleared.
- **Proposal** (fabric, saga): widen to `< 2.0.0` with the siblings.

### SD-9 http_gun observations need a supervised forwarder; the others emit inline

- **Packages**: http_gun, sinal. **Kind**: ergonomics. **Severity**: nit (known: sinal card, three emission paths).
- **Evidence**: fabric (`emit_routed`, unrouted), saga and llm_wire
  (`sinal.emit`) need only `sinal.observe`. http_gun emits nothing unless
  `config.observations` names a forwarder, so the app starts a supervisor
  for one (apps/support_desk/src/support_desk/telemetry.gleam:82-89) before
  either client.
- **Proposal**: none beyond the sinal card's; the cost is 8 lines.

## Glue measure

Lines of adapter or glue code per seam, excluding blank lines and comments.

| Seam                                                          | Lines | Location                                                                                |
| ------------------------------------------------------------- | ----- | --------------------------------------------------------------------------------------- |
| http_gun failure → saga step error (evidence-aware)           | 50    | shop.gleam:63-88 (refund mapping), :124-148 (`gleam/http` request helper)               |
| Telemetry correlation across fabric, http_gun (saga: none)    | ~40   | desk.gleam:40-50, :159-164; telemetry.gleam:68-74, :104-105, :123-137, :318-330         |
| Saga outcome → fabric tool outcome via fabric_saga            | 38    | desk.gleam:93-102 (10), refund.gleam:46-55 `Hold` (10, SD-1), :107-124 `explain` (18)   |
| fabric ↔ llm_wire ↔ http_gun model wiring and loopback policy | 38    | desk.gleam:81-92 (12), app.gleam:44-59 (16), :82-91 (10); configuration, not adaptation |
| Typed final answer (schema in prompt, decode text)            | 23    | desk.gleam:185-214                                                                      |
| json_blueprint record arity                                   | 23    | domain.gleam:186-208                                                                    |
| One tool definition shared by fabric, llm_wire and policy     | 0     | domain.gleam:157-182 is the declaration itself                                          |

Not counted as glue: the scripted provider (382 lines, of which about 100
are OpenAI SSE builders, SD-7), the scripted services (158), the ledger (77)
and the telemetry handlers themselves (about 150).

## What worked well

- **One definition per tool.** `tool.define` over json_blueprint codecs gave
  the model its declarations (with `integer_between`'s bounds), the
  argument check, and the policy's typed match (`tool.input`). The app wrote
  no llm_wire tool code.
- **Caller-owned client in `fabric/llm.model`.** After fabric 8648f6f, the
  OpenAI adapter ran first time against the loopback provider. Admitting
  loopback was one nested record update (app.gleam:82-91). Starting the
  client is visibly the app's job.
- **The approval gate.** `RequireApproval` suspends the run as data;
  `approve` with a reviewer resumes it, `reject` shows the model
  `{"error":"rejected","detail":reason}`, and `cancel` while waiting ends the
  run with no payment call. A late `approve` then returns `RunEnded`.
- **Invalid input stops before the policy.** An amount of 0 fails the
  codec's range; the action is `InvalidArguments(detail)`, the policy never
  runs, no approval is requested, and the model explains.
- **fabric_saga's mapping and lifecycle.** A failed notification undid
  the ledger entry and voided the refund in reverse order. The model got a
  definite `Explain`. `Unresolved` became an uncertain effect that blocked the
  next model turn until `fabric.reconcile`, after which the agent reported
  the refund as unconfirmed without resubmitting it.
- **http_gun's typed evidence.** `NotSubmitted` versus `MayHaveBeenSent`
  made the honest split possible in a few lines (shop.gleam:74-78), with no
  string parsing.
- **Typed Sinal descriptors.** 17 `sinal.observe` calls across four packages
  received typed metadata with no `Dynamic` handling.
