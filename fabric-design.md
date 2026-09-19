# `fabric` — a Gleam agent-orchestration package

A design for bringing BeamWeaver-style capability to Gleam/BEAM — a typed
workflow DAG engine, durable OTP execution, an autonomous LLM agent loop, and
multi-vendor model provider adapters — as one `gleam-dream` package,
`fabric`, organized into clearly separated internal modules rather than
either one flat monolith or an early five-way package split. This is a
**partial** migration by design: retrieval/RAG, vector storage, and document
splitting are explicitly out, left to compose in later through the same
standard interfaces any external system would use.

**Packaging is deliberately not decided yet.** The five concerns below
(§0–§4) are internal modules of `fabric` — `fabric/dag`, `fabric/gate`,
`fabric/durable_run`, `fabric/agent`, `fabric/llm_wire` — for now. Two
things could still change that before v1 ships: (1) one or more of these
modules might turn out to be better served by an existing Gleam package
than by code written here — that survey hasn't happened yet — and (2) even
if all five are written fresh, splitting some of them into their own
top-level packages later remains open, once real usage shows which
boundary actually needs independent versioning. The module boundaries
below are written to make either outcome cheap: each one is designed as if
it might become a separate package, so promoting one out of `fabric` later
is a mechanical extraction, not a redesign.

Guiding rule, same as the rest of `gleam-dream`: **keep everything typed;
push `Dynamic`/JSON to one named boundary module per package, at the point
where a value has to survive a process crash, a node restart, or a network
hop.** A DAG compiler needs none of that. A durable runtime needs it at the
checkpoint boundary. Provider wire codecs need it at the HTTP boundary. Each
package draws that line once, for its own reason — never as a default.

A fifth concern sits alongside these from the start rather than being
bolted on later: **every side-effecting action a run or an agent loop is
about to take — a tool call, spawning a sub-agent, anything a deployer might
want a human or an external policy service to authorize first — passes
through one named decision point before it happens.** This is `gate` (§0
below). It is designed in up front because retrofitting an authorization
seam after `agent`'s loop and `durable_run`'s execution model are already
fixed is exactly the kind of change that forces a breaking rework of both.

## Why five modules, cleanly separated

A workflow orchestrator, a durable execution runtime, an autonomous agent
loop, a set of LLM wire adapters, and an action-authorization seam are five
different reasons to depend on something, even while they ship inside one
`fabric` package:

- Someone wants a **typed DAG compiler** with zero runtime footprint —
  validate a pipeline shape at compile time, run it in a test, no OTP
  supervision tree required. `fabric/dag` should be usable on its own, the
  same way `saga`'s `Plan` combinators (`saga-design.md`) are usable
  without ever touching a job queue.
- Someone wants **durable execution** — a run survives a node restart, has
  an id and a revision, supports checkpointing and human review gates. This
  needs OTP and a persistence backend. It should not be a precondition for
  using the DAG compiler in a test.
- Someone wants an **autonomous agent loop** — a bounded conversation with
  tool calls — and does not care whether it ever touches a DAG at all. Most
  agent use is exactly this: one loop, no orchestration.
- Someone wants **LLM wire adapters** on their own, to build something that
  isn't an agent loop at all (a one-shot structured-extraction call, a
  custom retry policy, a different orchestration shape entirely).
- Someone wants to **authorize actions at runtime** — decide, per call,
  whether a tool may run or a sub-agent may spawn, possibly by asking a
  human or an external policy service — without that decision logic caring
  whether it's gating a DAG node, a durable run, or a bare agent loop.

A consumer who only wants the DAG compiler still pulls in `fabric` as a
whole today — that's the real cost of shipping one package instead of five,
paid deliberately, in exchange for not committing to package boundaries
before real usage tests them. Internally, the five modules stay strictly
separated anyway: module boundaries mirror what would be the package
boundaries, so each one answers exactly one of those five reasons and
composes with the others through ordinary function calls — never through a
shared internal representation, even though they currently live in one
compilation unit.

