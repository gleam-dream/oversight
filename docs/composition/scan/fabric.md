# fabric — API card

> Historical assessment. Round 9 supersedes the bridge-package proposals:
> classification is in llm_wire, run invocation is in fabric, and composition
> uses compiled recipes. See the [Round 9 migration guide](../../release-api/migration-round-9.md). Findings below retain their original context.

Bounded, typed LLM agent and agentic-graph runtime. Repo: `/code/gleam-dream/fabric`.
Design: [fabric-design.md](../../../fabric-design.md).

## Health

Gate: `nix develop --command python3 scripts/check.py full` (formatting, per-package
format/build/test for 13 Gleam packages, a throwaway PostgreSQL 16 cluster, a local
jobs service, Python protocol suites; credentials stripped, so there are no live calls).

| Run                                                                 | Result                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Real checkout, siblings at HEAD (llm_wire `1c0ad61`)                | **FAIL at `core-build`**. `nix flake check`, gate self-tests and `gleam format --check` pass. 4 compile errors: `session.run`/`run_structured` now take an `http_gun.Client` (`src/fabric/llm.gleam:58`, `src/fabric/graph/llm.gleam:73`). Later checks did not run.                                                                                                                                                                                                                                                                                                 |
| Scratch clone, llm_wire pinned to `bbde1d9`, other siblings at HEAD | **PASS, all checks.** The scripted run stopped at `consumers-jobs-tests` on a transient Hex API rate limit ("rate limit … exceeded") while resolving. Rerunning that check and the rest by hand passed. Gleam: core 650, the workflow bridge 35, fabric_postgres 64 (throwaway PG16, stopped), fabric_mcp 22, the classification bridge 18, app 15, graph 5, decision 2, jobs 19, writing 8, workflow_composition 29, graph_authoring 12, its consumer 6. That is **885 passed, 0 failed**. Python: 24 tests OK. Format and `--warnings-as-errors` builds are clean. |

- Git head: `ad20963 feat: add durable writing workflow and live reviewer comparison`. Worktree clean.
  The gate's `gleam build` rewrote `manifest.toml` to add `http_gun`. I restored it, so the repo is unchanged.
- The tested-revision table in `docs/PLAN.md:1705-1723` pins llm_wire `cc79a69` plus uncommitted
  changes. Those changes are now committed as `bbde1d9`, and llm_wire has since moved to `1c0ad61`
  ("migrate LLM Wire to shared HTTP Gun clients"). Fabric's path dependency gives it no protection from that move.
- No `TODO`/`FIXME` in `src/`, `integrations/*/src` or `consumers/*/src`.
- Open items (`docs/REMAINING.md`): S8 Grind integration, which is blocked on 4 missing public Grind APIs;
  Hex publication and hosted CI, both deferred; and the retained backlog listed below.
- README drift: it says "The root suite and CI do not run PostgreSQL tests", but `check.py full` does.

## Purpose and scope delivered vs design

Fabric runs typed agents: a `tool.Definition` owns the name and json_blueprint codecs, one
`Policy` gates every effect, and runs pause durably for approval, survive restart, and stay
cancellable. Uncertain effects are never retried and wait for reconciliation. Fabric owns the
transcript and calls models through its own `fabric/model` port. On top of the agent loop sits
a second runtime, `fabric/graph`: typed nodes, conditional routes, bounded cycles, signals,
external jobs, deadlines, forks, managed subgraphs and managed agent children. Both runtimes share
a supervised `Store`, which can be in-memory, a directory, an application backend, or a leased
multi-node backend in which `fabric_postgres` supplies leases, a sweeper, retention and statistics.
**The implementation has outgrown the design doc.** fabric-design.md §1–2 assign durable graph
execution to Saga and Grind. It says "Fabric does not retain a second `fabric/dag`" and that
"multi-node distributed coordination remains excluded". AGENTS.md now says "Fabric owns conditional
agentic graphs", and the leased store coordinates several nodes. The design doc needs a recorded
decision. Missing vs design and backlog:

