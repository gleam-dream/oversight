#import "../.render/designlib.typ": *

#let title = [Composition contracts]
#let accent = "teal"

#let body = [
  #section(title: "Foundation", lead: "Composition contracts state who owns each resource, decision and fact when independent libraries meet in one application.", body: [
    #goal(title: "Make ownership and failures inspectable")[A consumer can determine who configures, starts, cancels, persists, reconciles, and releases each resource. Failures preserve the facts needed for a meaningful next decision.]
    #invariant(title: "Composition preserves known effect evidence", enforcement: "partial")[A #term("term-composition-boundary") must not infer completed, prevented, or compensated work solely from cancellation intent, transport delivery, or loss of a reply. Unresolved implementation conflicts remain explicit gaps.]
    #principle(title: "Domain types and policy belong to callers", lens: "modeling")[Applications supply native records and policy. Libraries require nominal types only when those types carry useful admission, identity, or ownership guarantees.]
    #principle(title: "Bound work where it is owned", lens: "robustness")[Limits state the work they bound and the party that enforces them. Bounded queues, finite waits, cancellation, and cleanup are separate guarantees.]
    The caller-value and extension rules are justified by #adr(2) and #adr(7); the bounding rules by #adr(5).
  ])

  #pending-ledger(
    pending-entry(title: "A composed request budget needs explicit cleanup", kind: "ruling", since: "2026-10-06")[Relay owns one admitted request deadline and a separate bounded cleanup interval; its package design owns implementation acceptance. Saga driver timeout is followed by bounded synchronous cleanup. A composed foreground deadline must reserve admission, execution, cancellation grace, and cleanup rather than assigning the same duration to every phase.],
    pending-entry(title: "External schema breadth must be explicit", kind: "ruling", since: "2026-10-06")[Blueprint admits a finite runtime schema profile. General third-party MCP discovery requires a chosen supported vocabulary, bounded validation, and safe provider projection; sibling-to-sibling discovery alone does not establish that breadth.],
    pending-entry(title: "Durable scheduling integration remains application-owned", kind: "ruling", since: "2026-10-06")[Applications drive and cancel durable Saga and Fabric work through Grind jobs. The intended broader scheduling and retention integration requires a decision about authority before any common driver abstraction is introduced. See #adr(4).],
    pending-entry(title: "Carried-over caller contracts are unchecked against code", kind: "verify", since: "2026-10-17")[The caller-contract, execution-boundary, protocol and observation sections state rules moved from retired Oversight guides. Each rule needs a comparison against the owning package source before the section counts as verified.],
  )

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
]