```
              ┌───────────────┐        ┌───────────────┐
              │ fabric/dag     │        │ fabric/gate    │  pure: Action,
              │ (no OTP, no    │        │ (no OTP, no    │  Decision, the
              │  I/O)          │        │  I/O)          │  Gate function type
              └───────┬───────┘        └───┬───────┬────┘
                      │ takes a compiled    │       │
                      │ Dag(i, o) as input  │       │ checked before
                      ▼                     │       │ a tool call or
              ┌───────────────┐             │       │ sub-agent spawn
              │fabric/         │◀────────────┘       │
              │durable_run     │ RequireApproval      │
              │ OTP execution, │ becomes a durable    │
              │ checkpoints,   │ review.Ticket         │
              │ review tickets │                      │
              └───────┬───────┘                      │
                      │ (a durable_run occurrence MAY call         │
                      │  into an agent loop as ordinary work —      │
                      │  see "Composing with an agent loop")        │
                      ▼                                             ▼
              ┌───────────────┐        ┌───────────────┐
              │ fabric/agent   │──────▶│fabric/llm_wire │
              │ (LLM loop,     │ calls  │ (provider      │
              │  tools, budget,│ a Model│  adapters,     │
              │  checks gate)  │ port   │  transport,SSE)│
              └───────────────┘        └───────────────┘

              sinal (sinal-design.md) is depended on by durable_run, agent,
              and llm_wire — each emits its own typed events through it;
              none of them invent their own event type.
```

Dependency direction is a strict DAG, enforced the same way it would be
across separate packages: internal module visibility means `fabric/llm_wire`
simply has no way to import `fabric/agent`, even though both live in the
same package. `fabric/llm_wire` is a genuine leaf: it defines its own
request/response and model-port types and knows nothing about
`fabric/agent`. `fabric/agent` adapts those types to build a conversation
loop. `fabric/durable_run` depends on `fabric/dag` (it executes a compiled
graph) and is the only one of the five that needs OTP and a storage
backend. `fabric/gate` depends on nothing project-specific either — like
`fabric/dag`, it is pure types and pure functions, so both
`fabric/durable_run` and `fabric/agent` can depend on it without either one
becoming the other's dependency. `fabric/dag` itself depends on nothing
project-specific at all. This internal DAG is exactly the dependency graph
each module would need to keep if it were later promoted to its own
top-level package — nothing about the shape changes at extraction time.

## 0. `gate` — the runtime authorization seam

```
fabric/gate.gleam            -- Action, Decision, Gate, ApprovalRequest
fabric/gate/identity.gleam    -- GateId: a correlation id for one pending decision
```

A `Gate` is a plain function value — no typeclass, no registration table,
the same shape as any other port type in this design:

```gleam
pub type Action {
  ToolCall(name: String, args: BitArray)
  SubagentSpawn(role: String, budget_hint: String)
  // a closed, exhaustively matched sum type — a new action kind is a
  // compile error everywhere it isn't handled yet, not a silently
  // ignored string tag
}

pub type Decision {
  Allow
  Deny(reason: String)
  RequireApproval(request: ApprovalRequest)
}

pub type ApprovalRequest {
  ApprovalRequest(action: Action, id: identity.GateId)
}

pub type Gate =
  fn(Action, context: BitArray) -> Decision
```

`Action`'s payload fields are pre-encoded (`BitArray`), not the caller's
live typed values — `gate` sits below both `agent` and `durable_run` in the
dependency graph and must not import either one's message/conversation
types just to describe what it's authorizing. The caller (`agent`, later
`durable_run`) is responsible for encoding enough of the action to make an
external decision, the same "encode at the one boundary that needs it"
discipline the rest of this design uses.