- Streaming agent execution (llm_wire progress mapped to agent progress, with stream close on cancel).
- Structured final agent output: `run.Completed(text: String)`, and sub-agents parse strings.
- Approval expiry, edit/respond answers, family-wide token accounting, agent elapsed-time
  budgets and per-tool deadlines, context compaction.
- Historical review forks, and an agent suspending inside Saga. The Saga adapter only
  runs a workflow as a tool.
- Grind integration (S8). Direct child recovery with a parent link. A narrower child context type.

## Public modules

| Group         | Modules                                                                                                                                     | Responsibility                                                                                                                                                                    |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Agent facade  | `fabric`                                                                                                                                    | `start`/`start_with_budget`/`open`/`recover`/`child`, `await`/`snapshot`/`pending`, `approve`/`reject`/`cancel`/`reconcile`, `*_stored` terminal commands, `recovery` + `sweeper` |
| Agent config  | `fabric/agent`, `fabric/tool`, `fabric/policy`, `fabric/budget`                                                                             | `Spec`→`build`→`Agent`; typed tool definitions/binding/settlement; policy gate; family budget values                                                                              |
| Model port    | `fabric/model`, `fabric/llm`                                                                                                                | Provider-neutral `Model` (`model.new(fn(Request) -> Result(Reply, ModelError))`); llm_wire adapter                                                                                |
| Run data      | `fabric/run`, `fabric/observation`                                                                                                          | `RunId`, `Status`, `Outcome`, approvals, snapshots; Sinal event descriptors                                                                                                       |
| Storage       | `fabric/store`, `fabric/discovery`, `fabric/retention`, `fabric/statistics`, `fabric/testing`                                               | Store port and built-ins, leases, readiness; storage projections for backends; scripted calls + leased-backend conformance checks                                                 |
| Graph         | `fabric/graph`, `graph/definition`, `graph/operation`, `graph/agent`, `graph/llm`, `graph/signal`, `graph/job`, `graph/child`, `graph/fork` | Graph runtime/commands; typed node authoring; operation kinds; agent-as-node; one structured LLM decision; durable signals; external jobs; child/fork observables                 |
| Optional pkgs | `integrations/fabric_postgres`, `the workflow bridge`, `fabric_mcp`, `the classification bridge`                                            | pog leased backend + migrate/prune/stats; Saga workflow as a tool; MCP stdio tools as graph operations; TypeSafe classifier operations                                            |

## Common path

This is the tested-revision API. At llm_wire HEAD, `llm.model` does not compile (see Health).

```gleam
let assert Ok(key) = types.api_key(openai_key)          // llm_wire/types
let assert Ok(model_id) = types.model_id("gpt-4.1-mini")
let model = llm.model(config.openai(openai.options(key)), model_id)  // fabric/llm

let refund_def = tool.define("refund", "Refund an order.", refund_in, receipt_out)
let refund =
  tool.bind(refund_def, fn(ctx: Ctx, r: Refund) { payments.refund(ctx, r) }, fn(e) {
    case e {
      Declined -> tool.Explain("card declined")       // model sees it, run continues
      GatewayTimeout -> tool.Uncertain("sent, no reply") // run suspends for reconcile
    }
  })
let gate = fn(_ctx: Ctx, action: policy.Action) {
  use r <- result.try(tool.input(refund_def, action))  // typed input, None for other tools
  case r {
    Some(r) if r.amount > 100 -> Ok(policy.RequireApproval(run.Requirement("manager", 1)))
    _ -> Ok(policy.Allow)
  }
}
let runs = store.in_memory(process.new_name("runs"))   // store.supervised(runs) in an app
let assert Ok(Nil) = store.start(runs)
let assert Ok(desk) = agent.new("support", model, [refund], gate) |> agent.build
let assert Ok(handle) = fabric.start(runs, desk, ctx, "Refund order 42")
case fabric.await(handle, 30_000) {
  Ok(run.Suspended([pending, ..], _)) ->
    fabric.approve(handle, pending.reference, reviewer: Some("alice"), context: ctx)
  other -> other |> result.map_error(fabric.Unreadable) // Finished(Completed(text)) etc.
}
```

## Configuration and advanced paths

