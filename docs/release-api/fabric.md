# Release API review: fabric

> Historical assessment. Round 9 supersedes the bridge-package proposals:
> classification is in llm_wire, run invocation is in fabric, and composition
> uses compiled recipes. See the [Round 9 migration guide](migration-round-9.md). Findings below retain their original context.

Reviewed 2 October 2026 at fabric `db81b79` (includes `c60bc1c`), with `fabric_postgres`,
`the workflow bridge`, `fabric_mcp` and `the classification bridge`. The inputs were
[fabric-design.md](../../fabric-design.md), the [API card](../composition/scan/fabric.md),
[FEEDBACK.md](../composition/FEEDBACK.md) (including "Fix round results"), the app findings SD, RA
and TH, and the [public API guidelines](../../PUBLIC-API-GUIDELINES.md).

A scratch consumer package (path dependencies, public imports only, sibling HEADs) ran three
probes. Probe 1: the "today" program below compiles. Probe 2: another package can call
`@internal` functions; `run.issued("not a valid id because of spaces")` forges a `RunId` that
`run.parse_id` would refuse, and a positional `agent.Limits(8, 4, None, 4, 1, 5000, 200, 5000)`
compiles. Probe 3: stubs of the proposed facade compile with the proposed program, including
`with_answer` turning `Spec(context, String)` into `Spec(context, answer)`. A script over every
`pub` item outside `internal/` produced the surface counts.

## 1. Verdict

Fabric is not release-ready as an API, although its runtime contract (policy gate, durable
approval, `Explain`/`Uncertain`, compare-and-set records, leases, drain) is the strongest in the
ecosystem. Its surface is two runtimes with two vocabularies, 191 public functions (72 of them
`@internal` but callable) and 15 records that callers construct. The biggest problems are a
`String` final answer that every app parses (SD-4, RA-10), run ids minted by `fabric.start`
(RA-3, SD-3, RA-7), no default bound on agent tools, custom models, approvals or graph waits,
string failures where callers branch (`CommandRefused(String)`, `ModelError`, `fabric_mcp`), and
the open durability split with grind and saga (RA-1).

## 2. First ten minutes

The main job is an LLM agent with a typed tool, an approval gate and a final answer.

**Today** (probe 1, compiles at HEAD):

```gleam
import fabric
import fabric/agent
import fabric/llm
import fabric/policy
import fabric/run
import fabric/store
import fabric/tool
// + 9 more (process, option, result, http_gun, http_gun/config, codec, llm_wire x3)

  let assert Ok(client) = http_gun.start(http_config.default())
  let assert Ok(key) = types.api_key(key_text)
  let assert Ok(model_id) = types.model_id("gpt-4.1-mini")
  let model = llm.model(client, config.openai(openai.options(key)), model_id)
  let refund_def = tool.define("refund", "Refund an order.", input_codec, codec.string())
  let refund_tool =
    tool.bind(refund_def, fn(_ctx: Ctx, r) { refund(r) }, fn(e) {
      case e { Declined -> tool.Explain("declined")  GatewayTimeout -> tool.Uncertain("sent, no reply") }
    })
  let gate = fn(_ctx: Ctx, action) {
    use r <- result.try(tool.input(refund_def, action))
    case r {
      Some(r) if r.amount > 100 -> Ok(policy.RequireApproval(run.Requirement("manager", 1)))
      _ -> Ok(policy.Allow)
    }
  }
  let assert Ok(desk) = agent.new("desk", model, [refund_tool], gate) |> agent.build
  let runs = store.in_memory(process.new_name("runs"))
  let assert Ok(Nil) = store.start(runs)
  let assert Ok(handle) = fabric.start(runs, desk, ctx, "Refund order 42")   // id minted inside
  let assert Ok(run.Suspended([pending, ..], _)) = fabric.await(handle, 30_000)
  let assert Ok(_) = fabric.approve(handle, pending.reference, reviewer: Some("alice"), context: ctx)
  case fabric.await(handle, 30_000) {
    Ok(run.Finished(run.Completed(text))) -> parse_resolution(text)   // app parser: 23-46 lines
    other -> Error(other)   // StartError, RecordError and CommandError each need mapping
  }
```

**Proposed** (probe 3 compiles the Fabric part against stubs):

