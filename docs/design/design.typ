#import ".render/designlib.typ": *

#let title = [Gleam Dream ecosystem]
#let accent = "teal"

#let body = [
  #section(title: "Foundation", lead: "Oversight owns the composition contracts and executable evidence that connect independent Gleam libraries.", body: [
    #goal(title: "Compose independently useful libraries")[Applications build complex behavior from small public surfaces backed by cohesive capabilities. Each library remains useful without an ecosystem-wide runtime.]
    #goal(title: "Make ownership and failures inspectable")[A consumer can determine who configures, starts, cancels, persists, reconciles, and releases each resource. Failures preserve the facts needed for a meaningful next decision.]
    #goal(title: "Retain the intended capability scope")[A bounded release surface does not erase the broader #term("term-capability-scope"). Unbuilt requirements remain visible in the package that owns them.]
    #no-goal(title: "A shared application framework")[Oversight supplies no mandatory runtime, service container, universal error type, common retry engine, or global policy registry.]
    #no-goal(title: "Historical reports as present contracts")[Assessment chronology and decision rationale belong to ADRs. Test transcripts, release plans, and obsolete signatures do not define the current design.]
    #invariant(title: "Every contract has one semantic owner", enforcement: "convention")[Each #term("term-package-authority") defines its own guarantees. Consumers translate meanings explicitly; similar record fields alone do not establish shared meaning.]
    #invariant(title: "Composition preserves known effect evidence", enforcement: "partial")[A #term("term-composition-boundary") must not infer completed, prevented, or compensated work solely from cancellation intent, transport delivery, or loss of a reply. Unresolved implementation conflicts remain explicit gaps.]
    #invariant(title: "Evidence claims name their actual boundary", enforcement: "convention")[Compilation, scripted exchanges, native runtime tests, database tests, and upstream conformance establish different claims. An unexecuted scenario is not reported as passing.]
    #principle(title: "Simplicity includes application responsibility", lens: "composition")[Prefer the design that removes unnecessary concepts and repeated application decisions while retaining meaningful caller control. A shorter facade that shifts hidden work to every application is not simpler.]
    #principle(title: "Domain types and policy belong to callers", lens: "modeling")[Applications supply native records and policy. Libraries require nominal types only when those types carry useful admission, identity, or ownership guarantees.]
    #principle(title: "Bound work where it is owned", lens: "robustness")[Limits state the work they bound and the party that enforces them. Bounded queues, finite waits, cancellation, and cleanup are separate guarantees.]
    #principle(title: "Use executable consumers to judge interfaces", lens: "composition")[An ordinary task, an advanced case, native values, and recovery must be expressible from a #term("term-public-consumer"). Internal elegance does not replace that evidence.]
    The documentation ownership decision is recorded in #adr(1). The package and API boundaries are justified by #adr(2) and #adr(3).
  ])

  #pagebreak(weak: true)
  #pending-ledger(
      pending-entry(title: "A composed request budget needs explicit cleanup", kind: "ruling")[Relay owns one admitted request deadline and a separate bounded cleanup interval; its package design owns implementation acceptance. Saga driver timeout is followed by bounded synchronous cleanup. A composed foreground deadline must reserve admission, execution, cancellation grace, and cleanup rather than assigning the same duration to every phase.],
      pending-entry(title: "External schema breadth must be explicit", kind: "ruling")[Blueprint admits a finite runtime schema profile. General third-party MCP discovery requires a chosen supported vocabulary, bounded validation, and safe provider projection; sibling-to-sibling discovery alone does not establish that breadth.],
      pending-entry(title: "Durable scheduling integration remains application-owned", kind: "ruling")[Applications currently drive and cancel durable Saga and Fabric work through Grind jobs. The intended broader scheduling/retention integration requires a decision about authority before any common driver abstraction is introduced.],
  )

  #pagebreak(weak: true)
  #section(title: "System at a glance", lead: "The ecosystem contains independent libraries, four PostgreSQL adapters, a Postmark adapter, a development mailbox adapter and Retrace core, frontend and server packages. Oversight supplies design coordination and executable composition evidence, with no production runtime dependency.", visual: diagram(
    altitude: "L1", viewpoint: "runtime", title: "Applications select independent library authorities",
    nodes: (
      (id: "app", label: "Application", kind: "external-system"),
      (id: "fabric", label: "Fabric", kind: "component"),
      (id: "relay", label: "Relay", kind: "component"),
      (id: "warden", label: "Warden", kind: "component"),
      (id: "correio", label: "Correio", kind: "component"),
      (id: "saga", label: "Saga", kind: "component"),
      (id: "grind", label: "Grind", kind: "component"),
      (id: "llm", label: "LLM Wire", kind: "component"),
      (id: "http", label: "HTTP Gun", kind: "component"),
      (id: "json", label: "JSON Blueprint", kind: "component"),
      (id: "sinal", label: "Sinal", kind: "component"),
      (id: "retrace", label: "Retrace", kind: "component"),
    ),
    edges: (
      (from: "app", to: "fabric", relation: "call", label: "uses"),
      (from: "app", to: "relay", relation: "call", label: "uses"),
      (from: "app", to: "warden", relation: "call", label: "uses"),
      (from: "app", to: "correio", relation: "call", label: "uses"),
      (from: "app", to: "saga", relation: "call", label: "uses"),
      (from: "app", to: "grind", relation: "call", label: "uses"),
      (from: "app", to: "retrace", relation: "call", label: "uses"),
      (from: "fabric", to: "llm", relation: "dependency", label: "imports"),
      (from: "llm", to: "http", relation: "dependency", label: "imports"),
      (from: "relay", to: "http", relation: "dependency", label: "imports"),
      (from: "warden", to: "http", relation: "dependency", label: "imports"),
      (from: "fabric", to: "json", relation: "dependency", label: "imports"),
      (from: "llm", to: "json", relation: "dependency", label: "imports"),
      (from: "relay", to: "json", relation: "dependency", label: "imports"),
      (from: "http", to: "sinal", relation: "dependency", label: "imports"),
      (from: "saga", to: "sinal", relation: "dependency", label: "imports"),
      (from: "grind", to: "sinal", relation: "dependency", label: "imports"),
    ),
    caption: [The map shows the principal runtime dependencies. The complete direct-dependency table includes direct observation and transport dependencies omitted from this overview. The Retrace node groups its independently selected core, frontend and server packages. PostgreSQL adapters borrow an application-owned connection pool.],
  ), body: [
    #pagebreak(weak: true)
    #subsection(title: "Package responsibilities and dependencies")[The table lists every direct sibling dependency and its semantic exclusion.]
    #md-table(4, (
      [*Package*], [*Owns*], [*Direct sibling dependencies*], [*Excludes*],
      [Sinal], [Typed observations and correlation], [None], [Export policy and application control flow],
      [JSON Blueprint], [Codecs, schema projection, runtime contracts], [None], [Business authorization and execution],
      [HTTP Gun], [HTTP transport, body ownership, redaction and cassettes], [Sinal], [Provider semantics and automatic application retry],
      [Saga], [Typed workflows, compensation and effect settlement], [Sinal], [Job delivery and provider-specific reconciliation knowledge],
      [Grind], [Durable job admission, scheduling and delivery], [Sinal], [Application workflow meaning and exactly-once external effects],
      [LLM Wire], [Provider protocols and classification], [HTTP Gun, JSON Blueprint, Sinal], [Conversation ownership and autonomous tool execution],
      [Relay], [MCP client/server contracts and transport], [HTTP Gun, JSON Blueprint, Sinal], [OIDC custody and application authorization],
      [Warden], [OIDC/OAuth client behavior and token custody/validation], [HTTP Gun, Sinal], [MCP-specific policy and application sessions],
      [Correio], [Transactional message construction, delivery evidence and passwordless verification], [None], [Account policy, application sessions and OIDC token claims],
      [Fabric], [Agents, durable graphs, approvals and managed children], [LLM Wire, HTTP Gun, JSON Blueprint, Sinal], [Job delivery and Saga effect semantics],
      [Retrace core], [Typed recording, checkpoints, wire validation and pure reconstruction], [None], [Capture policy, UI and storage ownership],
      [retrace_frontend], [Browser/Tauri delivery, Lustre capture and optional replay viewer], [Retrace core], [Application state, safe projections and historical build publication],
      [retrace_server], [Session admission, indexing and object archival], [Retrace core], [Pool/worker lifetime, authentication and retention policy],
      [saga_postgres], [Saga persistence, leases and fencing], [Saga, Sinal], [Pool ownership and driver scheduling],
      [fabric_postgres], [Fabric persistence and family retention], [Fabric], [Pool ownership and model/tool policy],
      [warden_postgres], [Warden sealed-record persistence and conditional writes], [Warden, HTTP Gun, Sinal], [Pool ownership, sealing keys and application authorization],
      [correio_postgres], [Atomic challenge persistence and retention], [Correio], [Pool ownership and account policy],
      [correio_postmark], [Postmark submission and delivery evidence], [Correio, HTTP Gun], [HTTP client ownership and automatic resend],
      [correio_mailbox], [Read-only development inspection of captured mail], [Correio], [HTTP server ownership and production access policy],
    ))
    #points(
      [Each package repository owns its detailed layer. Oversight references those contracts without duplicating the package's state machines or glossary.],
      [Composition consumers declare immutable Git sources with matching lockfiles and CI source revisions. Published baselines use local paths only within the consuming repository. Experiments for unpublished contracts use disposable copies of all participating working trees, normalize the full sibling graph and retain source hashes; they do not qualify the published baseline. Evidence retains executed package inputs separately from inspected sibling checkouts. Scheduled compatibility selects captured current revisions in a disposable checkout. #adr(15)],
      [A #term("term-consumer-recipe") may join packages absent from each other's dependency graph. The recipe must understand their public semantics, not their private representation.],
      [The application selects the participating libraries; no package imports Oversight at runtime. The package set is recorded in #adr(14) and #adr(16); removed bridge rationale remains in #adr(3).],
    )
  ])

  #section(title: "Caller contracts", lead: "The public API conventions protect caller choices and extension guarantees. They constrain a boundary without prescribing an identical implementation for every package.", body: [
    #subsection(title: "Values and definitions")[
      #answers(title: "Caller-owned values",
        responsibility: [Preserve native inputs, outputs and meaningful failures through public boundaries.],
        interface: [Typed definitions bind names, codecs and behavior once; caller-built configuration values use opaque constructors and composable settings.],
        interactions: [A heterogeneous registry erases types only after binding each typed operation to its own definition. Persistence requests additional versioned codecs where durable replay needs them.],
        invariants: [A required argument changes observable behavior. Already-owned names and codecs are derived rather than requested again. Missing, null, false and unknown remain distinct when their meanings differ.],
        failure: [Rejected runtime input has a typed failure. Source definition mistakes follow the package's explicit programmer-error/check contract.],
      )
      #points(
        [Configuration construction does not open connections or start work. Complete configuration is validated before owned resources or external effects begin.],
        [Returned records are read by labelled fields. Growing outcome types retain meaningful classifications without erasing evidence into diagnostic strings.],
        [A static record codec, a runtime schema contract, a persistence codec, and a protocol declaration may share data but establish different guarantees. Small explicit adapters remain appropriate where those guarantees differ.],
      )
      #adr(2) #adr(7)
    ]
    #subsection(title: "Extensions retain shared guarantees")[
      #contract(name: "Public extension boundary", mission: "Vary behavior without bypassing admission or ownership.", answers: answers-data(
        responsibility: [The library retains its common admission, bounds, correlation and cleanup rules; the extension supplies only its declared variable behavior.],
        interface: [Public typed callbacks, protocol reducers, codecs or storage ports.],
        interactions: [The consumer owns captured resources and the library owns the invocation lifetime it explicitly promises. Callback process affinity is part of that agreement.],
        invariants: [An extension does not gain an undocumented path around destination policy, version checks, principal binding or state transitions.],
        failure: [Unsupported extensions fail explicitly; a callback failure cannot be interpreted as confirmed non-execution unless that is known.],
      ))
      #behavior(title: "A new extension must work outside its library", area: "Public extension admission", level: "boundary")[
        #given[A consumer supplies its own domain values and extension behavior.]
        #when[The consumer exercises the common and advanced public paths.]
        #then[The extension reaches its capability without importing implementation internals.]
        #then[Its failure and resource ownership remain observable through the public contract.]
      ]
    ]
  ])

  #section(title: "Execution and evidence boundaries", lead: "Several libraries execute work, but their authority applies to different facts. Composition retains those distinctions when mapping results or stopping work.", body: [
    #subsection(title: "Delivery is not effect settlement")[
      #md-table(4, (
        [*Authority*], [*Identity*], [*Durable fact*], [*What it cannot establish alone*],
        [Grind], [Submission receipt and job/attempt identity], [Admission and acknowledged delivery outcome], [Whether an unacknowledged external effect occurred],
        [Saga], [Workflow run, step and effect identity], [Checkpoint and known/unknown compensation evidence], [Destination deduplication merely from supplying a key],
        [Fabric], [Run, operation, approval and child identity], [Agent/graph state and recorded operation evidence], [The real-world result of a lost tool reply],
        [HTTP Gun / Relay / LLM Wire], [Exchange or caller-propagated identity], [Observed exchange and delivery evidence], [Application effect completion or successful compensation],
      ))
      #contract(name: "Outcome translation", mission: "Preserve the facts needed to recover across libraries.", answers: answers-data(
        responsibility: [The application maps delivery, domain failure, compensation and #term("term-effect-evidence") without treating them as synonyms.],
        interface: [Typed package outcomes and explicit application policy.],
        interactions: [Saga reports may be projected into Fabric tool results; LLM/HTTP failures may become Grind retry, snooze, discard or uncertain responses.],
        invariants: [A later success does not erase an earlier unresolved effect. A cancellation request does not certify non-execution.],
        failure: [Insufficient evidence leads to reconciliation or a truthful unknown result, not an automatic retry of a mutating effect.],
      ))
      #behavior(title: "Unknown delivery requires an effect policy", area: "Outcome translation", level: "boundary")[
        #given[An application operation may have performed an external effect and lacks confirmation.]
        #when[The application maps the package failure into another execution authority.]
        #then[The result retains the unresolved effect unless independent evidence settles it.]
        #then[Retry requires an explicit idempotency, fencing, transaction or reconciliation policy.]
      ]
      #adr(4)
    ]
    #subsection(title: "Identity scopes remain separate")[
      #points(
        [An #term("term-admission-identity") converges repeated admissions within its owning authority and retention window. It does not replace a destination's effect key.],
        [Grind uniqueness controls occupancy among selected job values and states. It does not serialize every external effect or prove permanent uniqueness.],
        [Fabric keyed invocation binds caller principal and key to a run; correlation remains an observation value, not the authenticated principal.],
        [Persistence codecs and worker/operation versions identify compatibility. An application changing behavior without its required version change cannot rely on replay equivalence.],
      )
    ]
    #subsection(title: "Budgets and cleanup have different intervals")[
      #md-table(4, (
        [*Phase*], [*Owner*], [*Examples*], [*Required composition fact*],
        [Admission], [Endpoint/configuration authority], [Token verification, context creation, queue/pool acquisition], [Whether time and cancellation are bounded before effects start],
        [Execution], [Active exchange/attempt/run owner], [HTTP body, model call, Saga attempt, Grind handler], [Remaining budget and propagation into nested calls],
        [Settlement], [Effect authority], [Undo, interrupted-effect resolution, tool settlement], [Whether a returned stop still carries unresolved effects],
        [Cleanup], [Resource owner], [Runner drain, claim release, stream close, pool shutdown], [Whether return confirms release or only requests it],
        [Durable waiting], [Persisted run authority], [Approval, graph signal, redelivery], [Whether a caller timeout stops waiting, stops a driver, or cancels the durable run],
      ))
      #points(
        [The application reserves time for nested execution and cleanup rather than assigning the same nominal timeout at every layer. A per-attempt timeout does not bound retry delays or the whole conversation.],
        [Killing a BEAM worker ends local execution, not an external side effect. A borrowed resource remains available until its users have completed the cleanup guarantees they actually provide.],
        [A provider Retry-After longer than the foreground budget may be returned or scheduled durably. Clipping the delay and retrying early changes provider policy.],
      )
      #adr(5)
    ]
      #subsection(title: "Pool and process lifetimes are explicit")[
      #contract(name: "Shared PostgreSQL lifetime", mission: "Share one application database without merging recovery authorities.", answers: answers-data(
        responsibility: [Grind owns the pool it creates from caller configuration; application queries and the three PostgreSQL adapters borrow connections.],
        interface: [Public connection accessors and borrowed transaction APIs; each adapter's migration and storage constructor.],
        interactions: [Startup establishes schema compatibility before admitting work. Shutdown stops producers and dependent runtimes before releasing the pool.],
        invariants: [A borrowed transaction is not committed by an enqueue helper. Claim fencing and destination effect fencing are distinct. Renewal connection reservations count toward deployment capacity.],
        failure: [Lost commit acknowledgement requires receipt/reconciliation handling. Stopping the pool invalidates borrowers; a stopped caller may still require durable recovery.],
      ))
    ]
  ])

  #section(title: "Protocol, schema and authorization contracts", lead: "Protocol libraries validate wire meaning; applications decide domain meaning and trust. Schema and authentication reuse do not erase those responsibilities.", body: [
    #contract(name: "JSON contracts through an HTTP boundary", mission: "Decode untrusted bytes into native application values.", answers: answers-data(
      responsibility: [HTTP Gun bounds and classifies the exchange; Blueprint validates admitted JSON and the application codec.],
      interface: [A caller-owned HTTP client and record codec, with explicit response/parser bounds.],
      interactions: [HTTP status and incomplete-body failure are inspected before choosing whether a complete document is required.],
      invariants: [Schema validity, schema-profile support, codec decoding and business validation are separately identified. Exact-number refusal does not silently round a value.],
      failure: [An oversized response can retain a successful status while lacking a usable document; the application determines whether that suffices for its task.],
    ))
    #contract(name: "MCP tools through an agent", mission: "Use protocol-neutral execution with explicit discovery policy.", answers: answers-data(
      responsibility: [Relay owns declaration and exchange semantics; Blueprint owns schema admission; Fabric owns tool policy and durable execution.],
      interface: [Typed definitions or admitted dynamic declarations plus application-owned call/serve recipes.],
      interactions: [Recipes propagate correlation and idempotency metadata and map complete tool-result evidence into the execution outcome.],
      invariants: [Unsupported schemas fail visibly. A peer's read-only hint is not independent proof that a mutating effect is impossible.],
      failure: [Unknown delivery remains uncertain unless an application-approved property of the tool justifies a safer classification. Buffered hosting exposes only the lifecycle information its host supplies.],
    ))
    #contract(name: "Authentication around a protocol boundary", mission: "Separate token validity from application permission.", answers: answers-data(
      responsibility: [Warden validates issuer/token properties and owns custody; Relay enforces MCP resource admission; the application maps claims into a principal and business permissions.],
      interface: [Warden resource validation or introspection, Relay verifier/context ports, and Fabric approver proof construction.],
      interactions: [Local signature validation and introspection have different freshness/network costs. A verifier's deadline and captured resources remain explicit.],
      invariants: [A valid token does not grant every tool permission. Reviewer identity is derived from authenticated claims; only the configured verifier can authorize its approval proof.],
      failure: [Authentication refusal, insufficient permission and unavailable validation infrastructure remain distinguishable; no failure opens the protected boundary.],
    ))
    #behavior(title: "Protocol verification does not grant domain permission", area: "Authorization composition", level: "boundary")[
      #given[A caller presents a valid identity without the permission required by an operation.]
      #when[The caller requests the protected operation.]
      #then[The application refuses the operation without beginning its business effect.]
      #then[The refusal preserves the distinction between invalid identity and insufficient permission.]
    ]
    #adr(8)
    #contract(name: "Email verification and application identity", mission: "Compose delivery and proof of possession without importing account policy.", answers: answers-data(
      responsibility: [Correio owns message admission, delivery evidence and challenge consumption. The application owns trusted account lookup, current permission and session publication.],
      interface: [A typed sender, an explicitly configured challenge service, opaque verification evidence and an application-native principal mapping.],
      interactions: [A capture sender and optional mailbox handler share one caller-owned capture. Email verification and Warden OIDC identity remain distinct authentication methods in the application's principal.],
      invariants: [Accepted mail does not establish authentication. Inspecting a message does not consume its challenge. Only intentional confirmation and current account policy can produce an application session.],
      failure: [Unknown submission is not automatically resent. Confirmed verification survives a session-publication failure as application-owned evidence; retrying publication does not verify a consumed answer again.],
    ))
    #adr(17)
  ])

  #section(title: "Observation and diagnostic contracts", lead: "Observation joins work without controlling it. Applications decide which events to retain, export, and disclose.", body: [
    #contract(name: "Cross-package observation", mission: "Associate related work without importing a tracing runtime.", answers: answers-data(
      responsibility: [Sinal owns the correlation value and typed observation boundary; applications select and propagate it.],
      interface: [Explicit optional correlation on starts, client views and event metadata.],
      interactions: [Agent, tool, Saga, job and HTTP observations carry the same application correlation where they belong to the same operation.],
      invariants: [Correlation neither authorizes effects nor replaces durable identities. Native synchronous handlers can delay emitting work; bounded forwarding is an explicit ownership choice.],
      failure: [Observation loss or handler failure is diagnostic evidence, not proof that durable work failed or committed.],
    ))
    #points(
      [The application installs lifetime-scoped observers and routes. A process-local guess about attribution does not replace explicit propagation across asynchronous work.],
      [Diagnostic rendering excludes credentials and private application payloads unless the caller deliberately supplies a safe public projection. Typed evidence is retained before rendering.],
      [An exporter may map #term("term-observation-correlation") into a trace system. Exporter policy and parent/child span semantics remain outside the core correlation contract.],
    )
    #points([Retrace reconstructs selected application state from safe checkpoints and messages. It does not replace Sinal correlation or infer business completion. Applications own deterministic reducers, disclosure policy and build-compatible renderers; the frontend and server introduce no mandatory ecosystem runtime.])
    #adr(6)
  ])

  #section(title: "Composition applications", lead: "Each application is a separately compiled consumer with its own domain types, policies, startup, and shutdown. Scripted peers expose deterministic failure paths without production credentials.", body: [
    #entity(id: "composition-application", title: "Composition application", description: [One executable consumer demonstrating a complete application task across selected package authorities.], kind: "aggregate", owner: "Oversight", lifecycle: "stateful", domain: "composition", tint: "teal")[
      #attribute(name: "Scenario contract", type: "Named task and observable outcomes", provenance: "authored")[The ordinary task, advanced case, native values and failure cases the consumer establishes.]
      #attribute(name: "Package configuration", type: "Public typed configuration values", provenance: "authored")[The participating packages and policies chosen by the application.]
      #attribute(name: "Evidence", type: "Observed assertions and outcomes", provenance: "observed")[Results of actually executed scenarios, with toolchain and environment limits attached to the claim.]
      #relates(cardinality: "1 : n")[A composition application exercises multiple package authorities, each of which may participate in several applications.]
    ]
    #subsection(title: "Session replay")[
      #answers(title: "Application-owned cart reconstruction",
        responsibility: [Demonstrate portable recording and pure reconstruction without a browser, database or native shell.],
        interface: [The separate public consumer under `apps/session_replay` supplies Cart, Message and CartError types, a pure reducer, an explicit session contract and elapsed times.],
        interactions: [The application accepts positive additions/removals without a negative cart quantity, then records each accepted message. Retrace numbers entries and reconstructs state. The application may resume at a trusted checkpoint and append further accepted messages.],
        invariants: [Only accepted state transitions enter the stream. Replay runs the same pure reducer and performs no external effects. A failed step leaves the previous player available. An in-memory checkpoint is not proof of durable persistence.],
        failure: [Missing entries and incompatible contracts are refused explicitly. Invalid quantities and removal beyond the cart retain native domain errors; the application can replay a corrected contiguous sequence or start from a trusted later checkpoint.],
      )
      #behavior(title: "Accepted cart messages reconstruct the same state", area: "Session replay", level: "boundary")[
        #given[A safe initial cart and its accepted messages, or a trusted checkpoint and the accepted messages following it.]
        #when[The application reconstructs the contiguous stream with its matching contract and pure reducer.]
        #then[The reconstructed cart equals the application's recorded cart at the same cursor.]
      ]
      #behavior(title: "Replay refusal preserves a recovery point", area: "Session replay", level: "boundary")[
        #given[A replay encounters a gap, incompatible contract or a message refused by the cart reducer.]
        #when[The consumer attempts reconstruction.]
        #then[It receives a typed failure without advancing the previous player, so it can retry from that recovery point with valid input.]
      ]
      #points([This consumer establishes core behavior only. Retrace owns the maintained basic browser and advanced Tauri examples and their separate UI, delivery and storage evidence.])
      #adr(16)
    ]
    #subsection(title: "Checkout")[
      #answers(title: "Checkout authority and recovery",
        responsibility: [Accept orders, reserve stock, charge payment, book shipment and enqueue receipts.],
        interface: [Order placement and lookup; local execution and a durable-job mode with native order/receipt/error codecs.],
        interactions: [Saga orders effects and undo; HTTP Gun calls scripted payment/shipping peers; Grind delivers durable runs and receipts; saga_postgres and application rows use the shared pool.],
        invariants: [Order insertion and durable-job admission share one application transaction. Confirmation and receipt admission share a transaction. Stable destination keys and explicit unknown_when policy preserve payment uncertainty.],
        failure: [Known failures compensate in reverse completion order. Lost driver ownership permits checkpoint resumption; requested job cancellation is translated into durable Saga cancellation and rollback.],
      )
      #points([The application owns payment/shipment reconciliation and release policy. A job retry alone cannot decide whether stock or money should be restored.], [Source owners: `apps/checkout/src/checkout/workflow.gleam`, `orders.gleam`, `jobs.gleam`, `gateway.gleam`, and `db.gleam`.])
    ]
    #subsection(title: "Financial recovery")[
      #answers(title: "Payment evidence across independent durable records",
        responsibility: [Retain application financial intent, reservations, payment evidence and local postings while coordinating recoverable execution and job delivery.],
        interface: [A separate public consumer under `apps/financial_recovery`, with native operation identifiers, payment requests, outcomes and errors. Its test entry runs against disposable PostgreSQL and a scripted loopback payment provider.],
        interactions: [The payment record owns financial facts. Saga owns the step checkpoint and interrupted-effect resolver. Grind owns delivery and attributed replay authorization. HTTP Gun supplies exchange evidence without inferring provider execution.],
        invariants: [A stable business operation identity survives job and receipt pruning. Reservation remains held while the payment result is unknown. Accepted evidence and local posting are idempotent by business identity. Re-entering a completed operation does not send another payment or post again.],
        failure: [A lost response or unavailable lookup leaves an unresolved payment. An interrupted Saga action uses its resolver before another effect is permitted. A completed unresolved Saga outcome is retained as such; coordinator replay does not turn it into an interrupted action.],
      )
      #md-table(4, (
        [*Record*], [*Owner*], [*Stable identity*], [*Authority*],
        [Payment operation], [Application], [Business operation identifier], [Intent, reservation, evidence and posting],
        [Workflow execution], [Saga], [Run and effect identifiers], [Admitted actions, checkpoints and interrupted-step recovery],
        [Delivery], [Grind], [Submission, job and attempt identifiers], [Scheduling, acknowledged outcome and attributed resolution],
      ))
      #points(
        [The consumer uses one application-configured Grind pool; application queries and saga_postgres borrow it. Startup applies all required schemas before admitting jobs. Shutdown stops drivers and borrowers before the pool.],
        [READ COMMITTED admission locks known account rows in a deterministic order and atomically records financial intent, reservation and job insertion. The example states the protected account invariant; this locking protocol is not a universal replacement for SERIALIZABLE isolation.],
        [A caller retaining SERIALIZABLE isolation receives Grind's typed refusal for `submit_in`. An application outbox can atomically record dispatch intent with its business transaction and submit separately under a stable operation key. It requires explicit dispatch, retry and retention ownership rather than an implied atomic cross-transaction enqueue.],
        [An audited AuthorizeReplay command permits another coordinator delivery only where cancellation policy allows it. The coordinator resumes the same durable execution and resolves interrupted effects from authoritative evidence; the authorization does not itself permit another payment request.],
        [A provider lookup must distinguish confirmed completion, authoritative non-execution and insufficient evidence. An unavailable lookup or a non-authoritative absence does not release a reservation or authorize another external effect.],
        [A local posting transaction and the later Saga checkpoint remain separate commits even when they use the same database. The posting record supplies recovery evidence; the consumer does not add a second Saga storage protocol.],
        [For a finished Unresolved execution, application reconciliation binds the retained coordinator job and validates its native input against financial intent. Positive provider evidence permits one transaction to record the evidence, posting and attributed reconciliation decision. Unavailable, absent, malformed or conflicting evidence cannot release the reservation. The current provider contract supplies no authoritative non-execution proof.],
        [The coordinator's business obligation is a confirmed payment and local posting. After the application settlement commits, attributed Grind confirmation records that obligation's fulfillment without changing the original Saga report. Cancellation does not prevent recording an executed payment; reconciliation never initiates another payment or a refund.],
        [A reconciliation identity binds one job, operation, actor, reason and accepted reference. Exact retries reuse the committed decision without another lookup. Pending application records permit bounded discovery with a decision-identity cursor and resumption by decision identity; the caller owns authorization, scheduling and retention. A blocked record does not hide later records, and no recovery service starts implicitly.],
        [After financial settlement, queue confirmation and its local acknowledgment share one short caller-owned READ COMMITTED transaction through Grind's borrowed resolution API. A failed local acknowledgment rolls back queue resolution; a committed acknowledgment survives queue pruning under application retention. A lost outer commit reply requires application readback or resumption by the same decision identity. Investigation remains outside this transaction, whose locks last until commit or rollback. Existing missing history and separate operator resolutions remain explicit errors; neither creates another delivery or fabricates acknowledgment. See #adr(12).],
        [The scripted provider owns independent payment evidence and submission counts. Process barriers expose effect/checkpoint gaps. Loopback lost-response evidence establishes HTTP delivery behavior, not TLS or live-provider qualification.],
      )
      #behavior(title: "Financial admission commits with delivery", area: "Financial recovery", level: "boundary")[
        #given[An application admits a payment operation inside a supported transaction.]
        #when[The transaction commits or rolls back after job insertion.]
        #then[Financial intent, reservation and job admission become visible together or remain absent together.]
        #then[An incompatible reuse of the business identity is refused without another reservation.]
        #then[Competing admissions over the same locked accounts cannot reserve more than their available balance; refusal leaves no partial operation or delivery.]
      ]
      #behavior(title: "Payment execution checks application intent", area: "Financial recovery", level: "boundary")[
        #given[A caller invokes the coordinator through Saga or Grind.]
        #when[The transfer effect checks the application's payment record.]
        #then[Missing or incompatible intent prevents a provider submission.]
        #then[Retained completion evidence supplies the known result without another provider submission.]
      ]
      #behavior(title: "Interrupted payment recovery preserves uncertainty", area: "Financial recovery", level: "boundary")[
        #given[A payment action is interrupted after the provider may have executed it and before Saga checkpoints its result.]
        #when[The replacement coordinator cannot obtain authoritative provider evidence.]
        #then[Saga recovery remains suspended and Grind exposes an uncertain job outcome.]
        #then[The application retains the reservation and does not submit another payment.]
      ]
      #behavior(title: "Authorized delivery resolves before another effect", area: "Financial recovery", level: "boundary")[
        #given[An interrupted payment has authoritative completion evidence and no pending cancellation.]
        #when[An attributed resolution authorizes delivery of its coordinator again.]
        #then[The same Saga execution resolves the interrupted action and the application posts the known payment once.]
        #then[Repeated evidence or completed-operation re-entry does not send another payment or create another posting.]
      ]
      #behavior(title: "Local posting survives a missing checkpoint", area: "Financial recovery", level: "boundary")[
        #given[The posting transaction commits before Saga checkpoints step completion.]
        #when[The executing process dies and another coordinator recovers the same operation.]
        #then[The resolver discovers the committed posting and supplies its result.]
        #then[The posting callback is not repeated.]
      ]
      #behavior(title: "Cancellation preserves financial uncertainty", area: "Financial recovery", level: "boundary")[
        #given[A payment effect is unresolved.]
        #when[Cancellation and its uncertain worker acknowledgement arrive in either order.]
        #then[The job's uncertainty and evidence remain queryable and its cancellation intent prevents replay authorization.]
        #then[The application retains its reservation until explicit financial reconciliation settles the operation.]
      ]
      #behavior(title: "Business identity outlives queue retention", area: "Financial recovery", level: "boundary")[
        #given[A payment operation and posting are complete and the old terminal job and its receipts have been pruned.]
        #when[The application receives the same business operation again.]
        #then[The application returns its retained result without another payment or posting.]
      ]
      #behavior(title: "Finished uncertainty admits application settlement", area: "Financial recovery", level: "boundary")[
        #given[A coordinator job is uncertain and its Saga has a saved Unresolved report.]
        #when[An authorized application reconciliation obtains authoritative payment completion evidence.]
        #then[Evidence, one local posting and an attributed decision commit together before delivery is reported as confirmed.]
        #then[The original Saga report remains unchanged; repeated or concurrent identical decisions cannot post or submit the payment again.]
        #then[A missing, malformed or conflicting confirmation leaves the reservation held. A posting failure rolls back the application settlement and cannot produce a confirmed delivery outcome.]
      ]
      #behavior(title: "Reconciliation resumes between independent commits", area: "Financial recovery", level: "boundary")[
        #given[An application settlement committed before the reconciler process stopped.]
        #when[The caller discovers the pending decision and resumes it.]
        #then[The retained decision supplies the exact attributed delivery resolution without another provider lookup or financial effect.]
        #then[Delivery resolution and the local acknowledgment become durable together; rollback preserves the pending decision and uncertain delivery.]
        #then[An already committed acknowledgment remains readable after delivery pruning.]
        #then[Missing delivery history retains an explicit pending acknowledgment and the settled financial facts.]
      ]
      #behavior(title: "The application retains its isolation choice", area: "Financial recovery", level: "boundary")[
        #given[The application supplies a SERIALIZABLE transaction to Grind admission.]
        #when[The consumer attempts `submit_in`.]
        #then[The typed unsupported-isolation result is preserved and the application transaction is not silently weakened.]
      ]
      #adr(10) #adr(11)
    ]
    #subsection(title: "Webhook delivery")[
      #answers(title: "Webhook delivery policy",
        responsibility: [Fan application events out to active tenant subscriptions as signed durable deliveries.],
        interface: [Subscription/event operations and a contextual Grind worker with a stable delivery identity.],
        interactions: [Application rows and enqueue share a transaction. HTTP Gun applies per-tenant destination views; Grind executes explicit retry/snooze/discard policy.],
        invariants: [The same delivery id signs and identifies every retry. Registration and delivery use destination policy; delivery re-reads subscription configuration so disablement and key rotation are effective.],
        failure: [Successful status can settle delivery despite an oversized unused body. Rate limits snooze within the cap; gone/unsafe destinations disable subscriptions; retryable transport/server failures consume bounded attempts.],
      )
      Source owners: `apps/webhooks/src/webhooks/attempt.gleam`, `delivery.gleam`, `subscription.gleam`, `egress.gleam`, and `web.gleam`.
    ]
      #subsection(title: "Document extraction")[
      #answers(title: "Typed document extraction",
        responsibility: [Fetch bounded documents, obtain a typed invoice from a provider and persist the result.],
        interface: [Batch job submission and native Invoice/LineItem/Currency values with semantic validation.],
        interactions: [Separate HTTP clients carry document and provider policies. LLM Wire uses one Blueprint codec for structured output; small adapters reuse the codec for Grind and database values.],
        invariants: [Document content, declared length and collected bytes are bounded before model input. Unsupported content and invalid invoices do not become successful stored outputs.],
        failure: [The application translates fetch, provider, validation and storage failures into retry, snooze or discard. Provider advice does not directly own job policy.],
      )
      Source owners: `apps/extractor/src/extractor/invoice.gleam`, `document.gleam`, `llm.gleam`, `outcome.gleam`, and `jobs.gleam`.
    ]
    #subsection(title: "Support desk")[
      #answers(title: "Approved compensating refunds",
        responsibility: [Run a support agent whose refunds require an authorized approval and a compensating workflow.],
        interface: [Ticket/run operations, typed tools, typed Resolution, and approve/reject commands carrying checked proof.],
        interactions: [Fabric owns agent state and approval; Warden checks approver identity; Saga performs refund/ledger/notification; the consumer recipe retains full reports before mapping them.],
        invariants: [The proof comes from the configured verifier and required scope. Ticket correlation reaches model, tool, Saga and HTTP calls. Reopening a ticket converges on its run.],
        failure: [Unauthenticated, unauthorized and unavailable-verifier outcomes are separate. Unknown payment effects require reconciliation; failed notification triggers the workflow's compensation policy.],
      )
      Source owners: `apps/support_desk/src/support_desk/desk.gleam`, `approvers.gleam`, `refund.gleam`, `domain.gleam`, and the local Saga recipe.
    ]
      #subsection(title: "Tool hub")[
      #answers(title: "MCP in both directions",
        responsibility: [Let an agent call discovered MCP tools and expose agent execution as an MCP tool.],
        interface: [Relay declarations/calls, admitted dynamic contracts, Fabric invocation, and application recipes.],
        interactions: [The application starts the inventory peer it discovers. Relay carries idempotency/correlation metadata; Fabric owns durable keyed invocation.],
        invariants: [Dynamic schema rejection is explicit. The local peer's trusted read-only declaration is an application precondition, not a trust rule for arbitrary external peers.],
        failure: [Keyed disconnect can leave durable work inspectable; unkeyed cancellation stops its owned invocation. Tool failure and uncertain delivery remain separate from a completed protocol exchange.],
      )
      Source owners: `apps/tool_hub/src/tool_hub.gleam`, `relay_discovery.gleam`, `relay_run.gleam` and `relay_serve.gleam`, and `relay_tools.gleam`.
    ]
    #subsection(title: "Protected MCP service")[
      #answers(title: "Authenticated tools and durable reports",
        responsibility: [Serve MCP tools for authenticated principals and delegate long report work to jobs.],
        interface: [Browser login, bearer-checked MCP requests and report submission/readback through public app routes.],
        interactions: [Warden supplies token validation/introspection; Relay owns protected-resource admission; the app derives principal and tenant policy; Grind owns report delivery.],
        invariants: [Token issuer/audience/scope checks precede tool business effects. Application ownership of report data remains distinct from a valid token.],
        failure: [Missing permission is a refusal, not a provider outage; unavailable verification does not admit the request. Job failures remain typed at readback.],
      )
      Source owners: `apps/secure_mcp/src/secure_mcp/auth.gleam`, `tools.gleam`, `reports.gleam`, and `web.gleam`.
    ]
    #subsection(title: "Email portal")[
      #answers(title: "Delivery, inspection and application sessions",
        responsibility: [Retain a complete email sign-in recipe under apps/email_portal using public Correio contracts.],
        interface: [Application-native account and session types, explicit challenge request and confirmation operations, capture checkpoints and the standard Gleam HTTP mailbox handler.],
        interactions: [Correio's memory store owns atomic challenge state. Capture retains local mail. The application owns both runtimes, its account policy, pending verification evidence and idempotent session publication.],
        invariants: [The mailbox route is explicitly configured for development. Pending values and confirmed evidence are not application sessions. A disabled or changed account cannot receive a session. Repeated publication of one verification identity returns the same session.],
        failure: [Delivery refusal, unknown delivery, invalid confirmation and failed publication remain distinct application outcomes. Publication recovery uses retained evidence and rechecks current account policy.],
      )
      #points([The ordinary flow takes a checkpoint, requests delivery, inspects the resulting message through the mailbox handler, explicitly confirms its secret and reads the application session. Advanced use configures a different mount path and challenge policy with email codes.], [Tests exercise separate consumer compilation, actual capture and memory runtimes, and in-process HTTP handler requests. They do not claim browser navigation, network transport, durable session storage or production authentication policy. Correio owns its separate browser, transport, database and upstream-oracle evidence.], [Detailed library design remains in the Correio repository. Oversight owns this composition and its scenario assertions. #adr(17)])
      #behavior(title: "Mailbox inspection grants no session", area: "Email portal", level: "boundary")[#given[A sign-in request has delivered a challenge into the development capture.] #when[The application inspects the mailbox and message.] #then[The challenge remains available for intentional confirmation.] #then[No application session exists before successful confirmation.]]
      #behavior(title: "Session publication recovers confirmed verification", area: "Email portal", level: "boundary")[#given[Challenge consumption has succeeded but application session publication failed.] #when[The application retries publication with the retained verification evidence.] #then[Current account policy is checked again.] #then[Publication creates or recovers one session without a second challenge consumption.]]
    ]
    #subsection(title: "SSO portal")[
      #answers(title: "Durable login custody in a web application",
        responsibility: [Maintain browser sessions and call a protected billing resource with recoverable token custody.],
        interface: [Login/callback/logout routes, application session cookie, and native principal/account views.],
        interactions: [Warden owns transactions and token custody; the application implements Warden's conditional sealed-record writes on PostgreSQL and separately manages its browser session. HTTP Gun performs resource calls.],
        invariants: [The application does not implement a second refresh state machine. Custody records and browser session references have separate owners and lifetimes. Guarded consumption checks version and database wall time under row ownership after lock waiting; validity and storage retention remain separate.],
        failure: [The application may refresh once after a resource refusal and recover uncertain publication once, then maps Warden's typed action to user-visible decisions. Storage uncertainty is not treated as definite non-action.],
      )
      Source owners: `apps/sso_portal/src/sso_portal/warden_records.gleam`, `session_store.gleam`, `web.gleam`, and `billing_api.gleam`.
    ]
    #subsection(title: "Durable research and publication")[
      #answers(title: "Independent delivery, conversation and publication",
        responsibility: [Resume research across restarts and publish its result through a compensating workflow.],
        interface: [A Grind worker starts or resumes a Fabric agent with search/read tools, then drives a durable Saga publication workflow.],
        interactions: [Fabric persists conversation and tool results; Grind schedules delivery; Saga owns publication effects; their PostgreSQL adapters share application resources.],
        invariants: [A fresh driver resumes durable state rather than replaying an arbitrary closure. Read-only tool replay is explicit. Publication keys and provider readback settle external effects.],
        failure: [Transient driver/store conflicts snooze; domain failures follow application retry policy; unresolved publication becomes Uncertain. Unexpected approvals fail explicitly. Cancellation reaches the agent/model and publication workflow without proving that every external effect was undone.],
      )
      Source owners: `apps/research_agent/src/research_agent/jobs.gleam`, `publish.gleam`, `researcher.gleam`, `node.gleam`, and `wire.gleam`.
      #answers(title: "History-aware turn delivery",
        responsibility: [Demonstrate application-owned turn data across durable admission, Fabric execution and outcome incorporation.],
        interface: [A separate public consumer in the research application uses Grind transactional admission, Fabric history-aware keyed invocation, the leased PostgreSQL store and its registered recovery sweeper.],
        interactions: [The application transaction records a turn and its delivery together. Delivery supplies validated history and the current prompt to Fabric. The sweeper resumes admitted execution after process loss; an idempotent application transaction incorporates the native answer and generated messages.],
        invariants: [The stable principal and turn key identify execution; correlation and live context do not replace that identity. Retain the outcome until incorporation commits. A durable applied marker prevents a later delivery from reinvoking an incorporated turn after Fabric pruning.],
        failure: [Working, suspension, uncertain execution, ended failure and refusal retain distinct application decisions. Lost incorporation acknowledgement requires readback or the same idempotent transaction. A shared connection proves no atomicity between the application transaction and Fabric's initial record.],
      )
      #points(
        [This consumer uses existing Grind delivery and Fabric recovery. It adds no application lease renewal, abandoned-run scanner or competing generic queue.],
        [A per-turn application graph may instead own incorporation as a declared operation with explicit idempotency and interrupted-effect recovery. It still needs the transactional admission bridge and does not imply a new PostgreSQL admission API.],
        [Deterministic model callbacks and disposable PostgreSQL establish public composition and tested process-loss behavior. They establish no live-provider or power-loss guarantee.],
      )
      #behavior(title: "Applied turns survive execution record pruning", area: "Durable research", level: "boundary")[
        #given[The application has incorporated an agent outcome and retained its applied marker.]
        #when[Delivery repeats after Fabric's settled run record is pruned.]
        #then[The application returns the incorporated result without starting another agent run.]
      ]
      #adr(13)
    ]
  ])

  #section(title: "Experiments and acceptance evidence", lead: "Retained prototypes answer narrow questions and remain separate from production libraries. Evidence is reproducible only when its inputs, oracle and execution boundary are explicit.", body: [
    #answers(title: "Interface laboratory",
      responsibility: [Explore typed public contracts and failure boundaries without presenting prototypes as production implementations.],
      interface: [Positive/negative compiler cases, pure transition models, scripted peers and selected oracle comparisons under `playground/interface_lab`.],
      interactions: [Experiments inform package-owned designs and ADRs; accepted capabilities require implementation and separate-consumer evidence in the owning repository.],
      invariants: [Compiler success proves expressibility, not crash recovery or operational bounds. A pinned protocol snapshot retains its license and provenance.],
      failure: [An incomplete experiment leaves its capability unproven; a stub, expected failure or skipped check is not counted as a working runtime.],
    )
    #md-table(3, (
      [*Retained system part*], [*Question it answers*], [*Limits of the evidence*],
      [`playground/relay_admission`], [Do admission callbacks share the request deadline, and what changes when their process owner changes?], [Barrier-driven public consumers check callback deadlines, disconnects, retiring capacity, shared budgets, shutdown, panic isolation and borrowed resources. Native process probes do not establish arbitrary resource cleanup or streaming lifecycle conformance.],
      [`playground/interface_lab`], [Can proposed native types, ownership states and protocol boundaries be expressed and distinguished?], [Prototype behavior does not establish production lifecycle conformance.],
      [`playground/blueprint_compatibility`], [How do codec/schema cases compare with the pinned implementation and validator?], [Only executed supported-vocabulary cases establish equivalence.],
      [`playground/ecosystem_pilot`], [Can protocol declarations, model calls and typed observations compose through public imports?], [A pilot does not replace each package's fault and resource tests.],
      [`playground/http_gun_interface`], [Can transport ownership and provider-neutral use fit separate consumers?], [Laboratory signatures are not retained public API promises.],
      [`playground/archive_release`], [Can authenticated admission and durable approval bind release to its requester, revision and current permission?], [Direct authorization admission and orderly store reopen do not establish full MCP transport or mid-effect crash recovery.],
      [`playground/instrument_replay`], [Can bounded recorded transport support offline evaluation under different application contracts?], [Synthetic measurements and local faults do not qualify a scientific instrument or remote service.],
      [`playground/erasure_campaign`], [Can reversible preparation compose with irreversible delivery and forward reconciliation?], [Application evidence, synthetic targets and local restarts do not establish legal erasure or host-loss guarantees.],
      [`playground/fabric_record_compatibility`], [Does a separately pinned earlier Fabric reader refuse the new history record envelope?], [Two public consumers preserve exact writer inputs and reader revision; incompatible-reader refusal does not establish every older release or backend fault case.],
      [`apps/scripts/with-postgres.sh`], [Can a consumer exercise real persistence in an isolated reproducible cluster?], [No production database, remote provider or existing deployment is validated.],
    ))
    #behavior(title: "A consumer proves only executed behavior", area: "Evidence acceptance", level: "boundary")[
      #given[A consumer compiles but its persistence or external-effect scenario is skipped.]
      #when[Its result is used to assess a package contract.]
      #then[The evidence is limited to compilation and the scenarios actually executed.]
      #then[The unexecuted operational guarantee remains unverified.]
    ]
    #points(
      [A #term("term-behavioral-oracle") names its version, license, relevant behavior and comparison limits. Native telemetry, JSON Schema, Gun/Cowlib, Reactor, Oban and protocol authorities are scoped evidence rather than automatic parity claims.],
      [Open-source Oban behavior and commercial Pro behavior require separate contracts and lawful evidence. Certification of an upstream identity library does not certify its wrapper.],
      [Deterministic barriers expose races and ownership; sleeps alone do not establish event ordering. Real database tests complement pure transition tests.],
      [The authored behavior areas are public facade, extension admission, effect translation, durable identity, budget/lifetime, authorization, observation and evidence acceptance. Each application adds its domain-specific cases in its executable tests.],
    )
    #adr(9)
  ])

  #section(title: "Design maintenance and rendering", lead: "Repository-local design sources are the present contract. The pinned renderer checks structure and references while semantic review checks the contract against the system.", body: [
    #answers(title: "Documentation authority",
      responsibility: [Keep package-local design, canonical terminology and decision rationale discoverable without duplicate planning authorities.],
      interface: [Typst design/glossary, Markdown ADRs and coverage map, one generated layer PDF, forwarded Nix render/check/context apps.],
      interactions: [README and AGENTS point to the local layer. Oversight links package owners and records ecosystem-wide decisions; operational guides link the relevant design rather than restating it.],
      invariants: [The design is timeless. ADR rationale is evidence-backed; missing historical context is explicit. The rendered document is generated, never edited directly.],
      failure: [A stale rendering or broken semantic reference fails the design gate. A green gate does not prove implementation conformance or correct design.],
    )
    #points(
      [Coverage classifies actual repository parts as captured, standard, or out-of-scope. A deleted component does not survive as an invented coverage row.],
      [Source/behavior changes require reviewing affected contracts, examples, callers and stored data. API similarity alone is not a reason to impose an ecosystem-wide migration.],
      [Current gaps remain in the owning native pending ledger. ADRs explain decisions and alternatives; they do not replace the standing design.],
      [Package and nested-adapter gates use the same pinned schema/renderer bundle. Nested adapter layers are checked through the parent's declared nested-project path.],
    )
    #adr(1)
  ])
]