- **Limits**: public record `agent.Limits(..agent.default_limits(), max_turns:, token_budget:, ...)`.
  `agent.build` validates it and returns every `ConfigError` at once. `agent.with_version` and `with_system_prompt` are also available.
  The family-wide budget is set at `fabric.start_with_budget(.., budget.Limits(work:, children:, depth:))`.
- **Policy/approval**: `Policy(context) = fn(context, Action) -> Result(Decision, String)`, where `Decision` is
  `Allow | Deny(reason) | RequireApproval(Requirement)`. `approve` re-runs the policy with a fresh context
  and may return `RequirementChanged`. `policy.always_allow()` is the only implicit allow, and it must be chosen explicitly.
- **Uncertain effects**: `tool.bind_settling(.., within:)` plus `tool.settle(settlement, result, summary:)`
  handle late outcomes. `fabric.reconcile` resolves an effect on a live run. `reconcile_stored`/`settle_stored`
  resolve one after cancellation and need no deployed agent.
- **Persistence/continuation**: `store.in_memory`, `store.directory` (single host, not power-loss safe), and
  `store.new(name, get:, insert:, compare_and_set:)` for an app backend. `store.leased(name, node:, lease:, backend:)`
  supports multiple nodes. `store.with_drain` and `store.with_record_version` (writer v2–7 for rolling upgrades) configure it.
  A run continues only under the same agent name and version (`IncompatibleAgent`).
- **Automatic recovery**: `fabric.sweeper(store, [fabric.recovery(agent, ctx_for_run), graph.recovery(id, build)], every:)`
  returns a `ChildSpecification`, which is added after the store in a rest-for-one supervisor. It works on leased stores only.
- **Postgres**: `fabric_postgres.settings(pog_conn, node:) |> with_lease |> with_schema`, `migrate`, `store`,
  `backend` (which `testing.leased_backend_checks` can check), `prune(ended_for:, limit:)`, `stats` (a new
  `statistics.Snapshot` of run counts, intervention counts, record ages, per-node leases and the oldest overdue lease), and `refresh_statistics`/`_retention`/`_discovery`.
- **Sub-agents**: `agent.with_sub_agent(spec, definition, to: child, prompt:, output:)`. The policy sees
  `StartAgent(name, version)`. The child shares the parent's context type and store, and cancel and recovery cascade to it.
- **Durable workflow (graph)**: `definition.build(Spec(identity, entry, nodes, state, answer, max_activations))`
  is assembled from `definition.node(id, op, select:, accept:, destinations:)`. Operation kinds are `operation.new`
  (an activity with an explicit `Recovery`; `with_replay` opts into replay), `await_signal`, `await_job`/`own_job`,
  `graph.as_subgraph`, `graph/agent.as_operation`, `graph.both`/`map` forks, `graph/llm.new`, and `with_deadline`.
  The runtime is `graph.new(definition, store, context: fn() -> context, policy)`, and its commands are `start/approve/reject/deliver/reconcile/cancel/poll_job`.
  `consumers/writing` is the reference durable workflow: read, generate, review (LLM or TypeSafe), bounded revise, approve, then save.
- **Custom model**: any `model.new(fn(Request) -> Result(Reply, ModelError))`. Provider replay data is stored
  as an opaque `ProviderData(format, value)`.

## Lifecycle and supervision

- The store is the only long-lived component. `store.supervised(store)` returns a `ChildSpecification(Nil)`
  for the store process and its runner factory, and `store.start` is for scripts. Runners are started per run under
  that factory. A shutdown drains them for the `with_drain` window and hands each run off. A runner still working
  when the window ends is killed, and its running tools become uncertain.
- The `Run`/`graph.Handle` handles hold no process and can be rebuilt with `open`/`attach`. `fabric.cancel` always
  commits the cancellation to the record, even without a runner, and kills tool tasks. A running tool's task is
  owned by the runner, and killing the task closes the llm_wire HTTP stream.
- Leased stores renew leases every `lease/3` and kill runners whose lease they lose. Recovery is explicit
  (`recover`), or automatic through the sweeper child spec.