**Why `RequireApproval` is a third case, not folded into `Deny`.** `Allow`
and `Deny` can be answered synchronously by a local, pure policy function —
no I/O, no waiting. `RequireApproval` means the decision needs someone
else — a human, an external approval queue — and that can take seconds or
hours. Whichever package checks the gate cannot block an OTP process for an
unbounded wait, so `RequireApproval` is a **suspend** signal, not a retry
loop: the caller returns a distinct paused outcome and lets whichever layer
already knows how to represent "waiting on an external answer" handle it.
For `agent` running standalone that's a value the caller must persist
themselves; for `agent` running as a `durable_run` node, `durable_run`
already has that mechanism — a human review ticket — so `RequireApproval`
becomes a `durable_run.review.Ticket` instead of a second, competing
pending-state concept. `gate` itself never depends on `durable_run` to make
this work; it just returns a request value that a higher layer knows how to
suspend on.

**Fail-closed is the stated default.** A gate implementation that talks to
an external service and gets no answer (timeout, connection refused) should
produce `Deny`, never `Allow` — this is named explicitly here because it is
easy to get backwards under a `result.unwrap_or` in application code, and
the whole point of designing this seam up front is to make the safe default
the path of least resistance, not something every caller has to remember.

```gleam
pub fn with_gate(options: agent.Options, gate: gate.Gate) -> agent.Options
```

`agent.run` checks the gate at exactly two points — before executing a tool
call, before spawning a sub-agent — always before the side-effecting action,
never after. A `Deny` becomes a typed observation fed back to the model (the
same containment as any other tool failure: the model sees why, and can
adapt, rather than the process crashing).

## 1. `dag` — the pure DAG compiler

```
fabric/dag.gleam              -- Builder(i, o), Dag(i, o), new/add/connect/compile
fabric/dag/node.gleam         -- Node(input, output), typed ports
fabric/dag/codec.gleam        -- Codec(value): the ONE type-erasure boundary
fabric/dag/schema.gleam       -- Schema identity for a codec, used to detect mismatches
fabric/dag/identity.gleam     -- NodeName, validated once at authoring time
```

A node's input and output types are real type parameters. Connecting two
nodes whose types don't match is a compile error, not a runtime `KeyError`
on a misspelled port name.

```gleam
pub opaque type Builder(i, o)
pub opaque type Dag(i, o)

pub fn new(input: codec.Codec(i), output: codec.Codec(o)) -> Builder(i, o)

pub fn add(
  builder: Builder(i, o),
  node: node.Node(input, output),
) -> Result(#(Builder(i, o), node.Output(input), node.Input(output)), Error)

pub fn connect(
  builder: Builder(i, o),
  from: node.Output(a),
  to: node.Input(a),
) -> Result(Builder(i, o), Error)

pub fn compile(builder: Builder(i, o)) -> Result(Dag(i, o), Error)
```