```gleam
import fabric
import fabric/agent
import fabric/policy
import fabric/run
import fabric/store
import fabric/tool
import fabric_llm          // optional adapter package (R12)
// + 7 more: process, result, codec, and llm_wire/http_gun for the model (no gleam/option)

  let model = fabric_llm.model(client, config.openai(openai.options(key)), model_id)
  // tool, binding and gate as today, but: Ok(policy.require_approval("manager"))
  let assert Ok(desk) =
    agent.new("desk", model, [refund_tool], gate)
    |> agent.with_answer(resolution_codec)          // typed, schema-checked answer (R1)
    |> agent.build
  let runs = store.in_memory(process.new_name("runs"))
  let assert Ok(Nil) = store.start(runs)
  let assert Ok(handle) =
    fabric.start(runs, desk, id: run.new_id(), context: ctx, prompt: "Refund order 42")
  let assert Ok(run.Suspended([pending, ..], _)) = fabric.await(handle, 30_000)
  let assert Ok(_) = fabric.approve(handle, pending.reference, reviewer: ctx.user, context: ctx)
  let assert Ok(run.Finished(run.Completed(Resolution(summary:)))) = fabric.await(handle, 30_000)
```

| Measure                                 | Today                                           | Proposed                             |
| --------------------------------------- | ----------------------------------------------- | ------------------------------------ |
| Fabric imports / all imports            | 7 / 16                                          | 7 (6 + adapter) / 14                 |
| Fabric calls                            | 12                                              | 13 (`run.new_id`, `with_answer`)     |
| Error types the caller converts between | 3 (`StartError`, `RecordError`, `CommandError`) | 1 (`fabric.Error` with `error_kind`) |
| App code for a typed answer             | 23 lines (SD-4) to 46 lines (RA-10)             | 0                                    |
| Run id known before the run starts      | no (`fabric.gleam:210`)                         | yes                                  |

The import count cannot fall to one or two: the job has six caller-owned concepts (model, tools,
policy, storage, run data, facade). The gain is in glue: no parser, one error type, and an id the
caller can put into context, job and telemetry.

## 3. Target surface