- The application owns: the pog pool (`pog.supervised`), a Sinal forwarder if handlers should run off the commit path,
  `fabric_mcp/client.start`/`stop`, which starts a port process and has no child spec, and any graph `fn() -> context` thunk.

## Failure model

- `StartError`: `StartUnconfirmed(id, reason)` (unknown outcome) or `StartRefused(reason)`.
- `RecordError`: `RunNotFound | StoreUnavailable | UnsupportedVersion | CorruptRecord | IncompatibleAgent(List(Incompatibility))`.
- `CommandError` has 11 variants: `RunEnded`, `RunNotFinished`, `WrongReference`, `StaleReference`,
  `AlreadyAnswered`, `RequirementChanged(PendingApproval)`, `NotReconcilable`, `RunUnattended`,
  `RunnerBusy`, `Contended`, `Unreadable(RecordError)`.
- A run's result is data. `run.Status` is `Working | Unattended | Suspended(approvals, uncertain) | Finished(Outcome)`.
  `Outcome` is `Completed(text) | Refused | OutputLimited | BudgetExhausted(TurnLimit|TokenLimit|FamilyLimit) | BudgetUnverifiable | Cancelled | Failed(HostFailure)`.
  `HostFailure` separates policy failure, output encoding, tool drift, `ModelFailed(ModelError)` and protocol violations.
- Tool errors are classified by the caller into `tool.Explain` or `tool.Uncertain`. Graph operations use
  `operation.DefiniteFailure` or `UncertainEffect`. `graph.Status` has 15 variants, including `Blocked`, `Expired` and `Cancelled(Cancellation)`.
- `graph.Error` (11 variants) includes the stringly `CallbackFailed(String)` and `CommandRefused(String)`.

## Composition seams

- **llm_wire (hard core dependency).** `gleam.toml` depends on `llm_wire` unconditionally, but only
  `fabric/llm` and `fabric/graph/llm` import it. The agent core runs on `fabric/model`, so any client plugs
  in through `model.new`. The coupling is real anyway: llm_wire's HTTP Gun migration breaks Fabric's whole core build.
  Both adapters must take a caller-owned `http_gun.Client`, which `llm.model(settings, model_id)` has no slot
  for. Moving the two adapters into an optional `fabric_llm_wire` package would match `fabric_postgres` and the others.
  `ModelError(reason: String, retryable: Bool)` (`src/fabric/model.gleam:77`) reduces llm_wire's typed
  `WireError` and retry evidence to `string.inspect` text (`src/fabric/llm.gleam:164-197`).
- **relay (no relation; parallel MCP client).** `fabric_mcp` ships its own MCP 2026-07-28 stdio JSON-RPC
  client (`fabric_mcp_stdio.erl`, `fabric_mcp/client.gleam:1-14`) rather than using `relay/client`. It binds
  MCP tools **only as graph operations** (`fabric_mcp.bind -> operation.Operation`, `fabric_mcp.gleam:215`), never as
  agent `tool.Tool`s, and requires a native codec whose schema equals the remote schema. In the other direction,
  fabric tools cannot be exposed over relay. `tool.Definition` and `tool.Tool` are opaque, and their name, schema
  and invoke accessors are all `@internal` (`src/fabric/tool.gleam:380-412`). An adapter would have to re-declare each tool from shared codecs.
- **saga / grind (reimplemented, not used).** `saga_tool.tool(definition, workflow, execution.config(), explain:, rollback_within:)`
  runs a Saga workflow as a single agent tool. Fabric's graph runtime owns its own durable records,
  revisions with compare-and-set, leases, sweeper, deadlines, signals, job polling and forks. That overlaps Saga's
  new persistence and recovery (`saga 23f0bdc`) and Grind's leases, polling and scheduling. Grind integration (S8)
  waits on 4 missing public Grind APIs (`docs/REMAINING.md`).
- **Postgres driver.** `fabric_postgres` pins `pog >= 4.1.0 < 4.2.0` and `pgo >= 0.20.0 < 0.21.0`, the same
  ranges as grind, and resolves pog 4.1.0 and pgo 0.20.0. It uses only public pog with a caller-owned
  `pog.Connection`, has no private-shape FFI, and can share grind's pool. It also inherits grind's tight pin,
  so the two packages must widen together.
