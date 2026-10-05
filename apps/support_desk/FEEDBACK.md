# support_desk — composition feedback

## Verdict

The combination works through public imports. A fabric agent with three
typed tools runs on a scripted OpenAI Responses provider through
`fabric/llm.model` and a caller-owned http_gun client. Refunds wait for an
approver at fabric's policy gate and then run as a saga through
`saga_tool`. Compensation, rejection, invalid input, cancellation while
waiting, and an unknown payment outcome all behave as the brief asks.
10 tests pass and `gleam run` prints five tickets and one ticket's
telemetry trail.

- The glue is about 210 lines across six seams (see the glue measure). The
  model wiring and the tool definitions needed almost none.
- One seam is honest only by explicit choice: a payment error that says
  "the refund may exist" is a known failure to saga. Without a `Hold` in the
  step's decider, `saga_tool` hands the model a definite failure for a
  refund the provider took (SD-1).
- `saga_tool` drops the run context (SD-2), and telemetry cannot follow a
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
- **How do saga outcomes map onto fabric tool outcomes?** `saga_tool`
  owns the mapping, and it is sound for what saga knows: `Completed` is the
  output; a `Failed` with every completed step undone is `Explain(explain(error))`;
  `Unresolved`, any unknown effect or anything left in place is `Uncertain`
  (saga/src/saga/outcome.gleam).
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

- **Packages**: saga, fabric (saga_tool), http_gun. **Kind**: composition. **Severity**: major.
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
  - `saga_tool` then classifies that outcome as definite and hands the
    model `Explain` (verdict.gleam:103-105), so the run continues and a model
    could resubmit a refund that exists.
  - The honest path needs a decider that returns `saga.Hold` for that error
    (refund.gleam:46-55, 10 lines), and `saga_tool` maps `Unresolved` to
    `Uncertain` (verdict.gleam:60). Even then
    `execution.unknown_effects(Unresolved(..))` is `[]` (same test), so the
    saga card's suggested rule ("non-empty `unknown_effects` → `Uncertain`")
    would also miss it in a hand-written mapping.
- **Proposal** (saga): let a step declare which returned errors leave an
  unknown effect, for example `saga.unknown_when(step, fn(e) -> Bool)`. A
  matching error is recorded in `unknown_effects` and held rather than
  compensated, so `execution.unknown_effects` stays the single check.
  Until then, `saga_tool`'s module doc should say that such errors must
  be held.

- **Status (wave 3):** resolved by saga f27b628 (`saga.unknown_when`, `execution.ActionReturnedUnknown`) and fabric d10635f (`saga_tool` maps a marked error to `Uncertain`). The `Hold` decider is deleted: `refund.gleam` goes from 124 to 107 lines, the `OnUnknown` type, the `workflow_with` wrapper and the 10-line `compensate` are gone, and the step carries a 6-line `unknown_when`. The "refund the provider may have taken" test (`unknown_payment_outcome_pauses_the_run_until_reconciled_test`) passes with the honest outcome and no app trick. The seam test is now `saga_names_a_returned_unknown_payment_as_an_unknown_effect_test`: the run is `Failed(StepFailed(_, PaymentOutcomeUnknown(_)))` and `unknown_effects` is `[StepAttempt(1) ActionReturnedUnknown]`, where it used to be `[]`. One difference from `Hold`: the run ends `Failed`, not `Unresolved`, and saga still rolls back earlier steps, which `Hold` prevented. That is harmless here (the payment is the first step) but see the re-run.

### SD-2 saga_tool discards the run context

- **Packages**: fabric (saga_tool), saga. **Kind**: flexibility. **Severity**: major.
- **Evidence**:
  - The handler ignores the context: `fn(_context, input, settlement)`
    (src/saga_tool.gleam). The workflow
    input is the tool input only.
  - The workflow must therefore capture its clients and ledger when the agent
    is built (apps/support_desk/src/support_desk/desk.gleam:93-102), so every
    ticket shares one uncorrelated http_gun client (see SD-3).
  - `fabric.approve` re-runs the approved action "with exactly this context"
    (fabric/src/fabric.gleam:521-522). That is where an approver's identity
    or a per-tenant client would arrive, but the saga never sees it. The
    ledger entry cannot record its approver; the test reads the reviewer back
    from the fabric snapshot instead (support_desk_test.gleam:83-88).
- **Proposal** (saga_tool): add a required `input: fn(context, tool_input) -> workflow_input`
  argument to `saga_tool.tool`, so the workflow input can carry what the
  context owns. Callers that need nothing from the context pass `fn(_, input) { input }`.

- **Status (round 5):** resolved by fabric fd60851/409f1a7: `saga_tool.tool` takes `input: fn(context, call, input)`. `desk.build` passes `fn(session, call, request) { refund.Refund(shop.correlated(session.shop, call.correlation), request) }`, so the workflow input carries a per-ticket shop and `refund.workflow` no longer captures one (`workflow(shop, ledger)` becomes `workflow(ledger)`). The cost is a wrapper type: `Refund(shop, request)` (7 lines) and each step reads `refund.shop`; the void step reaches it through `undo.input`. The approver is still not on the ledger entry, because the app does not use it.

- **Status (wave 5):** resolved for good by saga 9a0b1d8 (`saga.effect` and `saga.correlation_of(key)`). The `Refund(shop, request)` wrapper is deleted: the tool's `input:` is `fn(_, _, request) { request }`, `refund.workflow(shop, ledger)` takes the one shop when the agent is built, and each step tags it from its key (`shop.correlated(shop, saga.correlation_of(key))`, a 3-line helper in `refund.gleam`). The undo reads the same from `undo.key`. `Session.shop` goes too, since the tools close over `settings.shop`. The approver is still not on the ledger entry.

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
    concern. The new evidence: through `saga_tool` (SD-2) there is also no
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
    so a `bind_settling` handler (and `saga_tool`) can learn its action.
  - http_gun: `telemetry.id_from(String)`, so a fabric run id can be the
    correlation (same as EXT-4).
  - saga: an optional caller correlation in `execution.Config`, copied
    into every event's metadata.

- **Status (wave 2):** partially resolved by sinal 43279b3 (`sinal/correlation`); the app now keys a ticket by its own `Correlation`. The app emits `support_desk.ticket.opened` (ticket correlation plus fabric run id) and `ticket.answered` (`src/support_desk/events.gleam`, 83 lines new), and the collector derives the run-to-ticket join from them, so `telemetry.trail(telemetry, ticket)` no longer takes the run id. The trail grew from 18 to 20 events. The cause is untouched: fabric events still carry a `run: String`, saga and llm_wire carry nothing, and http_gun still uses `telemetry.Id`, so the ticket still has two identities (`Session.ticket` and `Session.http_id`) and `telemetry.register` remains. The 22 saga and 100 llm_wire events stay unattributable until those packages adopt `Correlation`.

- **Status (follow-up):** partially resolved by http_gun c45adfe and 056536b; `desk.correlated` passes `session.ticket` to `http_gun.with_correlation`, so the ticket has one identity. `Session.http_id`, `telemetry.register`, the `Register` message, the collector's id-to-ticket list and `http_obs.new_id()` are deleted (about 45 lines), and the HTTP handler reads `m.correlation` as the ticket directly. The trail stays at 20 events and the four lookup HTTP events still join the ticket. The refund, notify and model calls are still unattributable: saga, saga_tool (SD-2) and `fabric/llm.model` (no run on `model.Request`) give no way to put the ticket on their clients, and llm_wire and saga events carry no correlation.

- **Status (wave 3):** partially resolved by saga 89c1aec: saga events now carry `correlation` and `execution` metadata, and `execution.with_correlation` puts a `Correlation` in them. The app cannot use it: `saga_tool.tool` takes one `Config` when the agent is built, not one per call (SD-2), so no ticket reaches the saga. The demo still prints 22 saga events, 100 llm_wire events and every refund, notify and model HTTP event as unattributable. No app line changed for this finding.

- **Status (wave 4):** partially resolved by llm_wire 9f35183 and http_gun 4a6eeb0: llm_wire reads the correlation from the `http_gun.Client` view, so the 100 unattributed llm_wire events drop to 0 and the model's HTTP events join as well (the T-1 trail grows from 20 to 52 events; `telemetry.trail` now keys `ModelCall(ticket)`). It needed one app change that the guide does not predict: `fabric/llm.model` binds its client when the agent is built, and an agent is built once, so one correlated view per ticket meant one agent per ticket (`desk.open_ticket` calls `build` with `http_gun.with_correlation(llm_client, ticket)`; `Desk` keeps `Settings` instead of an `Agent`, +7 lines). The cause is untouched upstream: `model.Request` still has no run or correlation, so a durable run recovered from the store would need the app to rebuild the same view. Saga and the refund, notify and void HTTP calls stay unattributable (22 saga events), because `saga_tool.tool` still takes one `Config` for all tickets (SD-2).