| Module                                                             | Key types and functions after the proposals                                                                                                                                                                                                                                                                                                           |
| ------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fabric`                                                           | `Run(context, answer)`, `Error`, `ErrorKind`; `start`, `open`, `recover`, `id`, `child`, `await`, `snapshot` (absorbs `pending`), `approve`, `reject`, `reconcile`, `cancel`, `cancel_when_down`, `cancel_stored`, `reconcile_stored`, `settle_stored`, `error_kind`, `describe_error` (17)                                                           |
| `fabric/agent`                                                     | opaque `Spec(context, answer)`, `Agent(context, answer)`, `ConfigError`; `new`, `with_version`, `with_system_prompt`, `with_answer`, `with_sub_agent`, `with_sub_agents`, `with_family_budget`, `build`, `describe_config_error`, plus 10 limit setters (19)                                                                                          |
| `fabric/tool`                                                      | `Definition`, `Tool`, `Failure(Explain, Uncertain)`, `Settlement`; `define`, `name`, `description`, `input_codec`, `output_codec`, `bind`, `bind_settling`, `settle`, `action`, `with_replay`, `with_timeout`, `input`, `reconciliation` (13)                                                                                                         |
| `fabric/policy`                                                    | `Policy`, `Action(run, step, name, arguments_json, target)`, `Step`, `Target`, `Decision`; `always_allow`, `require_approval` (2)                                                                                                                                                                                                                     |
| `fabric/model`                                                     | `Model`, `Request` (read by label; gains `run`, `turn`, `answer`), `Reply`, `Message`, `AssistantTurn`, `Usage`, opaque `ToolCall` and `ModelError`; `new`, `tool_call`, `with_provider_data`, `error`, `with_retry_after`, `error_kind`, `is_retryable`, `describe_error` (8)                                                                        |
| `fabric/run`                                                       | `RunId`, `Status(a)`, `Outcome(a)`, `Snapshot(a)`, refs, `Deadline(After, Never)`; `new_id`, `parse_id`, `id_to_string`, `outcome_kind`, `describe_outcome` (5)                                                                                                                                                                                       |
| `fabric/budget`                                                    | opaque `Limits`, `Denial`, `Usage`; `limits`, `with_children`, `with_depth` (3)                                                                                                                                                                                                                                                                       |
| `fabric/store`                                                     | `Store`, `StoreError`, `Readiness`; `new`, `in_memory`, `directory`, `leased`, `with_drain`, `with_record_version`, `with_backend_timeout`, `supervised`, `start`, `readiness`, `now`, `describe_error` (12)                                                                                                                                          |
| `fabric/store/discovery`, `retention`, `statistics`, `conformance` | For backend authors: three projections moved from the top level, plus `checks` and `leased_memory` moved from `testing` (8)                                                                                                                                                                                                                           |
| `fabric/sweeper`                                                   | `Root`, `SweeperError`; `agent`, `graph`, `supervised`, `describe_error` (4). Replaces `fabric.recovery`, `fabric.sweeper` and `graph.recovery`.                                                                                                                                                                                                      |
| `fabric/telemetry`, `fabric/testing`                               | `telemetry`: renamed from `observation`, 19 descriptors plus graph events and `correlation` (R15). `testing`: `call`, `scripted_model` (2)                                                                                                                                                                                                            |
| `fabric/graph`                                                     | `Runtime`, `Handle`, `Status(a)`, `Error`; `new`, three timeout setters, `with_family_budget`, `start`, `open`, `id`, `snapshot`, `await`, `recover`, `approve`, `reject`, `reconcile`, `cancel`, `deliver`, `deliver_json`, `poll_job`, `child`, `branch`, `as_subgraph`, `status_kind`, `error_kind`, `describe_error` (24). Absorbs `graph/child`. |
| `graph/definition`, `operation`, `agent`, `signal`, `job`, `fork`  | 7, 9, 3, 2, 2 and 3 functions. `definition.Spec` and `graph/agent.Definition` become constructors. `both` and `map` move to `fork`.                                                                                                                                                                                                                   |
| Integrations                                                       | `fabric_postgres` (`config`, one `Error`); `the workflow bridge` (`tool` with `input:`); `the Relay bridge` replaces `fabric_mcp`; `the classification bridge` on `http_gun`; new `fabric_llm` (`model`, `decision`, `receipt_codec`)                                                                                                                 |

| Count (core, graph included)      | Before                               | After                                                                                                      |
| --------------------------------- | ------------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| Public modules                    | 23 (agent 14, graph 9)               | 22 (agent 15, graph 7); 15 if the graph is split out (Q1)                                                  |
| Public functions                  | 191 (119 documented, 72 `@internal`) | ≈162, none `@internal` (agent ≈112, graph ≈50)                                                             |
| Public records / with 4+ fields   | 74 / 28                              | ≈60 / ≈20                                                                                                  |
| Records callers construct         | 15                                   | 7: ports `LeasedBackend`, `Stored`, `Current`; `Usage`, `AssistantTurn`, `ProviderData`; `run.Requirement` |
| Opaque types                      | 19                                   | ≈30                                                                                                        |
| Integrations: modules / functions | 8 / 39 (3 `@internal`)               | 7 / ≈25 (`fabric_mcp`'s 11 replaced by ≈4)                                                                 |

Documented functions rise from 119 to about 162: setters replace constructed records,
`kind`/`describe` helpers replace string parsing, and new capabilities arrive (`with_answer`,
`with_replay`, timeouts, `new_id`, `cancel_when_down`, `scripted_model`). What a caller can misuse
shrinks: 72 hidden but callable functions, 8 constructed records and 3 duplicate entry points go.

## 4. Proposals

The proposals are ranked by user impact. "Breaks" means callers must change code.

### FABRIC-R1. Typed final answers (SD-4, RA-10, card concern 5)

- **Problem.** `run.Completed(text: String)` (`run.gleam:143`) is the only final answer.
  support_desk puts the schema in the prompt and parses the text back (23 lines); research_agent
  parses a `TITLE:` convention (46 lines). The provider never receives an output format, although
  llm_wire has `prepare_structured`. Sub-agents and graph agents parse strings too: the `output:`
  parser of `with_sub_agent` (`agent.gleam:201`) and `graph/agent.Definition.answer`
  (`graph/agent.gleam:29-38`).

- **Change.** The answer type flows from the agent through runs and delegations:

  ```gleam
  pub fn new(name, model, tools, policy) -> Spec(context, String)
  pub fn with_answer(spec: Spec(context, String), answer: Codec(answer)) -> Spec(context, answer)
  pub type Outcome(answer) { Completed(answer) ... AnswerInvalid(raw: String, reason: String) }
  pub fn with_sub_agent(spec, definition: tool.Definition(input, output),
    to child: Agent(context, output), prompt prompt: fn(input) -> String) -> Spec(context, answer)
  ```

  `model.Request.answer` carries the schema so the adapter requests structured output. Fabric
  validates the answer before it commits `Completed`. Store-only commands return
  `Snapshot(String)`.

- **Breaks:** yes; `Run`, `Status`, `Outcome` and `Snapshot` gain a parameter. **Effort:** L.

### FABRIC-R2. Caller-supplied run ids; one start (RA-3, RA-1, SD-3, TH-7)

- **Problem.** The agent runtime mints `"run-" <> random_id()` (`fabric.gleam:210`), while
  `graph.start(runtime, id, initial)` takes the caller's id (`graph.gleam:818`). A job cannot
  start an agent run idempotently, so research_agent keeps a job-to-run join table (about 115
  lines), and tools cannot tag calls with a run whose id does not exist yet when the context is
  built (`desk.gleam:40-50`). `start_with_budget` repeats `start` in both runtimes
  (`fabric.gleam:178`, `graph.gleam:829`) and reports bad limits as a `StartRefused` string
  (`fabric.gleam:187`).

- **Change.**

  ```gleam
  pub fn start(runs: Store, agent: Agent(context, answer), id id: RunId,
    context context: context, prompt prompt: String) -> Result(Run(context, answer), Error)
  // Error(AlreadyStarted(id)) when the id is taken; the caller then opens the run.
  pub fn new_id() -> RunId                                          // fabric/run
  pub fn with_family_budget(spec, budget.Limits) -> Spec(c, a)      // checked by build; graph alike
  ```

  The labels keep `context` and `prompt` apart when the context is a `String`.

- **Breaks:** yes. **Effort:** S.

### FABRIC-R3. Bounded by default: tools, models, approvals, waits, result size

- **Problem.** The agent runner waits on `selector_receive_forever` (`internal/runner.gleam:729`):
  nothing bounds a tool body or a `model.new` function, and only llm_wire's 60 s deadline bounds
  `fabric/llm`. Graph operations get 60 s (`graph.gleam:286`), so the runtimes disagree. Approvals
  never expire, though the design requires it (`fabric-design.md:38`). Graph signal, job, child
  and fork waits are unbounded without `with_deadline` (`operation.gleam:238`). Tool output is
  stored and resent every turn with no size limit.
- **Change.** Adopt the section 5 defaults. An unbounded value must be stated explicitly:

  ```gleam
  pub type Deadline { After(milliseconds: Int)  Never }               // fabric/run
  agent.with_tool_timeout(spec, After(60_000))      // expiry: Uncertain (or replay, R9)
  agent.with_model_timeout(spec, After(120_000))    // expiry: retryable ModelError(TimedOut)
  agent.with_approval_expiry(spec, After(7 * day))  // expiry: a rejection the model sees
  agent.with_max_result_bytes(spec, 1_048_576)      // over: HostFailure(ResultTooLarge)
  tool.with_timeout(tool, Deadline)                 // per-tool override
  operation.with_deadline(op, Never)                // graph waits default to After(7 * day)
  ```

- **Breaks:** behavior only, for long tools and waits. **Effort:** M.

### FABRIC-R4. Typed failures; one error per facade (card concern 3, RA-11)

- **Problem.** `graph.gleam` builds `CommandRefused(String)` at 33 sites and calls
  `string.inspect` 36 times, so "approval is not current" and "child runtime does not use the
  parent store" are indistinguishable. `ModelError(reason: String, retryable: Bool)`
  (`model.gleam:77`) inspects llm_wire's typed failure into text (`llm.gleam:172-185`);
  research_agent got `ModelError("HTTP status 404 (RequestMayHaveReachedProvider)", False)`. The
  agent facade has three error types, and the README's `review` converts between them three times.
- **Change.**

  ```gleam
  // fabric: one Error (start, read and command variants) with a stable classification
  pub type ErrorKind { NotFound  Refused  Retry  Unavailable  Incompatible }
  pub fn error_kind(error: Error) -> ErrorKind     pub fn describe_error(error: Error) -> String
  // graph: typed refusals, named like the agent's
  WrongRun | NotCurrent | AlreadyAnswered | SignalConflict | ChildMismatch(ChildProblem)
    | CallbackFailed(callback: Callback, reason: CallbackFailure)   // TimedOut | Crashed(String)
  // model: opaque ModelError built by error(kind, detail) |> with_retry_after(ms)
  pub type ModelFailure { Unreachable TimedOut RateLimited Overloaded Rejected(status: Int)
    InvalidRequest InvalidReply Crashed Other }
  ```

  Add `error_kind`, `is_retryable` and `describe_error` for `ModelError`. Document which unions may
  grow: `Error`, `Outcome`, `HostFailure`, `ActionState` and `graph.Status`.

- **Breaks:** yes. **Effort:** M.

### FABRIC-R5. One vocabulary for the agent and graph runtimes (card concern 1)

- **Problem.** An application that uses both runtimes writes two policies and two failure
  classifiers, and learns two command shapes:

  | Concept            | Agent                                                  | Graph                                                                 | Proposed for both                                                                                             |
  | ------------------ | ------------------------------------------------------ | --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
  | Definite or maybe  | `tool.Explain`/`Uncertain` (`tool.gleam:64`)           | `DefiniteFailure`/`UncertainEffect` (`operation.gleam:30`)            | `tool.Failure`; delete `operation.Failure`                                                                    |
  | Policy             | `policy.Action` (`policy.gleam:23`)                    | `graph.Action`, `graph.Policy` (`graph.gleam:39-51`)                  | one `policy.Action` with `step: ModelCall(..) \| Activation(..)` and `target: .. \| RunOperation(node, kind)` |
  | Approve            | `(run, ref, reviewer:, context:)` (`fabric.gleam:546`) | `(handle, approval)`: no reviewer, thunk context (`graph.gleam:1034`) | `(handle, ref, reviewer:, context:)`                                                                          |
  | Approval reference | `run.ApprovalRef`                                      | `graph.Approval` (`graph.gleam:94`)                                   | `ApprovalRef`                                                                                                 |
  | Cancel returns     | `Status` (`fabric.gleam:682`)                          | `Nil` (`graph.gleam:1021`)                                            | the status after the commit                                                                                   |
  | Reconcile          | `(run, ActionRef, content)`                            | `(handle, Reconciliation, output_json)`                               | `(handle, ref, content)`                                                                                      |
  | Open, read         | `open`, `snapshot`                                     | `attach`, `read`                                                      | `open`, `snapshot`                                                                                            |
  | Unattended context | `fn(RunId) -> context` (sweeper only)                  | `fn() -> context` (`graph.gleam:214`)                                 | `fn(RunId) -> context`                                                                                        |
  | Replay             | none (RA-4)                                            | `operation.with_replay`                                               | `with_replay` on both (R9)                                                                                    |

- **Breaks:** yes, mostly graph callers. **Effort:** L.

### FABRIC-R6. Hide machinery that is public today (probe 2)

- **Problem.** Public modules hold 72 `@internal` functions that any package can call: store 19,
  operation 15, definition 14, tool 9, job 6, child 3, signal 2, and one each in agent, graph,
  model and run. `run.issued` forges ids (`run.gleam:41`); `agent.admitted` exposes a 14-field
  record. Backend-only modules (`discovery`, `retention`, `statistics`, the checks in `testing`)
  sit at the top level.
- **Change.** Move every `@internal` item into `fabric/internal/*` behind thin facades, move the
  backend modules under `fabric/store/`, and merge `graph/child`'s read types into `graph`.
- **Breaks:** only callers of `@internal` items. **Effort:** M (mechanical).

### FABRIC-R7. Constructed configuration becomes opaque

- **Problem.** These values will grow, and positional construction compiles (probe 2):
  `agent.Limits` (8 fields, `agent.gleam:44`; R3 adds 4), `graph.with_timeouts` (three unlabeled
  `Int`s, `graph.gleam:289`), `definition.Spec` (`definition.gleam:59`), `graph/agent.Definition`
  (`graph/agent.gleam:29`), `budget.Limits(work, children, depth)` (`budget.gleam:4`), the
  3-tuple graph LLM request builder `#(http_gun.Client, config.Config, types.Request)`
  (`graph/llm.gleam:43`), `model.ToolCall`, `fabric_mcp/client.Options` and
  `the former classifier request bounds`.

- **Change.**

  ```gleam
  agent.new(..) |> agent.with_max_turns(6) |> agent.with_token_budget(20_000)   // no Limits record
  graph.new(..) |> graph.with_operation_timeout(60_000) |> graph.with_command_timeout(1000)
  definition.new(identity, entry:, nodes:, state:, answer:) |> definition.with_max_activations(100)
  graph_agent.new(identity, agent, input:, prompt:)       // output codec from with_answer (R1)
  budget.limits(work: 100) |> budget.with_children(10) |> budget.with_depth(3)
  fabric_llm.decision(identity, input:, output:, name:, call: fn(context, input) -> fabric_llm.Call)
  ```

  Both `build` functions still report every problem at once. `ConfigError`'s 19 per-field variants
  collapse into `InvalidLimit(limit: Limit, value: Int, minimum: Int, maximum: Int)`.

- **Breaks:** yes. **Effort:** M.

### FABRIC-R8. Run id and turn in model calls (SD-3, RA-7, TH-7)

- **Problem.** `model.Request(system:, messages:, tools:)` (`model.gleam:52-58`) has no run or
  turn, and `llm.model` binds one client per agent (`llm.gleam:42-50`). 100 llm_wire events in
  support_desk and 15 in research_agent are unattributed; tool_hub rebuilds the agent for every
  question (`assistant.gleam:100-120`).
- **Change.** `Request(run: RunId, turn: Int, system:, messages:, tools:, answer:)`, read by
  label. `fabric_llm.model` tags each turn with `http_gun.with_correlation` (needs `id_from`,
  EXT-4).
- **Breaks:** only positional matches. **Effort:** S.

### FABRIC-R9. Tool parity: replay, timeout, accessors, typed reconciliation

- **Problem.** After a crash every started tool becomes uncertain, with no opt-in replay (RA-4,
  `fabric.gleam:52-55`); research_agent spends 77 lines reconciling a read-only fetch. Definition
  accessors are `@internal` (`tool.gleam:379-418`), so a fabric tool cannot be served over Relay
  (TH-5, TH-8). A settling handler cannot learn its action (SD-3), and reconciliation content is
  hand-written JSON (SD-5, `fabric.gleam:779`).
- **Change.**

  ```gleam
  pub fn with_replay(tool: Tool(c), max_attempts: Int) -> Tool(c)   // checked by agent.build
  pub fn name(definition: Definition(i, o)) -> String   // and description, input_codec, output_codec
  pub fn action(settlement: Settlement(o)) -> run.ActionRef
  pub fn reconciliation(d: Definition(i, o), result: Result(o, Failure)) -> Result(String, codec.EncodeError)
  ```

- **Breaks:** no. **Effort:** S.

### FABRIC-R10. Relay composition through compiled recipes (TH-5)

**Resolved in round 9.** Fabric owns the protocol-neutral `fabric/invoke`
request lifecycle. Relay exposes definitions, output evidence and reply
metadata. Consumer-owned recipes cover typed calls (40 lines), discovery
(50), graph operations (28), serving (41), and reading a run id (12).
Each is compiled verbatim and checked against README and module docs. All
23 former bridge tests remain, and tool_hub uses the same recipes.

### FABRIC-R11. Saga outcome and ownership ports (SD-2, SD-5)

**Resolved in round 9.** `saga/outcome` classifies effects and held evidence;
`saga/reporting.run_owned` owns cancellation and reporting after its caller
stops. The 47-line `saga_tool` recipe forwards `call.correlation`, binds a
settling tool and maps failures to `Explain` or `Uncertain`. Saga steps read
`saga.correlation_of(key)`. Fabric core has no saga dependency. The old 43
tests are preserved in saga (24) and the consumer (19).

### FABRIC-R12. Provider-neutral classification and one HTTP client

**Resolved in round 9.** Provider adapters remain in fabric core, as the
owner decided on 1 October. `llm_wire/classify` adds a provider-neutral
question/request/outcome family; TypeSafe System One is its first wire.
`fabric/graph/classify.decision` consumes it alongside `fabric/graph/llm`.
Credentials are reveal closures, failures stay typed, and http_gun supplies
transport, redaction and recording. A second custom wire is compiled in an
external consumer. Confidence means concentration evidence, not correctness.
Old receipt and stored graph fixtures remain readable. Decision and writing
consumers migrated. No new optional provider adapter package is introduced.

### FABRIC-R13. Lifecycle: sweeper, owner, stop

- **Problem.** `fabric.sweeper(store, recoveries, every:)` (`fabric.gleam:936`) returns a child
  specification that must follow the store in a rest-for-one supervisor; only its documentation
  says so. A run outlives its starter, so a Relay disconnect leaves the run working (TH-3; 11
  lines of app glue). `store.start` has no `stop`.
- **Change.** `sweeper.supervised(store, [sweeper.agent(..), sweeper.graph(..)], every:)`, or
  better, `store.supervised` takes the sweeper so the order cannot be wrong. Add
  `fabric.cancel_when_down(run, owner: Pid)` and `store.stop`.
- **Breaks:** renames. **Effort:** S.

### FABRIC-R14. Naming collisions

- **Problem.** `observation.ActionRef(run: String, ..)` collides with `run.ActionRef(run: RunId,
id)` (`observation.gleam:127`, `run.gleam:53`). `graph.Approval` is a pending reference but
  `run.Approval` an answered record (`graph.gleam:94`, `run.gleam:110`). `fabric.Recovery` is a
  sweeper registration but `operation.Recovery` a replay contract (`fabric.gleam:904`,
  `operation.gleam:15`). `Route.Canceled` (`graph.gleam:168`) sits beside `Cancelled` everywhere
  else. There are four `Failure`, `Usage` and `Snapshot` types each and three `child` functions;
  `within` means a wait, a settlement window and a due time; `run.Identity` names a definition.
- **Change.** Rename to `telemetry.Action`, `graph.ApprovalRef`, `sweeper.Root`, `Cancelled`,
  `settle_within` and `run.DefinitionId`. Delete `operation.Failure` (R5) and
  `graph.approval_requirement`, which only reads a public field (`graph.gleam:811`).
- **Breaks:** renames. **Effort:** S.

### FABRIC-R15. Telemetry: name, correlation, graph events

- **Problem.** The module is `fabric/observation`, not `fabric/telemetry`. Metadata has no
  family-wide key, so a sub-agent's events do not join its root. The graph runtime emits nothing:
  no module under `internal/graph/` imports `observe`.
- **Change.** Rename the module, add `correlation` (the root run id) to all metadata, and add
  graph descriptors (start, activation, wait, approval, cancel, stop).
- **Breaks:** an import path. **Effort:** M.

### FABRIC-R16. Docs, dependencies, design

- **Problem.** The README opens with 55 lines of status before its test-compiled usage example.
  No package has a defaults table or a CHANGELOG, and `the workflow bridge` has no README.
  `README.md:483` says the suite skips PostgreSQL, but `check.py full` runs it. `http_gun`,
  `json_blueprint`, `llm_wire` and `sinal` are path dependencies. fabric-design.md §1-2 assigns
  durable graphs to Saga and excludes multi-node coordination; Fabric now does both.
- **Change.** Common path first in the README, the section 5 table, CHANGELOGs, Hex ranges, and
  the Q1 decision recorded in the design.
- **Breaks:** no. **Effort:** S.

## 5. Defaults table

| Operation                                   | Current default                                                                                                                                                                                                                   | Proposed default                                            |
| ------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| Model attempts per run                      | 8 (`max_turns`), retries included                                                                                                                                                                                                 | 8                                                           |
| Model call through `fabric/llm`             | llm_wire: 60 s overall, 15 s idle, 5 s read                                                                                                                                                                                       | same, plus Fabric's `model_timeout`                         |
| Model call through any `model.new` function | **none (infinite)**                                                                                                                                                                                                               | `After(120_000)`; a retryable `TimedOut` that uses a turn   |
| Model retry backoff                         | 200 ms doubling to 12.8 s; each retry uses a turn                                                                                                                                                                                 | same; `retry_after` honored                                 |
| Token budget                                | none; bounded only by turns × provider output cap                                                                                                                                                                                 | opt-in, documented (see section 6)                          |
| Agent tool body                             | **none (infinite)**                                                                                                                                                                                                               | `After(60_000)`, as graph operations; `Uncertain` on expiry |
| Tool result size                            | **none**; stored and resent every turn                                                                                                                                                                                            | 1 MiB; over it, `HostFailure(ResultTooLarge)`               |
| Command handoff to a live runner            | 5 s (agent), 1 s (graph)                                                                                                                                                                                                          | 5 s for both                                                |
| Approval wait, agent and graph              | **none (infinite)**                                                                                                                                                                                                               | `After(7 days)`; expiry rejects, and the model sees it      |
| Graph signal, job, child and fork waits     | **none** unless `with_deadline`                                                                                                                                                                                                   | `After(7 days)`; `Never` must be explicit                   |
| Graph operation body; callbacks             | 60 s; 1 s                                                                                                                                                                                                                         | 60 s; 1 s                                                   |
| Graph activations                           | required in `Spec`                                                                                                                                                                                                                | 100 (`with_max_activations`)                                |
| Settlement window (`bind_settling`)         | required                                                                                                                                                                                                                          | same, renamed `settle_within`                               |
| Store backend call                          | 5 s; setter is `@internal`                                                                                                                                                                                                        | 5 s; public `with_backend_timeout`                          |
| Store request mailbox                       | unbounded actor mailbox                                                                                                                                                                                                           | documented; callers are bounded by their own timeouts       |
| Sweeper                                     | `every` required; 50 + 50 per batch; context 5 s; per root 30 s; handler 1 s                                                                                                                                                      | same, listed in the README                                  |
| `fabric_mcp` request                        | 10 s; 1 MiB frames; 64 notifications; 16 discovery pages                                                                                                                                                                          | Relay client defaults (R10)                                 |
| `the classification bridge` request         | 20 s; 1 MiB request and response; 16 KiB headers                                                                                                                                                                                  | same, through `http_gun`                                    |
| Security                                    | policy required; policy failure and timeout fail closed; reviewer not authenticated; `RunId` forgeable (probe 2)                                                                                                                  | same; `reviewer` required; forging closed (R6)              |
| Unchanged and sound                         | 4 concurrent tool bodies; policy decision 5 s, fails closed; sub-agents 4 children, depth 1 (caps 999, 16); family budget opt-in; `await` takes a required `within`; drain 25 s; `fabric_postgres` lease 30 s, renewed every 10 s | same                                                        |

## 6. Convention feedback

1. **Opaque config.** This fits growing settings: `Limits` gains four fields in R3. It conflicts
   with the guidelines' "public records for straightforward settings"; proposed rule: a public
   record only for closed sets such as `run.Requirement`. Let `build` return `List(ConfigError)`,
   since reporting every problem at once beats one typed error.
2. **Constructed data is opaque.** Exempt ports: backend authors implement `LeasedBackend`,
   `Stored` and `Current`, and a new operation breaks them by necessity. Require a documented
   contract version instead, as `discovery.version` does.
3. **Growing unions.** Fabric has 67. Require `kind` only on unions callers branch on (`Error`,
   `Outcome`, `graph.Status`); displayed ones (`ActionState`) need only `describe`.
4. **Bounded by default.** Two dimensions cannot default: a token budget would stop every custom
   model that reports no usage (`BudgetUnverifiable`), and a wall-clock run deadline would cut
   approvals that legitimately wait days. Say instead "every step and every wait is bounded"; run
   time is then bounded by turns × (model + tool timeouts) + approvals × expiry.
5. **Lifecycle.** `fabric.start` starts a run, not a process: the domain verb collides with the
   lifecycle name. A handle may be a name-based value created before `start` (`Store`), with
   `start` returning `Result(Nil, _)`; the convention should allow both.
6. **Errors.** "One error type per boundary" yields three facade types that callers keep
   converting. Prefer one per facade module.
7. **Glossary.** Fabric adopts it: `observation` → `telemetry`, `settings` → `config`
   (`fabric_postgres`), `sweeper` → `sweeper.supervised`.
8. **JSON currency.** Allow raw JSON text where byte-exactness is the contract (duplicate signals
   and replay compare bytes, `graph.gleam:1079`). Tool and graph schemas stay on Blueprint.
9. **One ordinary path.** Fabric breaks it with `start_with_budget` (twice) and `pending`;
   `bind_settling`, `deliver_json` and `*_stored` add capabilities and fit.
10. **One or two imports** is unrealistic for a runtime with six caller-owned concepts. Measure
    glue lines and error conversions instead.

## 7. Open questions (owner decisions)

1. **Durability ownership (RA-1, theme 5).** In research_agent one request runs under three
   leases, recoveries, retry policies and cancel commands. Options (R2, R4 and R9 hold under all):
   - **A. Fabric owns conversation and graph state** (today's code). Record it in the design and
     ship `fabric_grind`: a job derives the run id (R2) and cancels through `JobContext` (RA-5);
     Saga keeps compensation. Cost: two durable graph runtimes in the ecosystem.
   - **B. Fabric owns the agent loop only.** The graph runtime moves to a separately versioned
     `fabric_graph`, later onto Saga's durable runner, as the design's table says; the core
     shrinks to 15 modules and about 112 functions. Cost: graph users migrate, and Saga must
     restate subgraphs, forks, signals and job polling.
   - **C. A shared durability substrate** (store, lease, sweeper, ids) for grind, saga and
     fabric. Cost: a cross-package design, the largest change.

2. **Is the graph runtime in fabric 1.0?** Shipping it as 0.x or as a separate package would let
   the agent API stabilize first. The answer follows from Q1.
3. **Optional adapter (R12).** Moving the adapter out decouples the core from llm_wire, at the
   cost of one more dependency for newcomers.
4. **Wait expiry.** Is 7 days the right default? Does an expired approval reject the action or end
   the run? Is a tool timeout `Uncertain`, or `Explain` for tools declared replayable?
5. **Reviewer.** The design asks for authenticated answers. Should `reviewer` be a required
   `String`, or a typed caller identity?
6. **Relay ↔ fabric adapter.** Does it live in `the Relay bridge` or on Relay's side? It also depends
   on Relay adding submission evidence (TH-4).