`compile` runs a Kahn-style topological check and rejects cycles and
control-only edges — a DAG here means a genuine value-dependency graph, not
a control-flow graph with data attached. A node with two writers and no
registered reducer is also rejected at compile time (`reduce` registers an
associative combinator for exactly that case; associativity itself is not
checked, and that's stated plainly rather than silently assumed).

`Error` here is a compile-time authoring error (`Cycle`, `MissingProducer`,
`DuplicateWriter`, `UnreachableOutput`) — a different, much smaller error
type than anything a _run_ can fail with, which is `durable_run`'s concern,
not this module's.

There is no process, no actor, no clock, and no I/O anywhere in this
module. `gleam test` against `fabric/dag` alone never spawns an OTP
supervision tree.

## 2. `durable_run` — OTP execution with checkpoints and review gates

```
fabric/durable_run.gleam        -- start/start_durable/cancel, the OTP actor
fabric/durable_run/execution.gleam -- Execution(o), Work, Completion — the run's live state
fabric/durable_run/checkpoint.gleam -- Checkpoint store interface + ExpectedRevision/CheckpointRevision
fabric/durable_run/checkpoint/memory.gleam
fabric/durable_run/checkpoint/postgres.gleam
fabric/durable_run/review.gleam    -- pause/resume human-review tickets, historical forks
fabric/durable_run/retry.gleam     -- backoff policy for a failed node
fabric/durable_run/event.gleam     -- typed lifecycle events, emitted via `sinal`
```

Takes a compiled `dag.Dag(i, o)` as input — it never reaches into `dag`'s
internals, only its public compiled artifact. This is the seam that keeps
`dag` genuinely leaf-like: `durable_run` can change its checkpoint format,
its retry policy, its review-gate machinery, all without `dag` knowing
anything changed.

```gleam
pub opaque type Execution(o)

pub fn start(
  graph: dag.Dag(i, o),
  input: i,
  checkpoints: checkpoint.Store,
) -> Result(process.Subject(Message(o)), StartError)

pub fn signature(graph: dag.Dag(i, o)) -> checkpoint.Signature
pub fn snapshot(graph: dag.Dag(i, o), execution: Execution(o)) -> checkpoint.Snapshot
pub fn restore(
  graph: dag.Dag(i, o),
  snapshot: checkpoint.Snapshot,
  checkpoints: checkpoint.Store,
) -> Result(Execution(o), RestoreError)
```

Checkpoint commits use `checkpoint.ExpectedRevision`; a conflicting commit
(another process already advanced the revision) returns
`checkpoint.Conflict` rather than silently overwriting — the same
optimistic-concurrency shape a Postgres-backed job queue needs, expressed
as a real sum type instead of a string status column.

**Human review gates** are a `durable_run` concept, not a `dag` one: a run
can pause at a node awaiting an external answer, expose that as a
`review.Ticket`, and resume once answered — including resuming from a
_historical_ fork (re-run from an earlier revision with a different
answer). This only makes sense once a run has an id and a revision history,
which is exactly what separates this module from `dag`. It is also the
same mechanism `gate.RequireApproval` reuses (§0) when an `agent` node
running inside a `durable_run` execution suspends awaiting authorization —
`durable_run` does not gain a second pending-state concept for "waiting on
a policy decision" versus "waiting on a human review answer"; a pending
gate decision **is** a review ticket.

Lifecycle events (`Started`, `Completed`, `Failed`, `CheckpointCommitted`,
`ReviewPending`, `ReviewAnswered`) are defined once here and emitted through
`sinal.execute`/`sinal.span` (`sinal-design.md`) — not a bespoke event enum
reinvented per module. A consumer who wants metrics on run duration attaches
one handler to `durable_run`'s span events the same way they'd attach to any
other typed `sinal` event.

## 3. `agent` — the autonomous LLM loop

```
fabric/agent.gleam            -- run/structured/stream, the conversation loop
fabric/agent/tool.gleam        -- Tool(args, result): a typed, schema-validated tool
fabric/agent/message.gleam     -- the shared LLM message vocabulary
fabric/agent/model.gleam       -- Model: the port type agent calls, provider-agnostic
fabric/agent/budget.gleam      -- turn/time/token limits — see below
```

```gleam
pub opaque type Options

pub fn options(model_calls: Int) -> Result(Options, Error)
pub fn with_budget(options: Options, budget: budget.Budget) -> Options
pub fn with_tool_error_policy(options: Options, policy: ToolErrorPolicy) -> Options
pub fn with_gate(options: Options, gate: gate.Gate) -> Options

pub type Output {
  Completed(message.Conversation)
  AwaitingApproval(request: gate.ApprovalRequest, resume: ResumeToken)
}

pub fn run(
  model: model.Model,
  tools: List(tool.Tool(a, r)),
  options: Options,
  input: message.Conversation,
) -> Result(Output, Error)

pub fn resume(
  model: model.Model,
  tools: List(tool.Tool(a, r)),
  options: Options,
  token: ResumeToken,
  decision: gate.Decision,
) -> Result(Output, Error)
```

`with_gate` is optional — an `Options` value built without one behaves as
if every action were pre-`Allow`ed (see §0's bypass gate, used exactly this
way for parity testing below). `AwaitingApproval` only appears when a
configured gate actually returns `RequireApproval`; a consumer who never
sets a gate never sees it and its `Result(Output, Error)` contract is
unchanged from a version of this design without §0 at all.

`model.Model` is a plain port type — a record of functions, not a typeclass
(Gleam has none) — so `agent` never imports anything from `llm_wire`
directly. A provider adapter constructs a `Model` and hands it to `agent`;
the dependency points from adapter to port type, never the other way. This
is the detail worth being deliberate about from the start, since it is easy
to get backwards by accident: if `agent` ever imports a specific provider
module, `llm_wire` stops being a leaf — and since Gleam's own module-privacy
rules are what would enforce this boundary, getting it backwards wouldn't
even fail to compile today, only make a future extraction into separate
packages break.

**Budget is a named, honest concept from day one**, not an afterthought:

```gleam
pub opaque type Budget

pub fn turns(max: Int) -> Budget
pub fn tokens(max: Int) -> Budget
pub fn elapsed(max: duration.Duration) -> Budget
pub fn combine(budgets: List(Budget)) -> Budget

pub type BudgetExceeded {
  TurnLimitReached(Int)
  TokenLimitReached(used: Int, max: Int)
  TimeLimitReached(duration.Duration)
}
```

v1 ships whichever of these three dimensions the provider adapters can
actually report (token counts depend on the provider's response including
usage — not all do, consistently); the ones not yet backed by real data are
left out of `Options`' accepted `Budget` values rather than accepted and
silently ignored. A budget dimension that compiles but never fires is a
worse trap than one that doesn't exist yet.

**Tool execution failure is contained, not fatal**: a malformed tool call or
a tool that raises produces a typed observation fed back into the
conversation, never a process crash — the same "typed core, crash-isolated
where the runtime needs it" split the rest of `gleam-dream` uses. Tool
schema validation happens once, at the `Tool` construction boundary
(`agent/tool.gleam`), so `agent.run`'s hot loop never touches `Dynamic`.

**Context management (pruning/summarizing old turns) is explicitly a v2
concern**, named here so it isn't silently assumed to exist: `run` bounded
by `Budget` is the v1 contract, and a consumer approaching a real context
window limit gets `TokenLimitReached`, not automatic pruning. Building
automatic pruning without first shipping the ability to _observe_ hitting
the limit would be building on an unverified assumption about what "old
enough to prune" means for a given consumer.

## 4. `llm_wire` — provider adapters and transport

```
fabric/llm_wire/provider/openai.gleam
fabric/llm_wire/provider/anthropic.gleam
fabric/llm_wire/provider/google.gleam
fabric/llm_wire/transport.gleam        -- Request/Response, streaming Stream type
fabric/llm_wire/transport/internal/boundary.gleam -- the ONE FFI boundary (TLS, HTTP)
fabric/llm_wire/sse.gleam              -- SSE frame reassembly across chunk boundaries
```

A leaf package: defines its own `Request`/`Response`/streaming `Stream`
types, and a provider module's job is purely to encode a
provider-independent call into that provider's wire format and decode the
response back — it never imports anything from `agent`. Each provider
module exports a constructor that returns an `agent.model.Model` value (a
record of functions) built from its own adapter; `agent` never needs a
compile-time dependency on any specific provider to exist.

**HTTP transport is the one place this package touches FFI**, and it's worth
being deliberate here rather than reaching for whatever's easiest:

- **Connection handling**: a real production LLM client needs to reuse
  connections (opening a fresh TLS handshake per request is real, measurable
  latency against a streaming chat API) and needs to survive a
  misbehaving/slow server without unbounded memory growth. Decide up front
  whether this uses an existing hex-published Erlang HTTP client
  (`gun`, on hex.pm from `ninenines`, is the standard choice for BEAM
  streaming HTTP/1.1+HTTP/2 with backpressure) as a normal dependency, the
  same way this project already depends on `pog`/`epgsql`-style Erlang
  packages elsewhere — versus vendoring. Vendoring is occasionally the
  right call for a security-hardening reason (an unpublished patch, a
  deliberately reduced attack surface), but that's a decision to make
  explicitly, with a written reason, not a default.
- **TLS verification is on by default**, always — peer and hostname
  verification, no silent fallback to unverified connections even in tests
  (tests use an explicit trusted-CA override, never a global "skip
  verification" flag).
- **Streaming uses credit-based backpressure**, not "read everything into
  memory then parse" — a chat completion response can be arbitrarily long,
  and `sse.gleam`'s frame reassembly already handles partial lines arriving
  across chunk boundaries; the transport layer's job is just to deliver
  those chunks without buffering the whole response first.

```gleam
pub type Request {
  Request(url: String, headers: List(#(String, String)), body: String, timeout_ms: Int)
}

pub opaque type Stream {
  Stream(next: fn() -> Result(Step, Error), close: fn() -> Nil)
}

pub fn http_stream(request: Request) -> Result(Stream, Error)
```

Every cursor `Stream` shares one idempotent `close` for its underlying
connection — closed on success, on error, on cancellation, and on panic, so
a consumer can never leak a connection by forgetting to call `close`
manually on every exit path.

## Composing with an agent loop, from a DAG or a durable run

The same composability question applies here as it does across the rest of
`gleam-dream`: can an `agent.run` call be a step inside a `dag`-compiled
graph, or a unit of work inside a `durable_run` execution?

Yes, for free, because `agent.run` is an ordinary function of shape
`fn(input) -> Result(output, error)` once a `model.Model` and `Options` are
partially applied. A `dag.node.Node` wraps any function of that shape — it
does not need to know the function happens to make network calls to an LLM
provider underneath. Concretely:

```gleam
let assert Ok(name) = dag.identity.node_name("draft_response")
let respond_node =
  dag.node.new(name, dag.codec.string(), dag.codec.string(), fn(prompt) {
    agent.run(model, tools, options, message.from_text(prompt))
    |> result.map_error(agent_error_to_dag_error)
    |> result.try(fn(output) {
      case output {
        agent.Completed(conversation) -> Ok(text_of(conversation))
        // an AwaitingApproval outcome from a gate is not an error — see §0 —
        // but a bare `dag` node has no pending-state mechanism of its own,
        // so this composition only makes sense once the node runs inside
        // a durable_run execution, which does
        agent.AwaitingApproval(..) ->
          Error(dag.Error.NotSupported("gate suspension needs durable_run"))
      }
    })
  })
```

The OTP supervision, retries, and checkpointing for that node's execution
are `durable_run`'s concern, not `agent`'s — `agent.run` itself stays a
plain synchronous call. This is deliberately the _simplest_ composition
available: no shared internal representation between `dag`/`durable_run`
and `agent`, just one module's public function wrapped as another module's
node — the same shape this composition would need if `dag`/`durable_run`
and `agent` were ever split into separate packages, so nothing here is
throwaway if that split happens later. A tighter integration — a
first-class "agent step" node type with its own multi-turn/streaming
semantics baked into the DAG's execution model — is real added complexity,
and should only be built once a second concrete use case actually needs
something the synchronous wrapper above can't express, not speculatively.

## Proving parity before building the real gate logic

`gate`'s presence in the type signatures (`Options.with_gate`,
`Output.AwaitingApproval`) is a **structural** commitment made from day one,
on purpose — retrofitting it later would touch every call site that matches
on `agent.Output`. But the actual policy logic behind a `Gate` (a real
external service call, a real human-approval queue) is new behavior with no
upstream equivalent to check against, and is exactly the kind of thing that
should not be built and tested at the same time as the port itself.

So implementation proceeds in two proven stages, not one:

**Stage 1 — a bypass `Gate`, wired in but inert, used to run the upstream
differential suite unchanged.**

```gleam
// fabric/gate/bypass.gleam — ships in the gate module itself, clearly named
// and documented as a testing/scaffolding tool, never the production default

pub fn always_allow() -> gate.Gate {
  fn(_action, _context) { gate.Allow }
}
```

Every `agent`/`durable_run` call site in the differential parity tests
built against upstream's own test fixtures (upstream's interrupt/review
scenarios — `review.batch`, `review.subset`, ticket ownership, resume
conflicts — are the closest existing analogue to what a gate suspension
needs to preserve) is wired with `gate.bypass.always_allow()`. This
isolates one variable at a time: with the bypass in place, `agent.run` and
`durable_run`'s execution behave exactly as they would with no gate concept
in the design at all, so the parity suite is checking "does our port
reproduce upstream's documented behavior," never "does our new
authorization feature work." A failure during this stage is a porting bug,
full stop — there is no ambiguity about which of the two new concerns
caused it, because only one of them is live.