- **Status (round 5):** resolved by fabric fd60851/409f1a7 (`fabric.start(.., correlation: Some(ticket))`, `model.Request.correlation`, `tool.Call.correlation`, and saga events configured per call). The demo prints `not attributable to any ticket: 0 of 267 events`, where wave 4 left 22 saga events plus the refund, notify and void HTTP events unattributed. The T-1 trail is 60 events (fabric 14, llm_wire 20, http_gun 16, saga 8, desk 2), and `telemetry.trail` is one filter on the event's correlation: the `ticket.opened` run-id join is deleted from it. `desk.open_ticket` builds no agent; `Desk` keeps one `Agent(Session)` again. Test `telemetry_follows_the_ticket_through_every_package_test` asserts `unattributed == []` and a trail equal to all events, and `one_agent_serves_two_tickets_and_keeps_their_events_apart_test` runs two tickets at once on the one agent.

- **Status (wave 5):** the join is complete and now cheap to keep. `telemetry.gleam` changes in three lines: the import is `fabric/telemetry`, and `SagaRun.ticket` is a `Correlation`, not an `Option` (saga's six observers pass `m.correlation` straight in; `ticket_of` wraps it in `Some` to keep one return type). http_gun and llm_wire events still carry `Option(Correlation)`, so `HttpRequest` and `ModelCall` keep their `Option`. The demo prints `not attributable to any ticket: 0 of 267 events`, the same as round 5.

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

- **Status (wave 5):** resolved by fabric F3/F4 (`agent.with_answer`, `run.Completed(answer:)`, `run.AnswerInvalid`, the corrective turn). The 23-line JSON parser (`answer`, `Answer`, `Untyped`) and the schema-in-prompt (`system_prompt()` with `codec.schema_json`) are deleted; the prompt is a constant. The provider now receives the schema as `text.format` (`json_schema`, `strict: true`), and `approved_refund_runs_the_saga_and_resolves_typed_test` asserts that and that the prompt no longer says "JSON Schema". A refused answer gets a corrective turn: provider order `A-600` answers in prose until the corrective user message arrives (`a_refused_answer_gets_one_corrective_turn_test`, 4 model requests), and `with_answer_attempts(1)` ends on `AnswerInvalid` (`one_answer_attempt_ends_on_the_refused_answer_test`, the first test of the `AnsweredUntyped` path through a real run). The turn-limit run still has no answer: `run.BudgetExhausted(run.TurnLimit(2))`.

### SD-5 The operator reconciling an uncertain refund gets no application evidence

- **Packages**: fabric (saga_tool), fabric. **Kind**: ergonomics. **Severity**: minor.
- **Evidence**:
  - `saga_tool` discards `Unresolved`'s typed evidence (verdict.gleam:60),
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
- **Proposal** (saga_tool): render `Hold` evidence with the existing
  `explain` callback, or with an optional `evidence: fn(error) -> String`.
  (fabric) A `tool.reconciliation(definition, Result(output, tool.Failure)) -> Result(String, codec.EncodeError)`
  helper would render reconcile content through the tool's codec.

- **Status (wave 3):** partially resolved by fabric d10635f. With `unknown_when` the operator's evidence now reads "attempt 1 of step refund_payment returned an error after which its effect is unknown", where a held step gave only "the workflow held the effects of step refund_payment unresolved". It still omits the application's reason (a deadline after the request was sent), and the reconciliation is still a hand-written JSON string (`support_desk.gleam`, `unconfirmed`).

- **Status (wave 5):** resolved for the reconciliation by fabric F6 (ee83046): `tool.unconfirmed_reconciliation(note)` replaces the hand-written JSON string, which `support_desk.unconfirmed` (a `const`) now builds as a one-line function. The model sees `{"unconfirmed": note}`, so the scripted provider reads that key instead of `status`. The operator-evidence half is resolved too: F6 renders the held error with the tool's `explain`, and the demo's evidence now reads "held the effects of step refund_payment unresolved: the payment outcome is unknown (Request deadline exceeded; request may have been sent)".

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

- **Status (wave 2):** resolved by json_blueprint 9a6633a (`codec.field`/`success` builder); `record4` and its 23 lines are deleted (`domain.gleam`). The six codecs and their `let assert Ok` for `integer_between` and `string_enum` now read as plain builders. See the re-run for what that cost in line count.
- **Status (follow-up):** the annotation cost this left is resolved by json_blueprint bb4da39 (`get:` last); the six codecs drop all 21 getter annotations and shrink from 105 to 91 non-blank lines, several fields now fitting on one line.

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

- **Status (wave 4):** resolved by llm_wire 177ad50 (`testing.events_for`). `provider.gleam` goes from 382 to 305 lines (345 to 269 non-blank, non-comment): `tool_call_events`, `text_events`, `completed` and `event` (about 100 lines) become `testing.tool_calls`, `testing.text` and a 4-line `wire` that adds the old usage with `testing.with_usage` and lowers with `events_for(message.OpenAI, _)`. The 12 tests pass unchanged against the generated wire, so the provider still accepts what llm_wire emits and fabric still reads what it sends. `events_for` gives `Interrupted` and `Status` replies back unchanged, so `sse` keeps a catch-all arm that answers 500 for them; the app uses neither.

- **Status (round 6):** the caller-built `Reply` is gone for good: llm_wire 36c341c makes `Reply` and `ScriptedCall` opaque, so the app cannot match `Events`/`Interrupted`/`Status` any more, and need not. `wire` and the `sse` case (about 17 lines) become one `sse` of three lines: `testing.with_usage`, then `testing.http_response(message.OpenAI, _)`, then `response.map` to `mist.Bytes`. The unreachable `Interrupted | Status -> status(500)` arm is deleted (`status` stays for the 400). `provider.gleam` goes from 319 to 308 lines; the one other change is `testing.ScriptedCall(..)` to `testing.tool_call(..)`. The 16 tests pass unchanged.

### SD-8 fabric, saga_tool and saga cap gleam_stdlib below 1.0

- **Packages**: fabric, saga. **Kind**: ecosystem-interop. **Severity**: minor.
- **Evidence**: `gleam_stdlib = ">= 0.70.0 and < 1.0.0"` in fabric/gleam.toml:12,
  fabric/integrations/saga_tool/gleam.toml:11 and saga/gleam.toml:11 (and
  llm_wire, see extractor EXT-10). The app allows `< 2.0.0` and resolved
  stdlib 0.71.0, mist 6.0.2 and gleam_otp 1.3.0 with no conflict. The only
  resolution friction was Hex rate limiting ("The rate limit for the Hex
  API has been exceeded"), which a retry after 60 s cleared.
- **Proposal** (fabric, saga): widen to `< 2.0.0` with the siblings.
- **Status (2 Oct 2026):** resolved by fabric db81b79 (fabric and
  saga_tool), saga 26dbc73 and llm_wire 56d793d. `gleam update` resolved
  gleam_stdlib 1.0.5 (was 0.71.0), mist 6.0.3, gleam_crypto 1.6.0; no app
  lines changed, because the app already allowed `< 2.0.0`.

### SD-9 http_gun observations need a supervised forwarder; the others emit inline

- **Packages**: http_gun, sinal. **Kind**: ergonomics. **Severity**: nit (known: sinal card, three emission paths).
- **Evidence**: fabric (`emit_routed`, unrouted), saga and llm_wire
  (`sinal.emit`) need only `sinal.observe`. http_gun emits nothing unless
  `config.observations` names a forwarder, so the app starts a supervisor
  for one (apps/support_desk/src/support_desk/telemetry.gleam:82-89) before
  either client.
- **Proposal**: none beyond the sinal card's; the cost is 8 lines.

- **Status (wave 2):** partially resolved by sinal 1ff1c18: `forwarder.new(name)` is total and takes no capacity, so the app drops the `Result` handling and 3 lines; the supervisor and the `config.observations` wiring stay, because http_gun 1dc20a1 still emits only through its own forwarder (it did not adopt `sinal.emit` plus an application route).

- **Status (wave 3):** resolved by http_gun e55fa1d: events go through `sinal.emit` by default. `telemetry.start` drops the supervisor, the forwarder, the `forwarder` accessor and the 50 ms drain sleep in `observations` (telemetry.gleam 316 to 298 lines, 18 net), and `app.gleam` drops the `with_observations` wiring. The collector's handler only sends a message, so running in the pool is safe here; an app with a slow handler would still route `["http_gun"]` to a forwarder.

## Glue measure

Lines of adapter or glue code per seam, excluding blank lines and comments.

| Seam                                                          | Lines | Location                                                                                |
| ------------------------------------------------------------- | ----- | --------------------------------------------------------------------------------------- |
| http_gun failure → saga step error (evidence-aware)           | 50    | shop.gleam:63-88 (refund mapping), :124-148 (`gleam/http` request helper)               |
| Telemetry correlation across fabric, http_gun (saga: none)    | ~40   | desk.gleam:40-50, :159-164; telemetry.gleam:68-74, :104-105, :123-137, :318-330         |
| Saga outcome → fabric tool outcome via saga_tool              | 38    | desk.gleam:93-102 (10), refund.gleam:46-55 `Hold` (10, SD-1), :107-124 `explain` (18)   |
| fabric ↔ llm_wire ↔ http_gun model wiring and loopback policy | 38    | desk.gleam:81-92 (12), app.gleam:44-59 (16), :84-93 (10); configuration, not adaptation |
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
  loopback was one nested record update (app.gleam:84-93). Starting the
  client is visibly the app's job.
- **The approval gate.** `RequireApproval` suspends the run as data;
  `approve` with a reviewer resumes it, `reject` shows the model
  `{"error":"rejected","detail":reason}`, and `cancel` while waiting ends the
  run with no payment call. A late `approve` then returns `RunEnded`.
- **Invalid input stops before the policy.** An amount of 0 fails the
  codec's range; the action is `InvalidArguments(detail)`, the policy never
  runs, no approval is requested, and the model explains.
- **saga_tool's mapping and lifecycle.** A failed notification undid
  the ledger entry and voided the refund in reverse order. The model got a
  definite `Explain`. `Unresolved` became an uncertain effect that blocked the
  next model turn until `fabric.reconcile`, after which the agent reported
  the refund as unconfirmed without resubmitting it.
- **http_gun's typed evidence.** `NotSubmitted` versus `MayHaveBeenSent`
  made the honest split possible in a few lines (shop.gleam:74-78), with no
  string parsing.
- **Typed Sinal descriptors.** 17 `sinal.observe` calls across four packages
  received typed metadata with no `Dynamic` handling.

## Re-run after fixes (2 Oct 2026)

Package heads: fabric db81b79, saga 26dbc73, llm_wire 56d793d, http_gun
a2869b7. `gleam update` resolved gleam_stdlib 1.0.5 (was 0.71.0). 10 tests
pass, and `gleam run` prints the five tickets, the ledger and the T-1 trail
as before (18 events; 22 saga and 100 llm_wire events still unattributable,
SD-3).

| Seam                                                          | Before | After | Change                                                                        |
| ------------------------------------------------------------- | ------ | ----- | ----------------------------------------------------------------------------- |
| fabric ↔ llm_wire ↔ http_gun model wiring and loopback policy | 38     | 38    | `config.allow_loopback` not adopted: it keeps `allow_public: True`, see below |
| Telemetry correlation across fabric, http_gun (saga: none)    | ~40    | ~40   | none; the `model_turn` usage change needed no edit                            |
| All other seams                                               | —      | —     | unchanged; SD-1 to SD-7 and SD-9 are not addressed by these fixes             |

- **Loopback helper.** `http_config.allow_loopback(config)` sets only
  `allow_loopback: True` (http_gun/src/http_gun/config.gleam:84-89), so on
  `default()` it leaves public destinations admitted. Both clients reach
  only the scripted loopback services, and `loopback()` deliberately closes
  public destinations too (app.gleam:84-93). Using the helper would drop
  that restriction, and restoring it needs the same nested
  `destination.Policy` update, so the app keeps its 10 lines. A companion
  such as `config.deny_public(config)`, or `allow_loopback` documented as
  "in addition to public", would make the two-line intent explicit.
- **Model-turn usage.** `observation.model_turn()` is now
  `Event(Option(Usage), ModelTurn)` and `RunTotals` gained
  `unreported_replies`. The app's handlers ignore the turn measurement and
  read only `totals.turns` (telemetry.gleam:178, :219), so both changes
  compiled without edits.
- **New friction.** None from the packages. The widened stdlib pulled
  mist 6.0.3, glisten 9.0.1 and gramps 6.0.1, whose sources now print nine
  "Deprecated type used" warnings (`Header`, "Use #(String, String)
  instead") during compilation; they come from third-party dependencies and
  need no app change. Hex rate limiting interrupted `gleam update` and the
  first `gleam test` again; a retry after 75 s cleared it.

## Re-run after wave 2

Package heads: sinal 5aef827, json_blueprint f55ec09, fabric 7844fa7,
saga 43ae141, llm_wire bc5d626, http_gun 1dc20a1. 12 tests pass (10 before,
plus two for the app's own events), and `gleam run` prints the five tickets,
the ledger and the T-1 trail (now 20 events with the desk's `ticket.opened`
and `ticket.answered`; 22 saga and 100 llm_wire events still unattributable).
fabric's `fork.result_codec` and `fabric_mcp` contract changes do not touch
this app. Nothing from the fabric `## Unreleased` list needed an edit
(`saga_tool.tool`, `tool.define`, `fabric/llm.model` compiled unchanged).

| Seam                                 | Before                                                             | After                                                    | Change                                                                |
| ------------------------------------ | ------------------------------------------------------------------ | -------------------------------------------------------- | --------------------------------------------------------------------- |
| json_blueprint record arity (SD-6)   | 23 lines of `record4`, 84 for the six codecs                       | 0 glue, 103 for the six codecs                           | -23 glue; codec lines +19 (builder getters carry annotations)         |
| Sinal handler ids and attach results | 20 lines (`observe` helper, suffix, `try_map`, forwarder `Result`) | 0                                                        | -20; `handlers` returns `List(Attachment)`                            |
| `let assert Ok` for definitions      | 3 (`integer_between`, `string_enum`, `handler_id`)                 | 0 in codecs and telemetry                                | -3; 3 remain for `saga.define`, `types.*`, `schema_json`              |
| Telemetry correlation (SD-3)         | ~40 lines, run id passed by the caller                             | ~40 lines plus `events.gleam` (83) and `desk.close` (25) | +108 lines for two new events and a typed ticket id; the join is data |

Net: about 46 lines of glue deleted (23 + 20 + 3). The app gained about 108
lines for ticket events, which is new behavior, not glue: it is what adopting
`sinal/correlation` for an id the app invented costs.

### New friction

- **Two builders, two getter conventions.** **Status (follow-up):** resolved by json_blueprint bb4da39 and sinal 5e8bee3; both builders now take an unannotated `get:` last, and the `fields.and` getter annotation (`fn(m: AnswerMetadata)`) is gone with `and` itself. Original finding: json_blueprint's `field` wants
  the record type on every getter; sinal's `and` wants it on the first only:

  ```gleam
  use order_id <- codec.field("order_id", codec.string(), fn(o: Order) { o.order_id })
  use customer <- codec.field("customer", codec.string(), fn(o: Order) { o.customer })
  // ...
  |> fields.and(correlation.field(), fn(m: AnswerMetadata) { m.ticket })
  |> fields.and(fields.string("run"), fn(m) { m.run })
  ```

  For a four-field record the old `record4(.., fn(o) { o.order_id }, ..)`
  had unannotated getters and fit in 14 lines; the builder takes 19 after
  `gleam format`, because each `fn(o: Order) { o.x }` repeats the type. The
  arity cliff is gone, the noise per field is higher. Typing the getter once
  would help (a `codec.record(Order)` start that fixes `r`), but I did not
  find a way in the current signature.

- **`correlation.field()` is always `Option`.** **Status (follow-up):** resolved by sinal f9cca37 (`correlation.required_field()`); see the re-run below. Original finding: The desk's events always have
  a ticket, yet metadata must hold `Option(Correlation)`, so every emission
  wraps `Some(ticket)` (`events.opened`, `events.answered`) and the collector
  unwraps with a `case` and a `None -> Nil` arm that cannot happen
  (`telemetry.gleam`, the `ticket` closure). A `correlation.required_field()`
  would remove both for app-owned events.
- **Two identities per ticket until http_gun adopts `Correlation`.** **Status (follow-up):** resolved by http_gun c45adfe; see SD-3. Original finding:
  `Session.ticket: Correlation` and `Session.http_id: http_obs.Id` must be
  minted together and joined by `telemetry.register`. The migration guide
  says to use `Correlation` for the app's own events and wait for wave 3, but
  does not say a second id is needed meanwhile; the app now carries both.
- **Event descriptors are rebuilt per call.** `events.ticket_opened()` builds
  the `Event` on every call (`sinal.event` is total but not free), and
  `emit` and `observe` both call it. A module-level constant is not possible
  for a value built with functions, so the app pays a rebuild for each
  emission. Not measured; probably small.
- **`fields.enum` list is unchecked.** `events.answer()` repeats the
  constructors next to a `case`; the compiler checks the `case` but not the
  list. The guide's advice (a round-trip test) is followed in
  `every_answer_kind_round_trips_through_the_event_fields_test`.

### Migration guides

Sufficient. The sinal guide's before/after for `observe`, `forwarder.new` and
`handler_id` covered every edit, and the json_blueprint guide's record,
`string_enum` and `render_json_decode_error` entries covered the codecs; the
app compiled after those edits with no other change. Gaps: (1) the
json_blueprint guide shows the getter annotation rule but not the cost for
wide records; (2) the sinal guide does not say how an app bridges
`Correlation` and http_gun's `Id` before wave 3; (3) neither guide mentions
that `correlation.field()` forces `Option` on app-owned events; (4) the guide
lists no replacement for http_gun's forwarder requirement (SD-9) because
http_gun did not change.

## Re-run after the follow-up fixes

Package heads: json_blueprint bb4da39, sinal 6de2b69, http_gun 056536b.
12 tests pass (unchanged count; one test constructor and the `register`
helper call changed), and `gleam run` prints the five tickets, the ledger and
the T-1 trail as before (20 events; 22 saga and 100 llm_wire events still
unattributable). `gleam format` is clean and the build has no warnings.

| Seam                                               | Before                                                                  | After                                     | Change                                                                                      |
| -------------------------------------------------- | ----------------------------------------------------------------------- | ----------------------------------------- | ------------------------------------------------------------------------------------------- |
| json_blueprint getters (six codecs)                | 105 non-blank lines, 21 getter annotations                              | 91 lines, 0 annotations                   | -14 lines (domain.gleam 201 to 187)                                                         |
| Sinal record builder (two events)                  | 2 `fields.record`/`parameter`/`and`/`build` chains, 3 annotated getters | 2 `use` blocks with `get:`, 0 annotations | events.gleam 83 to 73 lines (-10, including the removed `Option`/`Some` imports)            |
| `Option(Correlation)` for an always-present ticket | 2 `Some(ticket)` wraps, 1 unreachable `None -> Nil` arm, 4-line match   | 0 wraps, 0 arms, closure sends directly   | -9 lines (events and the telemetry `ticket` closure)                                        |
| Ticket identity for http_gun (SD-3)                | 2 ids per ticket, join table, `register` at 2 call sites                | 1 `Correlation`, no table                 | about -45 lines: telemetry.gleam 348 to 316, desk.gleam 259 to 255, 2 `register` calls gone |

Net: 140 lines deleted and 78 added across six files, about 62 net, none of
it behavior. The ~40-line telemetry correlation seam in the glue measure is
about 10 lines now: `desk.correlated` (4), the `ticket` closure (5) and the
`HttpRequest(m.correlation)` read (1), plus the unchanged `ticket.opened`
join and `events.gleam` that carry fabric runs.

### New friction

- **The correlation reaches only the tool calls, so the fix is half the
  story.** One id per ticket is true, but only the lookups carry it. The
  refund and notify HTTP calls run inside the saga on clients captured when
  the agent is built (SD-2), and model calls run on `fabric/llm.model`'s one
  client. The demo still prints "every uncorrelated http_gun event" and the
  test still asserts `HttpRequest(None)` events exist. The http_gun change
  removed the join table, not the cause.
- **http_gun's `correlation` is `Option`, the app's is not.** The collector's
  `HttpRequest(ticket: Option(Correlation))` and the `Some(owner)` filter in
  `trail` remain, correctly, because uncorrelated requests exist. The guide
  states that `field()` and `required_field()` interoperate, which is what
  makes the split safe, but an app that reads both kinds of event holds both
  shapes.
- **`fields.include` runs the block with placeholder values.** The sinal guide
  says to keep a block to `include` calls and `success`. The `answer()` record
  follows that, but a `case` inside `fields.enum`'s encoder is called with each
  list entry at definition time; it is pure here, and the rule is easy to
  break silently in a larger record. A compile-time barrier is not possible,
  so it is a docs-level hazard.
- **`fields.enum`'s constructor list is still unchecked** (previous
  re-run). The round-trip test still guards it; nothing in the new builder
  changes that.
- **A `use` record in argument position needs braces.** `sinal.event(.., {
use .. fields.success(..) })` is a little unusual to read next to the
  function-body form used for `answer()`; the guide shows both, so this is a
  nit.

### Migration guides

Sufficient. The `get:` rule in the json_blueprint guide and the
`required_field()` before/after in the sinal guide matched the edits, and the
http_gun guide's join-table example covered the whole correlation change. The
only gap: the http_gun guide says a join table "is no longer needed" but does
not say that a context type holding the old `Id` (here `Session.http_id`)
must also change, nor that tool calls inside a saga still cannot be tagged.

## Re-run after wave 3

Package heads: saga 2ee5e0a, http_gun 1a5f5ef, fabric d10635f, sinal 44c5395,
json_blueprint 74a9a7d, llm_wire 576482e. 12 tests pass (unchanged count; one
test was rewritten, see below) and `gleam run` prints the five tickets, the
ledger and the T-1 trail as before (20 events; 22 saga and 100 llm_wire events
still unattributable). `gleam format` is clean and the build has no warnings.
The Hex rate limit did not interrupt this run.

| Seam                                                           | Before | After | Change                                                                                                                                  |
| -------------------------------------------------------------- | ------ | ----- | --------------------------------------------------------------------------------------------------------------------------------------- |
| Unknown payment outcome (SD-1): `Hold` decider, `OnUnknown`    | 23     | 6     | `saga.unknown_when` on the step; `workflow_with`, `OnUnknown` and the `compensate` decider deleted (refund.gleam 124 to 107 lines)      |
| Model and shop clients plus loopback policy                    | 26     | 11    | one client with `loopback_only()` and `with_request_timeout`; the shop's 1 s budget is a `with_timeout` view (app.gleam 93 to 71 lines) |
| http_gun observation forwarder, supervisor, drain sleep (SD-9) | ~16    | 0     | default `sinal.emit` delivery; telemetry.gleam 316 to 298 lines                                                                         |
| `saga_tool.tool` `Result` handling                             | 4      | 0     | `tool` returns the tool; `desk.build` keeps `Result` only for the endpoint and `agent.build`                                            |
| http_gun evidence split in `shop.refund`                       | 5      | 7     | two `Failure(evidence: ..)` patterns become `error.evidence(failure)` and a nested `case`: +2                                           |
| Saga callbacks and `Config`                                    | —      | —     | `undo(fn(undo) ..)` and `execution.config() \|> with_max_concurrency(1)`: line-neutral rewrites                                         |
| Telemetry correlation across fabric, http_gun (saga: none)     | ~10    | ~10   | none: `execution.with_correlation` exists but `saga_tool.tool` cannot take a per-ticket `Config` (SD-2, SD-3)                           |

**Status (wave 3 fixes):** SD-1 resolved by saga 92612fd; the unknown payment now ends `Unresolved` (not `Failed`) with `settlement.undone == []`, and fabric 8eb5a16 maps it to `Uncertain`. The refund and fabric-level tests expected no change; only the saga seam test changed.

Source lines (`src/`): 108 deleted, 51 added, net about 57 fewer. The test
file changed by +18 and -15.

- **Test turned from defect to behavior.** `saga_reports_a_returned_unknown_payment_as_known_unless_held_test`
  asserted both defects (an aborting decider gave a clean `Failed`, and
  `unknown_effects` was `[]` even for the held run). It is now
  `saga_names_a_returned_unknown_payment_as_an_unknown_effect_test`: the same
  run asserts `unknown_effects == [UnknownEffect(StepAttempt(1), _, ActionReturnedUnknown)]`
  and an empty ledger. The fabric-level test needed no edit and passes with
  no `Hold`: the model never sees a failure for the A-400 refund, and the run
  pauses until `fabric.reconcile`.
- **Seams that still need glue.**
  - Per-ticket saga correlation and per-ticket saga input: fabric
    (`saga_tool.tool` takes one `Config` and no context mapping; SD-2, SD-3).
  - The refund's `PaymentOutcomeUnknown` mapping from http_gun's `MaybeSent`
    (7 lines in shop.gleam): the app owns it, because only the app knows a
    5xx or a missing refund id also leaves the refund possibly taken.
  - The typed final answer (23 lines, SD-4) and the reconciliation JSON
    string (SD-5): fabric.
  - The scripted OpenAI wire (about 100 lines, SD-7): llm_wire.

### New friction

- **`unknown_when` repeats a decision `shop.refund` already made.**
  `shop.refund` maps the http_gun failure to `PaymentOutcomeUnknown`, and
  `refund.gleam` then matches that constructor again:

  ```gleam
  |> saga.unknown_when(fn(error) {
    case error {
      PaymentOutcomeUnknown(_) -> True
      _ -> False
    }
  })
  ```

  It is 6 lines of `case` for a one-constructor test. A step error type that
  can answer the question itself is not expressible, so a `fn(e) -> Bool`
  that pattern-matches is the only form. It reads fine; it is not free.

- **`unknown_when` marks, but does not hold.** `Hold` kept the run from
  rolling back earlier steps. `unknown_when` with no decider ends the step
  with `Failed(StepFailed(..))`, and saga undoes what completed before it.
  That is right for this workflow, where the payment is the first step. A
  workflow whose uncertain step comes after a payment would void the payment
  while the later effect may exist. The author must still write a `compensate`
  decider returning `Hold` for that case, so `unknown_when` replaces the
  `Hold` trick only for the first-step case and for classification. The
  `unknown_when` doc comment does not say this.

  **Status (wave 3 fixes):** resolved by saga 92612fd; an unknown effect with no decider ends the run `Unresolved` and undoes nothing, so a workflow whose uncertain step follows a payment needs no `Hold` decider. `saga.on_unknown(step, saga.RollBack)` restores the rollback.

- **`error.evidence` reads worse than the old pattern for a two-way split.**
  `Error(Failure(evidence: NotSubmitted, ..) as failure) -> ..` was one arm
  per case; now an `Error(failure)` arm holds a nested `case` on
  `error.evidence(failure)` (7 lines, was 5). The opaque type is the right
  trade for the library, but a split on evidence is the one decision this
  app makes with the failure, and a `Result` helper such as
  `error.map_not_sent(result, fn(f) -> e)` would not read better either.
  No change proposed; recorded as a cost.
- **One client leaves the shop's 1 s budget in a view the app must not
  forget.** `Shop.client` now holds a `with_timeout` view of the shared
  client, so `desk.correlated` stacks `with_correlation` on a view. It
  composed with no surprise, but the llm_wire client gets the bare 10 s
  default only because `desk.Settings.llm_client` is passed the unviewed
  client by hand; nothing prevents passing the shop view to the model.
- **`StartError` needs `describe_start_error`.** The old code used
  `string.inspect`; the new call is one function and returns a readable
  string. Not friction, but `app.gleam` no longer imports `gleam/string`.

### What worked well (wave 3)

- `destination.loopback_only()` is the clearest change: the 10-line nested
  `Policy` update and its comment about `allow_loopback` leaving public hosts
  open collapse to one call, and public hosts stay denied as before.
- `unknown_when` plus fabric d10635f made the app's most important test pass
  with the honest outcome and no app code that knows about `Uncertain`.
- `saga_tool.tool` returning the tool removed an error path that could
  never fail for this app.
- Default `sinal.emit` delivery from http_gun removed the app's only
  supervision glue for observability.

### Migration guides

Sufficient. The saga guide's `unknown_when` entry and its support_desk note
predicted the SD-1 change exactly; the http_gun guide's `loopback_only`,
`Failure` and `Kind` entries covered every compile error. Gaps: (1) neither
guide says `unknown_when` without a decider ends `Failed`, not `Unresolved`,
and still rolls back earlier steps; (2) the saga guide lists `execution.Config`
setters but not that `saga_tool.tool` cannot take a per-call one, which is
what stops the new `with_correlation` from helping an agent.

**Status (wave 3 fixes):** gap (1) resolved by saga 92612fd; the follow-up section documents `Unresolved`, no rollback by default, and `on_unknown`. Gap (2) is unchanged (fabric).

### After the follow-up fixes

12 tests pass (unchanged); `gleam run` and `gleam format` are clean, with no
warnings. `saga.define` is total, so `refund.workflow` lost its
`let assert Ok(workflow)` and trailing `workflow` (3 lines). The saga seam
test now asserts `Unresolved(_, PaymentOutcomeUnknown(_), settlement)` with
`settlement.undone == []`, where it asserted `Failed(StepFailed(..))`. Source:
7 lines removed, 6 added (refund.gleam 107 to 106, all in docs and `define`).
Test: 7 removed, 7 added. grind, `durable`, `describe_cause` and
`http_gun` additions are not used by this app.

## Re-run after wave 4

Package heads: fabric 556abc3, llm_wire 9f35183, http_gun 4a6eeb0, saga af644b0,
sinal 44c5395, json_blueprint 74a9a7d. 12 tests pass (unchanged count; the
telemetry test was rewritten, see below) and `gleam run` prints the five
tickets, the ledger and the T-1 trail (52 events, was 20). `gleam format` is
clean and the build has no warnings. The Hex rate limit hit the first
`gleam run` once; a retry after 60 s cleared it.

| Seam                                                           | Before | After | Change                                                                                                                                                                                             |
| -------------------------------------------------------------- | ------ | ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Scripted OpenAI wire (SD-7)                                    | ~100   | ~12   | `testing.events_for(message.OpenAI, ..)` with `testing.text` and `tool_calls`; provider.gleam 382 to 305 lines                                                                                     |
| llm_wire configuration (key, model id, endpoint)               | 12     | 4     | `openai.new(key) \|> openai.config \|> llm_wire.with_endpoint(url)` and `llm.model(client, config, "gpt-4.1-mini")`; no `types.api_key`, `model_id` or `endpoint` asserts and no endpoint `Result` |
| llm_wire telemetry handler                                     | 10     | 10    | `event()`, `stage_name`, `outcome_name`; the key changes from `Unkeyed` to `ModelCall(m.correlation)`, and the `Unkeyed` variant is deleted                                                        |
| Millisecond conversions                                        | 3      | 0     | `shop_deadline_ms: Int` becomes `shop_deadline: Duration`; `Milliseconds(10_000)` becomes `After(duration.seconds(10))`; the view timeout takes `After(shop_deadline)`                             |
| Model calls joined to the ticket (SD-3)                        | 0      | 7     | one agent per ticket over `http_gun.with_correlation(llm_client, ticket)`; `Desk.agent` becomes `Desk.settings`                                                                                    |
| Rebuilt `Failure`s, private turn envelope, `_structured` twins | 0      | 0     | none in this app; there are no stored turns or fixtures (the store is in-memory), no structured output and no `Failure` construction                                                               |

Source lines (`src/`): about 115 deleted, 55 added. The test file changed by
+20 and -11 (`gleam_time` import, `Duration` argument, the telemetry test).

- **Telemetry test rewritten.** `telemetry_follows_agent_and_tool_http_but_not_the_saga_test`
  is now `telemetry_follows_agent_tools_and_model_but_not_the_saga_test`.
  It asserts 12 http_gun events in the trail (4 lookups plus 4 model turns
  at 2 each, was 4), that the trail holds every llm_wire event, and that
  saga events and the refund and notify HTTP calls are still outside it.
- **Seams that still need glue.**
  - Per-ticket saga correlation and input: fabric (`saga_tool.tool`, SD-2).
  - Per-ticket model view: fabric (`model.Request` has no run), now 7 lines
    plus a rebuilt agent per ticket.
  - The `PaymentOutcomeUnknown` mapping (7 lines in shop.gleam) and the
    `unknown_when` repeat: the app.
  - The typed final answer (SD-4) and the reconciliation JSON string
    (SD-5): fabric.
- **Old fixtures.** The app stores nothing across runs and keeps no
  cassette or turn fixture, so there is nothing to prove decodes. The
  nearest evidence is that the generated OpenAI stream drove all four model
  turns of every scenario with the same call ids (`call_n`), arguments and
  `"minimum":1` in the request body that the hand-written stream produced.

### New friction

- **An agent per ticket is the honest consequence of a bound client.** **Status (round 5):** resolved by fabric fd60851 (`model.Request.correlation`; `fabric/llm` tags the view per turn); `Desk` holds one agent again. Original finding: The
  wave 4 correlation rule ("set it once, on the view") assumes the caller
  chooses the view per call. `fabric/llm.model` takes the view when the model
  is built, so the only way to correlate model calls with a ticket is to build
  the model, and therefore the agent and its tools, per ticket. It is cheap
  here, but `Desk` lost its single built `Agent`, and `desk.start` now builds
  one agent only to reject bad settings. A per-request view
  (`model.Request.correlation`, or a `fn(Request) -> Client`) would keep one
  agent for all tickets.
- **The ecosystem rule stops at fabric.** **Status (round 5):** resolved by fabric fd60851: `fabric.await(handle, within: duration.seconds(10))` and `rollback_within: duration.seconds(5)`; no millisecond literal is left in the app (src or tests). Original finding: `fabric.await(handle, 10_000)`,
  `saga_tool.tool(.., rollback_within: 5000)` and the test timeouts are
  still `Int` milliseconds, next to `Duration` for the shop view and the
  client. 556abc3's CHANGELOG moves fabric onto the wave 4 APIs but does not
  apply the rule to fabric's own public API.
- **`events_for` is a three-line win with a quiet caveat.** It lowers
  `Interrupted` and `Status` replies back unchanged, so a server that turns a
  reply into an HTTP response must still handle all three constructors
  (`sse` answers 500 for the two it never receives). Nothing wrong with the
  function; the type simply does not say "a reply that produces a stream".
- **Third-party warnings.** Not new: the `Header` deprecation warnings from
  mist and glisten remain.

### What worked well (wave 4)

- The llm_wire guide's `support_desk` entry named every file and line, and the
  "After" snippet for `events_for` was the code that compiled.
- Correlation on the view is the right shape: one `http_gun.with_correlation`
  tagged the llm_wire events, the model's HTTP events and the lookups, with no
  llm_wire-level setter and no join table.
- `Duration` in the client configuration removed a class of unit doubts; the
  `shop_deadline` argument reads at the call site (`duration.seconds(1)`).

### Migration guides

Sufficient for the compile errors. Two gaps: (1) the llm_wire guide says the
correlation is read from the view but not that `fabric/llm.model` fixes the
view when the agent is built, which is why a per-ticket agent is needed;
(2) the support_desk entry lists `provider.gleam` as "no llm_wire import" but
the replacement needs `llm_wire/testing` and `llm_wire/message`, so the app
gains an llm_wire dependency in its test server, which it already had in
`gleam.toml`.

### After round 5

Package heads: fabric fd60851/409f1a7 (local), the others as above. 14 tests
pass (12 before: the telemetry test was rewritten, and two were added);
`gleam run` prints the five tickets, the ledger and the T-1 trail; `gleam
format` is clean and the app builds with no warning of its own.

| Seam                                    | Before                                                   | After                                                                      | Change                                           |
| --------------------------------------- | -------------------------------------------------------- | -------------------------------------------------------------------------- | ------------------------------------------------ |
| Agents built                            | one per ticket (plus one at start)                       | one, at `desk.start`                                                       | `Desk.settings` becomes `Desk.agent`             |
| Model-call correlation                  | per-ticket `http_gun.with_correlation` view, 7 lines     | `correlation: Some(session.ticket)` in `fabric.start`                      | -7 lines, `build` loses its client parameter     |
| Tool and saga HTTP correlation          | `desk.correlated(session)`, lookups only (6 lines)       | `shop.correlated(shop, call.correlation)` in 3 handlers, saga included     | helper moves to `shop.gleam` (+8), `desk` -6     |
| Saga workflow input                     | `RefundRequest`, shop captured at build                  | `Refund(shop, request)` from `saga_tool.tool`'s `input:`                   | +9 lines in `refund.gleam`                       |
| Ticket to run join in `telemetry.trail` | 19 lines: collect `TicketRun` run ids, match `FabricRun` | 1 filter on `ticket_of` (fabric and saga events now carry the correlation) | `trail` 19 to 5; `ticket_of`, `unattributed` +16 |
| Millisecond literals                    | 3 in src, 9 in tests (`10_000`, `5000`)                  | 0                                                                          | `Duration` everywhere                            |
| Waiter processes                        | 0                                                        | 0                                                                          | the app never had one; `await_with` not needed   |
| Idempotent open                         | none: a second `open_ticket` started a second run        | run id `ticket-<ticket>`; `AlreadyStarted` opens the stored run            | +20 lines in `desk.open_ticket`, new behavior    |

Source lines (`src/`): 110 removed, 157 added, net 47 more. The deletions are
the per-ticket agent, `correlated`, the run join and the millisecond
literals, about 35 lines of glue. The additions are mostly behavior the
brief asked for or the measure needs: the idempotent open (about 25 lines),
the `Refund` wrapper (9), `shop.correlated` (8) and `ticket_of` plus
`unattributed` (16). Tests: +65, -27 (two tests added).

- **Unattributed events per run: 0 of 267** in the demo (was 22 saga events and
  every refund, notify, void and model HTTP event). The bound is weak: it
  holds because every path the desk takes passes `session.ticket` into
  `fabric.start`. With `correlation: None`, fabric derives the correlation
  from the run id, so the events would carry a correlation that is not the
  ticket's and drop out of the trail, while `unattributed` (which counts
  events with no correlation) would still report 0. The measure cannot see
  that failure; the trail-equals-all assertions in the tests can.

### New friction

- **Two sources for one ticket id.** `Session.ticket` and `tool.Call.correlation`
  are equal only because `open_ticket` passes `Some(session.ticket)`. Tools
  now read the call's, but `close`, `events.opened` and `events.answered`
  still read the session's. Nothing ties them; a caller who opens a run
  elsewhere with another correlation would split the trail. Dropping
  `Session.ticket` would mean `close` reads the correlation back from the run
  (`fabric.snapshot`?), which the app did not try.
- **A saga step cannot read the run's correlation.** `saga_tool` puts
  `call.correlation` on the Saga run's events, but a step gets only its input.
  The HTTP calls join the ticket only because the app also builds a correlated
  `Shop` into the workflow input, so the same value reaches saga twice by two
  routes. `Refund(shop, request)` and the `shop.refund`, `shop.void` and
  `shop.notify` calls are the app's cost for that. A step-level accessor
  (`saga.correlation(context)`) would let the workflow keep a plain client.
- **`AlreadyStarted` is a start error but the idempotent answer is a run.**
  `open_ticket` handles it with `fabric.open(store, agent, session, id)` and
  maps `RecordError` back into `StartRefused` (8 lines). A
  `fabric.start_or_open` would be one call. Also, the second prompt is
  dropped without notice, which is right for a retried job and surprising for
  a customer who wrote again; the desk cannot tell the two apart.
- **A ticket must be a valid run id.** `correlation.from_string` admits 1 to
  128 arbitrary bytes, while `run.parse_id` admits letters, digits, `-` and
  `_` up to 128 including the `ticket-` prefix. A ticket id with a space or a
  `.` is refused as `StartRefused`. Hashing with `correlation.from_key` would
  avoid that, but then the run id is not readable in the trail.
- **The saga's run counter is process-global.** T-1's saga run is `refund#6`,
  not `#1`: saga numbers its runs per process, so it is not a join key and the
  trail needs the correlation, which is what it now has.

### Migration guide

Sufficient. The round 5 guide's support_desk row named every compile error
(`start`, `_call`, `input:`, `Duration`) and predicted the single agent. It
says "the ticket's saga events now join it" but not that the saga's HTTP
calls still need the app to put a correlated client in the workflow input.

### After wave 5

Package heads: fabric a19b48c (local), saga 9a0b1d8, llm_wire 2c32d5e. 16 tests pass (14 before: two tests added for the corrective answer turn; an assertion on the schema and one on `error_kind` added to existing tests); `gleam run` prints the five tickets, the ledger and the T-1 trail; `gleam format --check` is clean and the app builds with `--warnings-as-errors`.

| Seam                         | Before                                                                | After                                                                         | Change                                          |
| ---------------------------- | --------------------------------------------------------------------- | ----------------------------------------------------------------------------- | ----------------------------------------------- |
| Final answer                 | `answer` parser, `Answer` type, schema in the prompt (about 35 lines) | `agent.with_answer(domain.resolution())`; tests match `run.Completed`         | `desk.gleam` -35; `close` returns `Nil`         |
| Saga step context            | `Refund(shop, request)` wrapper, per-call shop in `input:`            | `saga.effect` + `correlation_of(key)`; `input: fn(_, _, request) { request }` | wrapper type (7) gone; `correlated` helper (+4) |
| Start errors                 | `StartError`, `StartRefused` x2, `run.parse_id` (14 lines)            | `fabric.Error`, `run.id_from_parts`, `AlreadyStarted(id, ..)`                 | `open_ticket` 40 to 30 lines with its doc       |
| Reviewer                     | `Some("alice")`, `None` in 6 tests                                    | `desk.approver_named(name)`: `reviewer.new` and a `Result`                    | +9 lines in `desk`, +5 in the test helper       |
| Limits                       | `Settings.limits: agent.Limits`, `default_limits()`, `with_limits`    | `Settings.tune: fn(Spec) -> Spec`; tests pass `agent.with_max_turns(_, n)`    | -2 lines; no record update in 3 tests           |
| Read tools after a crash     | uncertain effect                                                      | `tool.with_replay(3)` on both lookups                                         | +2 lines, no test (see gaps)                    |
| Command failures in the demo | `let _ = fabric.approve(..)`, errors dropped                          | `refused(error)` branches on `fabric.error_kind`                              | +9 lines in `support_desk.gleam`                |

Lines in `src/`: 139 added, 136 removed (net +3). Production code (`desk`, `refund`, `app`, `telemetry`) is 88 added, 109 removed (net -21). The additions elsewhere are the demo's error handling (+9) and the test provider's `A-600` quirk (+15). Tests: 103 added, 34 removed, of which about 30 added lines are the two new tests.

- **Unattributed events per request: 0 of 267** in the demo, as in round 5. Nothing moved because round 5 had already joined every event; wave 5 only made the saga half total (`Correlation`, not `Option`). The caveat from round 5 holds: the measure counts events with no correlation, and a run started with `correlation: None` would still report 0 (its events carry a correlation derived from the run id). The trail-equals-all test assertions are what detect that.

### Gaps left

- **No authenticated approver.** The desk has no sign-in. The approver is a name the scripted console passes (`ApproveAs("alice")`), so `desk.approver_named` builds `reviewer.new(name)` with no issuer, because an issuer would claim a vouching party that does not exist. The typed reviewer is therefore as honest as the console, and `reviewer.subject(who) == "alice"` proves only that the string made the round trip. The new API fits an app that has claims; here it is a typed wrapper around a string, plus a `Result` the demo must `let assert`.
  **Status (round 7):** resolved by warden 77da944. Approvers sign in at `warden/testing`'s scripted OIDC provider (`app.sign_in`: `begin_login`, `testing.authorize`, `complete_login`, `access_token`) and answer with the access token. `desk.approve` and `desk.reject` take an `approvers.Credential` (`Bearer(token)` or `Anonymous`), never a name; `approvers.authenticate` runs `resource.verify` and builds `reviewer.new(sub) |> reviewer.with_issuer(iss)` from the claims, handling both `Result`s. `desk.approver_named` is deleted. A missing, expired, forged, unsigned, wrong-issuer or wrong-audience credential returns `desk.NotAuthenticated(approvers.Error)` and fabric never sees it. The stored approval now holds `alice` and the provider's issuer (`reviewer.issuer(who) == Some(testing.issuer(app.identity))`). What it does not fix is below.

- **A second message on a ticket is reported, not applied (F6).** `open_ticket` now returns `Opened(run:, message:)` with `Applied`, `Repeated` (`same_input: True`, a retried open) or `NotApplied` (`same_input: False`), and the demo prints "the message was not applied" for the last. That is the whole fix the desk can make: fabric has no command to add a message to a running run, so a follow-up still cannot reach the agent, and the caller must tell the customer or open another ticket. Cost: +15 lines in `desk.gleam` for the two types, a one-arm change in `main` and in the test helper; `opening_a_ticket_twice_returns_its_one_run_test` now asserts `Repeated` and `NotApplied`.
- **`tool.with_replay` is untested here.** Proving it needs a crash of the runner mid-lookup; the app has no such harness. It is a one-line declaration backed by fabric's own tests.
- **`Session.ticket` and `call.correlation` are still two sources** for one value (`close`, `events.opened` and `events.answered` read the session's). Nothing in wave 5 touched that.
- **`ticket.answered` repeats fabric's `run.stop`.** Fabric's `OutcomeKind` now has `AnswerInvalid`, so the desk's `AnsweredTyped/Untyped/Nothing` event adds no information a fabric event lacks. It stays because `telemetry.trail` and the tests use it, but it could be deleted with `events.Answered`.
- **F6 helpers with nothing to replace.** `run.describe_action_state`, `describe_host_failure` and the two `*_kind` functions have no use here: the app never matches an `ActionState` to log it, and `run.Status` has no `describe_status`, so the demo's "stuck" line is still `string.inspect(status)`.
- **An unreadable record on a taken id** now returns the read's error (F6) instead of `AlreadyStarted(_, False)`. `open_ticket`'s catch-all passes it through, so a corrupt stored ticket is no longer reported as `NotApplied`; no test provokes it.
- **A start whose result is unknown.** `fabric.Error` has `StartUnconfirmed(id, reason)`; `open_ticket` returns it as is. Calling `open_ticket` again would find the run by its id, so the caller's retry is sound, but the demo has no test of it.

### New friction

- **`Settings.tune` is a type to spell.** Keeping a general hook needs `fn(agent.Spec(Session, Resolution)) -> agent.Spec(Session, Resolution)` in the record and in `app.start_with`. The alternative, one field per knob (`max_turns: Int`), is shorter but then every new limit is a new field. Setters on a spec are good for a pipeline and awkward to pass through an app's settings; an `agent.Tuning` or a documented pattern would help.
- **`Spec(context, answer)` leaks into every signature.** `Desk`, `build`, `open_ticket`, `close`, `drive` and the test helpers all name `Resolution` next to `Session`. It is correct, and the compiler found each one, but a type alias in the app (`type Ticket = fabric.Run(Session, Resolution)`) is the natural fix and the guide does not mention it.
- **`reviewer.new` returns a `Result` for a value the app wrote in source.** The demo's names are literals and the `let assert Ok(..)` is noise; a literal could not exceed 256 bytes. Where a name comes from a token the `Result` is right, which is the case the guide describes.
- **`describe_config_errors` (F6) removed the per-error join** in `desk.build`, and the `gleam/list` import with it.
- **`Completed` and `AnswerInvalid` are siblings of the budget and cancel outcomes.** Every caller that wants the typed answer writes `Ok(run.Finished(run.Completed(resolution)))`, and one that wants to explain a failure needs a catch-all (`run.describe_outcome` covers it well). The `finish` test helper is the one place that asserts all of it.
- **The corrective turn changes what a scripted provider must do.** The stateless test provider decides from the conversation, and the corrective message is the only signal that a refusal happened. It matches the message's text (`Your final answer could not be read`), which fabric's guide documents but does not export as a constant.

### Migration guide

Sufficient, and the order of its slices matched the order of compile errors. It named every break in this app: `desk.gleam`, `app.gleam`, `support_desk.gleam`, the tests and `telemetry.gleam:224-261`. Two things it did not predict: `agent.Spec` now has two type parameters, so a `Settings` field that holds a spec hook needs both; and `fabric.Run(Session)` and `Agent(Session)` in the tests each needed the answer type added. The saga guide's "after" snippet for `saga.effect` still matches `saga.correlation_of(key)` as an `Option` (`Some(correlation) -> .. None -> ..`); the function returns a plain `Correlation`, as the text below it says, and that snippet does not compile.

### After round 6

llm_wire 36c341c, fabric 3d4b840. The only edit is `provider.gleam` (SD-7 status above). The app uses no graph runtime, MCP serving or provider safety stop, so none of the fabric round 6 changes touched it. 16 tests pass, `gleam format --check` and `--warnings-as-errors` are clean, and `gleam run` prints the same five tickets, the ledger and `not attributable to any ticket: 0 of 267 events`.

New friction: none. The one `Reply` question left is that the scripted provider cannot script a safety stop (`testing.content_filtered`) without a new ticket case; the desk has no ticket that needs one.

### After round 7

warden 77da944, fabric 3d4b840. 19 tests pass (16 before, plus three: no credential, an expired token, and five forged, foreign-issuer, malformed or wrong-audience tokens), `gleam format --check` and `--warnings-as-errors` are clean, and `gleam run` prints the approver's subject and issuer (`approved by alice (issuer https://localhost:PORT)`), a refused anonymous attempt on T-1 that leaves the approval pending, and `not attributable to any ticket: 0 of 267 events`. The suite takes about 7 s with Postgres up (every test now also starts a TLS provider and a Warden client).

Lines: `approvers.gleam` +78, `desk.gleam` +45 (`approve`, `reject`, `AnswerError`, an `authenticate` helper; `approver_named` -9), `app.gleam` +36 (provider, client, validator, `sign_in`), `telemetry.gleam` +5, `support_desk.gleam` +60 (sign-in, the anonymous attempt, `who`). Tests: three new and a `signed_in` helper replacing `approver`; every approval in the suite now goes through `desk.approve` and a real token.

Friction, and how well Warden and fabric compose here:

- **Fabric does not tie a `Reviewer` to authentication; the app does by convention.** `reviewer.new` takes any string, and `fabric.approve` is still callable with `reviewer.new("anyone")`. The guarantee here is only that `desk.approve` is the one function the app exposes. A `Reviewer` that could only come from a verified identity (a fabric function that takes a proof, or a warden type the reviewer accepts) would make the property checkable. As it stands, grep is the check.
  **Status (round 8):** resolved by fabric 98a3684: `fabric.approve` and `reject` take an `approvers.Proof` that only `approvers.check` makes, and the agent refuses a proof from other approvers (`OtherApprovers`), even a rebuilt copy of the same recipe over the same validator (test `a_proof_from_other_approvers_is_refused_test`). `reviewer.new("anyone")` no longer reaches `approve`.
- **Warden has no function from its output to `Reviewer`, and two sources of "who".** `warden.session_identity` (ID-token `sub`/`iss`) and `resource.AccessClaims` (access-token `sub`/`iss`) both fit. I took the access token because `resource.verify` is the one call that validates expiry, signature, issuer and audience in a pure function with typed errors; a restored `warden.Session` answers `SessionNotFound` for an expired session but offers no check that a caller-held reference is current without a store round-trip. The cost: an access token is meant for calling an API, and here the desk is its own resource server. The glue (`approvers.authenticate`, 25 lines) is mostly mapping `resource.ErrorKind` onto the desk's `Error`.
- **Authentication is not authorization, and neither package says who may approve.** Any identity the provider signs in (`mallory`) can answer `refund-approver`. Fabric's `Requirement` names a role, but `approve` does not check that the reviewer holds it, and Warden's `with_required_scopes` would make a missing scope `Forbidden`. I left that unused: the scripted provider's login tokens carry no approver scope I could script without a new test hook. So the typed reviewer is now honest about who, and silent about whether they were allowed.
  **Status (round 8):** resolved by fabric 98a3684 and warden f6120ef. `approvers.warden_approvers` (fabric's recipe, verbatim) checks the scope `approve:<requirement name>`; the desk's requirement is `refund-approver`, and the provider grants it to alice, bob and carol with `testing.with_granted_scopes`, and `openid` only to mallory. A signed-in mallory gets `desk.NotAuthorized` for both `approve` and `reject`; the approval stays pending and no payment is made (test `a_signed_in_approver_without_the_scope_is_not_authorized_test`, demo T-4).
- **`resource.ErrorKind` has a `Forbidden` the desk can never see** (no required scopes), so the `Rejected | Forbidden` arm is dead code that exists to be exhaustive. `TokenError` is an open union by design, so only `describe_error` is safe to log; the reason string stays in `Rejected` for logs only.
- **Warden's HTTP traffic lands on the desk's ticket telemetry.** Its http_gun client emits to the same global event, so the first run had 6 to 8 uncorrelated events per test (`unattributed` failed in two tests). A person's sign-in belongs to no ticket, and `warden.with_correlation` only helps when the caller has a correlation to give. The fix is a filter on the client label (`Some("warden")`) in `telemetry.gleam`: a string the two packages agree on by documentation, not by type.
- **The sign-in is played in process.** The desk serves no HTTP callback, so `app.sign_in` does what the browser would (`begin_login` with `request.new()`, `testing.authorize`, `complete_login`). That is the documented unit-test path and is 12 lines, but it means the demo does not exercise the cookie, redirect or `/callback` route that an operator console would. `sso_portal` is the app that does.
- **The approver is on the fabric record, not in the saga.** `fabric.approve` takes the reviewer and the context separately, and `saga_tool`'s `input:` sees only the context, so the ledger entry still has no approver. The workaround is to put the reviewer in `Session` when approving; not done, because `Session` is the ticket's context and carrying an approver in it would make it a per-answer value.
- **`approval.answer` telemetry does not name the reviewer.** The trail shows `issue_refund Approved`; who approved is only in the snapshot.

### After round 8

fabric 98a3684, warden f6120ef. 21 tests pass (19 before, plus two: a signed-in approver without the scope is `NotAuthorized` on approve and reject, and a proof from approvers built a second time is refused). `gleam format --check` and `--warnings-as-errors` are clean. `gleam run` shows alice approving and mallory refused on T-4 (`refused, still pending: not authorized: the token lacks the scope approve:refund-approver`), the anonymous attempt on T-1 refused, and `not attributable to any ticket: 0 of 267 events`.

Lines, before to after: `approvers.gleam` 78 to 42 (the recipe with its `denial` mapper; `Credential`, the five-case `Error`, `describe` and the opaque wrapper are gone), `desk.gleam` 317 to 335 (`AnswerError` grows from two to four cases and carries reasons as `String`; `approve` and `reject` call `approvers.check` and pass the proof; `with_approvers` is one line), `app.gleam` +16 (four `with_granted_scopes` lines, `approver_scopes`, `anonymous`), `support_desk.gleam` +15 (`UnscopedFirst` for mallory), tests 501 to 534 (two new tests; the token tests shrink because the refusal is a variant of `AnswerError`). The app's own code that builds a `Reviewer` from claims is deleted.

Friction:

- **The credential type is `String`, so "no credential" has no value.** The recipe's `Approvers(String)` cannot say `Anonymous`; the desk keeps a convention (`app.anonymous = ""`), which warden refuses as an empty token. An app that wants a typed credential (`Bearer` or `Anonymous`) has to write its own `verify`, and then it is not the recipe.
- **The reason string is the only detail left.** `NotAuthenticated(reason)` lumps expired, forged, wrong-audience and malformed tokens together. The old `WrongAudience` case was a distinct app error; tests now match the case, or the reason text (`"expired"`). That is fine for a 401, but a caller that wants to say "wrong resource" has to parse text.
- **The scope name is agreed by string in two places.** The recipe builds `"approve:" <> requirement.name`, and `app.approver_scopes` builds the same string for the test provider. In production the identity provider owns it. Nothing ties the two by type; a typo makes every approver `NotAuthorized`, which is at least loud.
- **The proof is a hidden second step.** `desk.approve` is now `check` then `fabric.approve`, with a 60 s proof lifetime between them. The desk calls them back to back, so the lifetime never matters here, but a handler that checks early (to fail fast with a 401) and answers after a slow step would meet `ProofExpired`.
- **Approvers compare by identity.** A second `warden_approvers` call compiles and fails at runtime with `OtherApprovers("warden")`, which names the verifier but not that it is a copy of the agent's. The single-boot rule holds here only because `Settings.approvers` is the one place the value lives.
- **Still open from round 7:** the ledger entry has no approver, and `approval.answer` telemetry does not name the reviewer. The proof carries the verifier, so the trail could name both; fabric does not emit them.

### After round 9

- **Status (round 9):** outcome classification lives in `saga/outcome`; held
  effects and returned unknown effects still become `Uncertain` (SD-1).
- **Status (round 9):** the application owns the 47-line `saga_tool` recipe.
  It retains native inputs, context, cancellation rollback and late settlement
  through `saga/reporting.run_owned` (SD-2).
- **Status (round 9):** the recipe passes the call correlation to saga; steps
  keep reading it from their effect keys (SD-3).

Application source removes 5 lines and adds 52, including the 47-line recipe.
Dependency manifests remove 4 lines and add 1. Documentation is excluded from
those counts. The app owns more source despite removing a published dependency:
that is the concrete maintenance tradeoff. The recipe stays generic and adds no
business types, but the owner-lifetime and rollback-budget requirements still
need explanation. Fabric's exact-copy gate guards the canonical consumer and
two documentation copies; this app's copy must be refreshed deliberately when
that recipe changes. No mapping policy or receiver lifecycle is duplicated here.

The migrated app passes 21 tests. Its demo still reports **0 of 267 events
unattributed**. The recipe consumer preserves the old bridge's 19 integration
tests; the 24 outcome table tests live in saga, with independent reporting and
classification-accessor coverage added there.