- **HTTP.** `the classification bridge` opens `gun` directly (`the former classifier HTTP transport`) instead of using `http_gun`.
  This is a second hand-rolled HTTP client in the ecosystem.
- **sinal.** Agent and store events go through `sinal/forwarder.emit_routed` under `[fabric, ...]`: `run.start/recover/
hand_off/take_over/cancel/stop`, `lease.lose`, `lease.renew.fail`, `sweep.stop`, `model.stop`,
  `approval.request/answer`, `tool.start/stop`, `tool.settlement.refuse`, `child.start/stop`, `drain.stop/unavailable`.
  **The graph runtime emits no events**: nothing under `src/fabric/internal/graph/` imports `observe` or `sinal`.
- **json_blueprint.** `Codec` is used for tool and graph declarations, and stored values go through json_blueprint `Value`.
  This dependency is justified by the schema requirement.

## Ergonomics concerns

1. **Two runtimes with different vocabularies for the same ideas.** Tool failures are
   `tool.Explain/Uncertain` (`src/fabric/tool.gleam:64`) while operation failures are `operation.DefiniteFailure/UncertainEffect`
   (`src/fabric/graph/operation.gleam:30`). `tool.define(name, description, ..)` (`tool.gleam:132`) differs from
   `operation.new(run.Identity, ..)` (`operation.gleam:100`). There are two `Policy`/`Action` types (`policy.gleam:42`
   and `graph.gleam:39-51`). The command shapes also diverge: agent `approve(run, ref, reviewer:, context:)`
   (`fabric.gleam:546`) against graph `approve(handle, approval)` with no reviewer (`graph.gleam:1034`), and agent `cancel` returning
   `Status` (`fabric.gleam:682`) against graph `cancel` returning `Nil` (`graph.gleam:1021`). The context model differs too: per-call
   `context` in `fabric.start`/`approve`, against a captured `fn() -> context` in `graph.new` (`graph.gleam:214`) and
   `graph/agent.new` (`graph/agent.gleam:52`). Run ids are generated by `fabric.start` but supplied by the caller to `graph.start` (`graph.gleam:818`).
2. **The llm_wire adapter has no slot for a caller-owned transport and is already broken.** `llm.model(settings, model_id)`
   (`src/fabric/llm.gleam:39`) and `graph/llm.new(.., request: fn(context, input) -> #(config.Config, types.Request))`
   (`src/fabric/graph/llm.gleam:36`) both predate llm_wire's `session.run(client, prepared)`. The core package fails
   to compile against sibling HEAD.
3. **Stringly failures where callers must branch.** `ModelError(reason: String, retryable)` (`model.gleam:77`) drops
   deadline, status and rate-limit detail. `graph.Error.CommandRefused(String)`/`CallbackFailed(String)` (`graph.gleam:197`).
   `start_with_budget` reports invalid limits as `StartRefused("invalid family budget limits")` (`fabric.gleam:184-190`)
   instead of a typed `budget` error. The whole `fabric_mcp` facade returns `Result(_, String)` (`fabric_mcp.gleam:73,215`;
   `client.gleam:57`), built with `string.inspect`.
4. **Positional same-typed arguments.** `graph.with_timeouts(runtime, callbacks, operation, commands)` takes three
   unlabeled `Int`s (`graph.gleam:289`). A public `Options` record, like `agent.Limits`, would fit the guidelines.
5. **Final output is a string.** `run.Completed(text: String)` (`run.gleam:143`), plus string-parsing `output:`
   callbacks in `agent.with_sub_agent` (`agent.gleam:201`) and `graph/agent.Definition.answer`. A typed agent cannot
   return a caller record without a hand-written parser, despite the json_blueprint codecs already present.
6. **MCP client without supervision.** `fabric_mcp/client.start` (`client.gleam:57`) spawns a port with no
   `ChildSpecification`, unlike `store.supervised` and `fabric.sweeper`. Lifetime is manual (`stop`).