**Only once Stage 1 is green** — the full upstream-derived differential
suite passing with the bypass gate, the same "establishes parity, not just
that our own tests pass" bar the rest of this project holds itself to —
does Stage 2 begin: implement a real `Gate` (a local policy function first,
then the external-service-backed `external_gate` shown below), and write
the tests that are actually new: `RequireApproval` suspension and resume,
`Deny` producing a typed observation instead of a crash, fail-closed
behavior on an unreachable external service, and the `durable_run.review`
reuse path for a gate that suspends inside a durable execution.

```gleam
pub fn external_gate(endpoint: String) -> gate.Gate {
  fn(action, context) {
    case llm_wire.transport.http(policy_request(endpoint, action, context)) {
      Ok(response) -> decode_policy_decision(response.body)
      Error(_) -> gate.Deny("policy engine unreachable")
    }
  }
}
```

This ordering is the point: a regression in core execution behavior can
never hide behind a bug in brand-new policy logic, because until Stage 1 is
proven, the policy logic isn't live in the differential suite at all.

## What's explicitly out of scope for this partial migration

- **Retrieval, vector storage, document loading/splitting (RAG).** These
  compose with `agent` through the same `agent/tool.gleam` interface any
  external system would use — a retrieval backend is just a `Tool` whose
  `run` function queries wherever the vectors live. Building RAG as a first
  -class feature of the core loop would couple the `agent` module to a
  storage technology choice it doesn't need to make. If/when this gets
  built, it's a fresh design (its own package, e.g. a future
  `gleam-dream/retrieval`), not an extension bolted onto `fabric/agent`.
