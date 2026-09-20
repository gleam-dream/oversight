# `fabric` — a Gleam agent-orchestration package

- Fabric provides a typed autonomous agent loop with contextual tools, bounded execution, action policy, and resumable approval. It consumes independently usable package contracts for data, providers, workflows, delivery, and observations.
- This remains a **partial BeamWeaver-style migration**. Retrieval/RAG, vector storage, and document loading/splitting were excluded in the baseline and remain external tool integrations.
- The baseline at `9194f02` already separated five concerns (`dag`, `durable_run`, `agent`, `llm_wire`, `gate`). The package assignments below refine those existing boundaries; they do not establish that the original design was monolithic.
- [PUBLIC-API.md](PUBLIC-API.md) freezes the initial facade and [API-COVERAGE.md](API-COVERAGE.md#fabric) records its evidence. An unimplemented capability remains backlog unless this design explicitly excludes it; the facade freeze does not reduce the full requirements.

## Package ownership and dependency direction

| Baseline concern                | Current owner                             | Fabric integration requirement                                                                |
| ------------------------------- | ----------------------------------------- | --------------------------------------------------------------------------------------------- |
| Typed value-dependency DAG      | [Saga](saga-design.md)                    | Adapt agent operations through typed input, output, error, and compensation contracts.        |
| Durable graph execution         | Saga and its optional `saga_grind` runner | Preserve owned suspension and child references without a second graph journal.                |
| Queue delivery                  | [Grind](grind-design.md)                  | Deliver work naming a Fabric continuation or Saga run; never serialize live closures.         |
| Agent loop and action policy    | Fabric                                    | Own model turns, tool reports, approval state, budgets, and agent continuation compatibility. |
| Provider adapters and transport | [LLM](llm-design.md)                      | Retain the originating provider and consume its public buffered and streamed contracts.       |
| JSON Schema-aware contracts     | [Blueprint](blueprint-design.md)          | Derive tool declarations and dispatch from the same retained codecs.                          |
| Observation delivery            | [Sinal](sinal-design.md)                  | Emit Fabric-owned facts after accepted state transitions.                                     |

- Fabric's agent core must remain usable without a workflow graph or queue. An integration with Saga or Grind must reside in an optional distribution unit or application adapter; an optional module does not make package dependencies optional.
- LLM owns its request, response, and continuation vocabulary without importing Fabric. Fabric may depend on the LLM public contract, but must not import specific provider networking to implement agent policy.
- Blueprint owns JSON Schema-aware contracts for tool declarations and structured output. Ordinary continuation or other JSON serialization uses standard Gleam JSON encoders/decoders and may use an optional schema-independent codec abstraction. Each package owns its boundary errors and admission rules. Native application values remain typed until a named network or persistence boundary requires encoding.
- Sinal delivers observations without owning state transitions. Packages define distinct event descriptors and fact types; no universal lifecycle event, task type, context, retry policy, or persistence protocol is introduced.

## 0. `gate` — action policy and approval

- The application supplies explicit policy and trusted context. There is no implicit allow branch; an explicitly named `always_allow` policy remains available for parity tests and applications that deliberately choose it.
- Policy inspects an action before a tool invocation or sub-agent admission. Action identity includes the logical run, trusted incarnation, model-turn ordinal, provider call identifier, and exact arguments; provider call identifiers alone may repeat on later turns.
- Inspection does not execute the action. Preparation retains the exact action and context admitted by policy; input-dependent authorization may additionally run inside the typed handler after decoding.
- Policy distinguishes allowance, model-visible denial, and required approval. Policy failure remains a host failure and must not silently resume the model as an ordinary business failure.
- An external policy timeout or unavailable service must fail closed. The selected adapter reports the failure explicitly and never substitutes allowance.
- Approval suspends execution instead of blocking a worker indefinitely. Its reference identifies the action, requirement version, and approval revision; wrong, stale, and already answered references have distinct outcomes.
- Answering approval rechecks current policy with current context. Current denial or policy failure wins, and a changed approval requirement requires another answer.
- Approved invocation retains the same context used by the recheck. A stored approval answer alone does not authorize a changed action or a later incarnation.
- Durable approval requires authenticated answer commands, expiry and cancellation rules, and compare-and-set ownership of the latest revision. A copyable pure controller, approval reference, or prepared invocation does not prevent replay or establish atomic enforcement.
- Fabric owns its approval state. A Saga integration maps suspension to the runner's owned waiting state and routes the answer back to the same Fabric continuation; it must not create two competing owners of one pending decision.

## 1. `dag` — typed workflow requirements reassigned to Saga

- Saga owns generic workflow authoring and execution. Fabric does not retain a second `fabric/dag` implementation or promise compatibility with the baseline's provisional module paths.
- The retained baseline requirement is a pure typed value-dependency graph whose mismatched connections cannot compile. Authoring and validation must be usable without processes, actors, clocks, I/O, or an OTP supervision tree.
- Authoring validation must reject cycles, missing producers, duplicate writers without a declared reducer, and unreachable outputs. Control-only edges remain outside the baseline value-dependency contract.
- The baseline proposed Kahn-style topological validation and associative reducers for multiple writers. Saga integration must establish equivalent validation and an explicit reducer mapping before claiming coverage; associativity is an application obligation, not a property proved by the compiler.
- Native types govern connections. Versioned encoders/decoders govern persisted boundaries without requiring Blueprint; explicit schema compatibility applies only where the boundary requires JSON Schema. Graph authoring errors remain distinct from execution failures.
- The current shared workflow experiments establish useful typed composition, not complete equivalence to every baseline graph operation. Reducer behavior and control-edge compatibility remain explicit friction to resolve during implementation.

## 2. Durable execution, checkpoints, and review

- Saga's durable runner owns graph progress, readiness, branch choices, retries after observed operation failure, compensation, and the child journal. Grind owns admission, claims, capacity, delivery recovery, and job state.
- Grind retains its independent dependency-only job workflows. Those workflows do not imply typed final output or Saga compensation, and Fabric integration must not replace them with an assumed universal Saga scheduler.
- The baseline durable execution requirements remain assigned to that runner (start, cancellation, typed completion, graph signature, snapshot, restore, memory and PostgreSQL checkpoint backends, expected revision, conflict outcomes, and review tickets). Persisted state must restore through compatible deployed definitions and codecs rather than saved closures.
- Checkpoint commits must compare the expected revision and return a conflict instead of overwriting newer state. Definition identity, definition version, structural compatibility, and boundary codec versions remain separate compatibility assertions.
- Historical review forks remain a baseline requirement: an earlier revision may be resumed with a different answer under an explicit effect policy. Neither the current facade nor an ordinary retry proves safe historical forking; ownership and treatment of already performed effects remain unresolved.
- Fabric owns a separate versioned agent continuation record (transcript, originating provider continuation, outstanding calls, accepted reports, budget counters, approval state, definition version, child links, and ambiguous effects). A Grind job carries its reference rather than the state of a live controller.
- Restart must reload the latest record through a compare-and-set store port. Unsupported migration, corrupt state, incompatible provider continuation, stale commands, and duplicate commands require explicit outcomes.
- Completion recording and admission of newly ready work require a shared transaction or transactional outbox with idempotent admission. A queued callback and a type-correct snapshot do not establish durability.
- A process lost after an external effect but before recording its result leaves an uncertain effect unless transactions, fencing, or downstream idempotency resolve it. Neither delivery recovery nor agent retry may assume that the effect did not occur.
- The baseline requires single-node BEAM OTP supervision with durable checkpoints. Multi-node distributed coordination remains excluded from this partial migration; reassignment to a capable queue does not silently expand Fabric's claim.

## 3. `agent` — the autonomous LLM loop

### Typed contextual tools

- A tool retains its native argument and result codecs and typed application handler. A heterogeneous registry preserves those individual relationships behind the registration boundary and rejects duplicate names.
- Request context is separate from business input. An application function and its codecs may also be exposed through Relay or Grind, whose adapters retain their own authorization, error, retry, and lifetime rules.
- Declarations and dispatch derive from the same registry. Construction validates available schema metadata, while each invocation decodes and validates incoming provider arguments before calling the handler; construction does not validate future argument values.
- Tool visibility and permission to execute are separate decisions. Tool metadata needed by policy remains part of the integration backlog rather than an assumed guarantee of schema registration.
- The LLM adapter admits exact tool schemas against its configured provider profile before rendering or transmitting declarations. Unsupported nested features, unavailable schemas, invalid local input, and remote rejection remain distinct outcomes.
- Arbitrary schema-policy acceptance does not authenticate a provider or prove model compatibility. Fabric delegates generic call/result correlation and provider-bound admission to LLM while retaining application execution policy.

### Current contextual registration

- Code below is a current prototype declaration excerpt: constructor definitions and function signatures retain the linked source module’s names and aliases; function bodies and unrelated declarations are omitted. These excerpts are not standalone modules or published package signatures, and no new compilation or runtime claim follows from this documentation pass.
- [Fabric's registry module](playground/interface_lab/src/lab/fabric.gleam) imports `Codec` from `lab/blueprint`. [The shared-registry consumer](playground/interface_lab/src/consumers/shared_registry.gleam) uses contextual handlers and codec-derived declarations; this schema-bearing seam does not require Blueprint for ordinary continuation serialization.

```gleam
pub fn context_tool(
  name: String,
  input: Codec(i),
  output: Codec(o),
  error: Codec(e),
  handler: fn(context, i) -> Result(o, e),
) -> ContextTool(context)

pub fn registry(
  tools: List(ContextTool(c)),
) -> Result(Registry(c), RegistryError)

pub fn dispatch(
  registry: Registry(c),
  context: c,
  name: String,
  input: Value,
) -> Result(Value, DispatchError)
```

### Turns, budgets, and outcomes

- Fabric owns the bounded action controller and transcript. A model request may complete, produce pending tool calls, require approval, fail at the host boundary, exhaust its budget, or stop for uncertain-effect reconciliation.
- Pending turns retain the original provider and native continuation. Resuming accepts correlated results without accepting a replacement provider, even when another provider has the same native continuation type.
- The model-turn budget must be positive and counts the initial request and every attempted continuation, including provider failures. Tool execution and approval waiting do not reset the count.
- Exhaustion retains outstanding state and prevents new effects whose results cannot be continued within the limit. The older prototype `bounded` callback wrapper does not implement these guarantees.
- Turn, token, elapsed-time, and combined limits remain requirements. Token accounting depends on observed provider usage; elapsed-time accounting requires a trusted clock and interruption behavior, not provider usage metadata.
- Unsupported or unavailable budget dimensions must be rejected or explicitly reported, never accepted and ignored. Token usage omissions, time races, combined limits, and stream interruption remain runtime work.
- Ordinary typed business failures, known missing tools, and policy denial may become model-visible observations. Codec failures and policy failures remain host failures; callback crashes require isolation and an explicit disposition based on whether an effect could have occurred.
- An uncertain effect stops model continuation until explicit reconciliation. It must not be converted into an ordinary tool failure or automatic retry, and reconciliation must match the original action identity.
- Report acceptance rejects foreign and repeated reports. Inspection and dry-run policy cannot fabricate successful tool results, and an issued denial cannot be replaced by success from another policy path.
- Controller values remain copyable. Runtime ownership must serialize transitions, prevent replay of prepared invocations, establish incarnation freshness, contain foreign exceptions, and settle cancellation.

### Current controller boundary

- [The agent controller](playground/interface_lab/src/lab/fabric_agent.gleam) imports `model` as `lab/llm_turn` and `Value` from `lab/value`. The [policy consumer](playground/interface_lab/src/consumers/agent_policy.gleam) exercises allow, denial, approval, and report handling; [the negative approval consumer](playground/interface_lab/negative/approval_reference_is_not_invocation.gleam) rejects executing an approval reference as prepared work.
- This `start` uses the buffered laboratory provider and preserves the native application context in `Controller`. It does not implement the full durable, streaming, token-budget, or elapsed-time requirements above.

```gleam
pub type PolicyDecision {
  Allow
  Deny(reason: String)
  RequireApproval(ApprovalRequirement)
}

pub type Policy(context) =
  fn(context, ActionDescription) -> Result(PolicyDecision, PolicyError)

pub type Started(context, continuation) {
  InitialFinished(Value)
  InitialPendingActions(Controller(context, continuation))
}

pub fn start(
  run: RunId,
  incarnation: Incarnation,
  limit: MaxModelTurns,
  provider: model.Provider(continuation),
  request: llm.Request,
  registry: fabric.Registry(context),
  policy: Policy(context),
) -> Result(Started(context, continuation), AgentError)
```

### Structured output, streaming, and context

- Structured agent output consumes LLM's prepared output schema and retained native decoder. Local schema validation precedes native mapping, and final output validation remains required after tool use.
- Streaming agent execution remains in scope but unimplemented. Fabric must map LLM progress into agent progress while LLM owns partial tool-call assembly, provider resources, and terminal stream outcomes.
- Streaming integration must define approval interruption points, partial transcript commits, cancellation, backpressure, and restart boundaries. Scripted LLM streaming evidence does not establish these Fabric behaviors.
- Automatic context pruning and summarization remain deferred v2 capabilities, as in the baseline. A budget limit must report exhaustion; provider context-window rejection must remain an explicit provider outcome when local accounting cannot predict it.

### Sub-agent execution

- Sub-agent spawning remains a retained growth requirement with pre-effect policy. The baseline's role and budget-hint strings were placeholders, not a complete execution contract.
- A concrete consumer must define child input, accessible tools, allocated budgets, recursive depth, completion, cancellation, effect ownership, and parent recovery. Reuse Saga child semantics where they fit instead of introducing a second child runtime.
- Supervision, resource partitioning, and durable parent-child recovery require runtime evidence. The initial facade freeze defers this work without excluding sub-agents from the full design.

### Package observations

- Fabric emits an accepted-action fact only after report acceptance succeeds. The fact carries model-turn ordinal, call identifier, and a package-owned model-visible, host-failure, or outcome-unknown disposition.
- The full action identity stays on the controller and report. The observable turn and call identifier subset is not a unique identity across runs.
- Failed event delivery must not make a report acceptable again or roll back the accepted state. Additional lifecycle descriptors follow concrete Fabric facts rather than a shared cross-package event enum.
- Live delivery, backend failure handling, persistence ordering, callback ordering, and native Sinal integration remain runtime obligations.

## 4. `llm_wire` — provider capability reassigned to LLM

- [LLM](llm-design.md) owns standalone provider-neutral buffered calls, structured calls, tool turns, provider-origin continuations, streamed progress, and provider-specific adaptation. Fabric must remain a consumer of those contracts.
- The baseline OpenAI, Anthropic, and Google adapter targets remain provider coverage requirements owned by LLM. Initial adapters and optional reuse do not establish complete multi-vendor parity.
- Transport ownership includes HTTP/TLS, connection reuse, bounded buffering, timeouts, incremental SSE frame reconstruction across chunks, and credit-based backpressure. Peer and hostname verification must remain enabled by default; tests use explicit trusted-CA configuration.
- Every stream cursor must share an idempotent resource close with cleanup on success, error, cancellation, and panic. Fabric integration must prove that agent termination reaches this cleanup boundary.
- The baseline `gun` dependency-versus-vendoring question moves to LLM's adapter decision. Existing package reuse, native wire implementation, and optional ReqLLM adaptation require clean consumer builds and behavioral validation; no particular transport is selected by Fabric.
- Provider retry and continuation restoration remain explicit adapter contracts. An integration must assign retry at one declared layer per effect so provider, Saga, and Grind retries do not multiply ambiguous calls.

## Composing agents, workflows, and durable children

- A bounded synchronous agent operation can be adapted as a Saga activity through ordinary typed functions. Read-only work needs no special graph representation; side-effecting work requires declared compensation or effect receipts because deleting a transcript does not undo tools.
- Approval waiting is neither a completed value nor a failed activity. An adapter must retain one continuation owner and map suspension explicitly instead of triggering compensation or rerunning the agent.
- The first durable composition may approve in Fabric before starting a side-effecting Saga child. A suspending agent inside Saga remains a required integration contract to prove before advertising that mode.
- Fabric may submit or attach an opaque Saga child through a configured owner. Fabric stores the parent continuation and child link; Saga alone controls the child's scheduling, journal, rollback, and compensation.
- Reattachment requires a fresh compatible child contract and its retained codecs. Owner, run, definition, signature, and boundary versions are checked before decoding persisted results; a child link is routing data, not a credential.
- Child outcomes preserve waiting, typed completion, failure with undo errors, cancellation, and reconciliation. Missing or expired results, corrupt data, unavailable owners, and incompatible definitions remain distinct from ordinary waiting.
- Parent recovery records stable submission, cancellation, and compensation command identities. It must recover an already admitted child after a crash before parent-link persistence rather than submit a second logical child.
- Waiting releases worker capacity, including a single-slot queue needed by the child. Child deadlines cannot extend the parent's deadline, and nested concurrency must use an explicit shared or partitioned budget.
- Cancellation requests go through the child owner and settle against committed child state. A parent must not infer cancellation from a cancelled delivery job or retry a completed or partly executed child without an explicit replay-safety contract.
- Compensation is opt-in authority returned through a retained receipt. Durable receipt references must rebind through the original contract after restart; completion alone does not grant compensation rights, and later compensation does not erase historical output.
- Notifications may wake a parent, but committed owner state controls progress. Sinal observations must never drive child completion or resume, and read-only introspection must not permit rescheduling child internals.

## Baseline capability disposition and oracle validation

| Baseline capability at `9194f02`                                                | Disposition and evidence limit                                                                                             |
| ------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Typed pure DAG, validation, reducers                                            | Reassigned to Saga; reducer and control-edge correspondence remain unresolved.                                             |
| Durable OTP execution, memory/PostgreSQL checkpoints, revisions, cancellation   | Reassigned to Saga runner and Grind delivery; no Fabric restart guarantee follows from interface probes.                   |
| Review tickets and historical forks                                             | Review ownership is integrated with Fabric approval; historical forks remain unproven backlog with effect-policy friction. |
| Bounded agent, typed tools, structured output                                   | Retained; contextual registration and scripted policy/turn consumers provide partial evidence.                             |
| Turn/token/time budgets                                                         | Retained; only model-turn accounting has controller evidence.                                                              |
| Approval and sub-agent gating                                                   | Retained; tool approval is scripted, sub-agent execution remains open.                                                     |
| Streaming and multi-vendor adapters                                             | Provider capabilities reassigned to LLM; streamed Fabric execution and full vendor coverage remain open.                   |
| Lifecycle instrumentation                                                       | Retained as package-owned Sinal facts; accepted-action projection is demonstrated, native delivery is not.                 |
| Context pruning/summarization                                                   | Retained v2 backlog, not an initial facade promise.                                                                        |
| RAG/vector/document processing, distributed coordination, cyclic control graphs | Inherited exclusions, not losses introduced by consolidation.                                                              |

- BeamWeaver remains a partial behavioral oracle for the migrated subset. Before differential testing, record the exact upstream revision, fixture provenance, and license; no completed upstream parity run is claimed here.
- Preserve the baseline bypass-policy differential suite before integrating real policy into runtime execution. The bypass must be explicit and must isolate migrated behavior from Fabric-specific authorization behavior.
- Retain upstream interrupt/review scenarios (`review.batch`, `review.subset`, ticket ownership, resume conflicts). Their applicability to policy approval must be established case by case because a human review pause is not automatically an authorization pause.
- After the relevant bypass suite passes, validate real denial, approval suspension/resume, fail-closed external policy, and the Saga waiting integration. The existing pure policy experiments are interface evidence and do not replace this runtime ordering or the upstream comparison.
- Validation must cover compiler-negative native type relationships, malformed provider input, action correlation, repeated/stale approval, provider substitution, model-turn exhaustion, and uncertain-effect reconciliation. Runtime tests must add process loss, restart, migration rejection, duplicate delivery, concurrent compare-and-set, child admission races, capacity-one waiting, compensation failures, stream cleanup, and observed budgets.
- New potential capability loss is confined to unresolved reassignment equivalence: graph reducers, historical review forks, suspension inside Saga, streaming agents, and concrete sub-agent execution. These remain required backlog and must not be reported as completed merely because the initial facade is frozen.

## Evidence and remaining decisions

- The current design incorporates [agent policy](playground/interface_lab/AGENT-POLICY.md), [schema admission](playground/interface_lab/SCHEMA-ADMISSION.md), [provider-bound turns](playground/interface_lab/PROVIDER-STRUCTURED-TURNS.md), [child attachment](playground/interface_lab/CHILD-ATTACHMENT.md), and [package observations](playground/interface_lab/PACKAGE-OBSERVATIONS.md).
- [Composition contracts](research/composition-contracts.md), [workflow boundaries](research/workflow-boundaries.md), and [child lifecycle](research/child-lifecycle-contract.md) ground the ownership assignments. Scripted callbacks, copyable opaque values, and unfinished runtime functions establish neither durable ownership nor exactly-once effects.
- Implementation must resolve continuation encoding and compatibility, live cancellation, observed budget dimensions, approval expiry/authentication, historical-fork effect policy, and the retained graph-validation requirements. Provider transport selection belongs to LLM, and graph journaling belongs to Saga's runner.
- The facade freeze ends interface-refinement work for now. Reopen a public signature only when implementation demonstrates a concrete caller mismatch, while retaining every open full-system requirement above.