- **Multi-node clustering / distributed execution.** `durable_run` is
  single-node BEAM OTP supervision with a durable checkpoint store;
  distributed lease coordination across nodes is a different, larger
  problem and stays out.
- **Arbitrary cyclic control graphs.** `dag` compiles value-dependency DAGs
  only. A workflow that upstream frameworks express as a cyclic
  control-flow graph (a loop with a guarded exit edge) needs to be
  re-expressed as bounded iteration encapsulated inside one node (an
  `agent` loop is exactly this shape already) — not as a cycle in the graph
  itself.

## Open questions to settle before implementation

1. **`gun` as a direct dependency vs. vendored.** Default to a direct hex
   dependency unless a specific, written security reason says otherwise —
   decide this once, early, rather than defaulting to whichever is easiest
   mid-implementation.
2. **Which budget dimensions ship in v1.** Turn-count is unconditionally
   available from any provider. Token and elapsed-time limits depend on
   what each provider's response actually reports — confirm per-provider
   before promising all three uniformly.
3. **Whether any module gets replaced by an existing Gleam package, and
   whether/when any module gets promoted out of `fabric` into its own
   top-level package.** Both are still open — no survey of the existing
   Gleam ecosystem has been done for `dag`/`gate`/`durable_run`/`agent`/
   `llm_wire` individually, and no module has yet shown the kind of
   independent-versioning pressure that would justify extraction. Revisit
   once real usage exists.
4. **What upstream fixtures the Stage 1 bypass suite actually reuses.**
   Upstream's interrupt/review scenarios (ticket ownership, `review.batch`
   vs `review.subset`, resume-conflict handling) are the closest existing
   analogue for the `RequireApproval`/resume path, but they were written for
   a _human review_ pause, not a _policy-authorization_ pause — confirm how
   much of that fixture set actually transfers before assuming Stage 1's
   suite is "the upstream tests, unchanged."
5. **Whether `SubagentSpawn` needs a richer payload than `role`/
`budget_hint`.** Both are placeholders in §0; the real fields depend on
what a spawned sub-agent actually needs declared upfront for a policy
engine to make a meaningful decision (e.g., which tools it would have
access to) — worth grilling once a concrete sub-agent design exists.
</content>
