#import "../.render/designlib.typ": *

#let title = [Composition applications]
#let accent = "violet"

#let body = [
  #section(title: "Foundation", lead: "Each application is a separately compiled consumer that completes one task across several package authorities, using its own domain types, policies, startup and shutdown.", body: [
    #goal(title: "Complete real tasks through public contracts")[An application performs an ordinary task, an advanced configuration, native-value handling and a failure recovery using only public package modules.]
    #goal(title: "Expose recovery paths without credentials")[A #term("term-scripted-peer") and a disposable database reproduce lost replies, refusals, process loss and cancellation locally, so recovery behavior is executable without provider accounts.]
    #no-goal(title: "A production deployment template")[An application demonstrates a composition. It is not a complete ledger, account system, session transport, accounting specification or compliance assessment.]
    #invariant(title: "Application records own application facts", enforcement: "convention")[Payment, order, session and release facts live in application-owned records. Library records establish delivery, workflow or conversation state and never replace them.]
    #principle(title: "A recipe translates and never extends a contract", lens: "composition")[A #term("term-consumer-recipe") maps one package's public result into another's input. It adds no state machine, retry engine or bridge dependency of its own.]
    The application set and its package boundaries are recorded in #adr(3), #adr(10), #adr(13), #adr(16), #adr(17) and #adr(18).
  ])

  #pending-ledger(
    pending-entry(title: "Provider contract lacks proof of non-execution", kind: "ruling", since: "2026-10-07")[Releasing an unconfirmed payment reservation needs a provider contract that excludes late execution. The scripted provider supplies lookup evidence only for completed payments, so an unavailable lookup or an absence never releases a reservation. See #adr(11).],
    pending-entry(title: "Application invariants are unchecked against the apps", kind: "verify", since: "2026-10-17")[The invariants and behavior rules for the compiled applications were folded from retired application READMEs and feedback notes. Each needs a comparison against the application source and its tests before the section counts as verified.],
  )

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
        [READ COMMITTED admission locks known account rows in a deterministic order and atomically records financial intent, reservation and job insertion. The locking protocol protects the invariant that balance is at least reserved and reserved is not negative for those known rows; it does not cover arbitrary predicates, new account sets or writers that bypass the protocol, and it is not a universal replacement for SERIALIZABLE isolation. A second admission over a locked account waits, then is refused with an insufficient-funds failure that leaves no operation or job.],
        [A #term("term-business-identity") identifies one payment operation; Saga and queue identities derive from it. Reuse with changed intent is refused as an identity conflict, and admission of a completed operation returns the retained result before Saga or Grind is consulted. The provider lookup encodes the identity as one path segment while records and the idempotency header keep it unchanged. An unconfirmed outer transaction preserves uncertainty: the caller reads the application record or retries admission under the same identity and never generates a replacement.],
        [The coordinator holds every non-completed Saga outcome for inspection, so a held job may carry a known refused effect as well as an unknown effect. The retained Saga outcome is inspected before an operator decision is chosen.],
        [A caller retaining SERIALIZABLE isolation receives Grind's typed refusal for `submit_in`. An application outbox can atomically record dispatch intent with its business transaction and submit separately under a stable operation key. It requires explicit dispatch, retry and retention ownership rather than an implied atomic cross-transaction enqueue.],
        [An audited AuthorizeReplay command permits another coordinator delivery only where cancellation policy allows it. The coordinator resumes the same durable execution and resolves interrupted effects from authoritative evidence; the authorization does not itself permit another payment request.],
        [A provider lookup must distinguish confirmed completion, authoritative non-execution and insufficient evidence. An unavailable lookup or a non-authoritative absence does not release a reservation or authorize another external effect.],
        [A local posting transaction and the later Saga checkpoint remain separate commits even when they use the same database. The posting record supplies recovery evidence; the consumer does not add a second Saga storage protocol.],
        [For a finished Unresolved execution, application reconciliation binds the retained coordinator job and validates its native input against financial intent. Positive provider evidence permits one transaction to record the evidence, posting and attributed reconciliation decision. Unavailable, absent, malformed or conflicting evidence cannot release the reservation. The provider contract supplies no authoritative non-execution proof.],
        [The coordinator's business obligation is a confirmed payment and local posting. After the application settlement commits, attributed Grind confirmation records that obligation's fulfillment without changing the original Saga report. Cancellation does not prevent recording an executed payment; reconciliation never initiates another payment or a refund.],
        [A #term("term-reconciliation-decision") binds one job, operation, actor, reason and accepted reference under one decision identity. Exact retries reuse the committed decision without another lookup. Pending application records permit bounded discovery with a decision-identity cursor and resumption by decision identity; the caller owns authorization, scheduling and retention. A blocked record does not hide later records, and no recovery service starts implicitly.],
        [After financial settlement, queue confirmation and its local acknowledgment share one short caller-owned READ COMMITTED transaction through Grind's borrowed resolution API. A failed local acknowledgment rolls back queue resolution; a committed acknowledgment survives queue pruning under application retention. A lost outer commit reply requires application readback or resumption by the same decision identity. Investigation remains outside this transaction, whose locks last until commit or rollback. Missing queue history and separate operator resolutions remain explicit errors; neither creates another delivery or fabricates acknowledgment. See #adr(12).],
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
      #points(
        [Destination policy is per tenant tier on one HTTP client. A public tenant reaches public addresses only and every DNS answer is checked; the internal tier reaches allowlisted loopback host entries. Registration applies the same policy value, so a refused address is rejected before any delivery.],
        [A response body beyond the read limit keeps its success status, so delivery settles once. A rate-limit response snoozes for the advised interval up to a configured cap and then consumes an attempt.],
        [Worker tests replay recorded refusals and body-limit failures from cassettes without a receiver, and a request that skips the tenant's client view is refused before sending.],
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
        interactions: [Fabric owns agent state and approval; Hellhound checks approver identity; Saga performs refund/ledger/notification; the consumer recipe retains full reports before mapping them.],
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
        interactions: [Hellhound supplies token validation/introspection; Relay owns protected-resource admission; the app derives principal and tenant policy; Grind owns report delivery.],
        invariants: [Token issuer/audience/scope checks precede tool business effects. Application ownership of report data remains distinct from a valid token.],
        failure: [Missing permission is a refusal, not a provider outage; unavailable verification does not admit the request. Job failures remain typed at readback.],
      )
      #points(
        [The login asks for the resource of the MCP endpoint, and the provider issues access tokens whose audience is that endpoint. Local validation checks signature, type, issuer, audience and expiry; introspection is an alternative mode that also reaches the provider. A revoked token that local validation accepts is an explicit limit of local mode.],
        [A job owned by another user answers exactly like a missing job.],
      )
      Source owners: `apps/secure_mcp/src/secure_mcp/auth.gleam`, `tools.gleam`, `reports.gleam`, and `web.gleam`.
    ]
    #subsection(title: "Email portal")[
      #answers(title: "Delivery, inspection and application sessions",
        responsibility: [Retain a complete email sign-in recipe under apps/email_portal using public Correio contracts.],
        interface: [Application-native account and session types, explicit challenge request and confirmation operations, capture checkpoints and the standard Gleam HTTP mailbox handler.],
        interactions: [Correio's memory store owns atomic challenge state. Capture retains local mail. The application owns both runtimes, its account policy, pending verification evidence and idempotent #term("term-session-publication").],
        invariants: [The mailbox route is explicitly configured for development. Pending values and confirmed evidence are not application sessions. A disabled or changed account cannot receive a session. Repeated publication of one verification identity returns the same session.],
        failure: [Delivery refusal, unknown delivery, invalid confirmation and failed publication remain distinct application outcomes. Publication recovery uses retained evidence and rechecks current account policy.],
      )
      #points([The ordinary flow takes a checkpoint, requests delivery, inspects the resulting message through the mailbox handler, explicitly confirms its secret and reads the application session. Advanced use configures a different mount path and challenge policy with email codes.], [Tests exercise separate consumer compilation, actual capture and memory runtimes, and in-process HTTP handler requests. They do not claim browser navigation, network transport, durable session storage or production authentication policy. Correio owns its separate browser, transport, database and upstream-oracle evidence.], [Detailed library design remains in the Correio repository. Oversight owns this composition and its scenario assertions. #adr(17)], [Session state in this application is local and sequential. A production publisher needs durable atomic idempotency and an application-owned session credential, and pending evidence belongs to this service context and is never accepted from untrusted clients or other application instances.])
      #behavior(title: "Mailbox inspection grants no session", area: "Email portal", level: "boundary")[#given[A sign-in request has delivered a challenge into the development capture.] #when[The application inspects the mailbox and message.] #then[The challenge remains available for intentional confirmation.] #then[No application session exists before successful confirmation.]]
      #behavior(title: "Session publication recovers confirmed verification", area: "Email portal", level: "boundary")[#given[Challenge consumption has succeeded but application session publication failed.] #when[The application retries publication with the retained verification evidence.] #then[Current account policy is checked again.] #then[Publication creates or recovers one session without a second challenge consumption.]]
    ]
    #subsection(title: "SSO portal")[
      #answers(title: "Durable login custody in a web application",
        responsibility: [Maintain browser sessions and call a protected billing resource with recoverable token custody.],
        interface: [Login/callback/logout routes, application session cookie, and native principal/account views.],
        interactions: [Hellhound owns transactions and token custody; the application implements Hellhound's conditional sealed-record writes on PostgreSQL and separately manages its browser session. HTTP Gun performs resource calls.],
        invariants: [The application does not implement a second refresh state machine. Custody records and browser session references have separate owners and lifetimes. Guarded consumption checks version and database wall time under row ownership after lock waiting; validity and storage retention remain separate.],
        failure: [The application may refresh once after a resource refusal and recover uncertain publication once, then maps Hellhound's typed action to user-visible decisions. Storage uncertainty is not treated as definite non-action. Listener startup refusal returns a recoverable error without terminating its caller. Listener shutdown and caller exit retire the owned Mist subtree.],
      )
      #points(
        [Hellhound's stored records are sealed with an application-held key and hold nothing readable. The PostgreSQL adapter implements Hellhound's explicit write conditions: a guarded write locks the row, checks its version and samples database time before updating, and a failed commit acknowledgement remains an unknown outcome.],
        [Web-tier restart waits for the owning actor to retire the previous listener subtree, allowing a bounded interval for child cleanup and failing explicitly on timeout.],
      )
      #behavior(title: "Listener startup refusal preserves its caller", area: "SSO portal", level: "boundary")[#given[Another listener already owns the requested address.] #when[The application attempts to start its listener.] #then[Startup returns an error without terminating the caller.] #then[The caller can start and stop a listener at an available address.]]
      #adr(18)
      Source owners: `apps/sso_portal/src/sso_portal/hellhound_records.gleam`, `session_store.gleam`, `web.gleam`, `billing_api.gleam`, and `server.gleam`.
    ]
    #subsection(title: "Durable research and publication")[
      #answers(title: "Independent delivery, conversation and publication",
        responsibility: [Resume research across restarts and publish its result through a compensating workflow.],
        interface: [A Grind worker starts or resumes a Fabric agent with search/read tools, then drives a durable Saga publication workflow.],
        interactions: [Fabric persists conversation and tool results; Grind schedules delivery; Saga owns publication effects; their PostgreSQL adapters share application resources.],
        invariants: [A fresh driver resumes durable state rather than replaying an arbitrary closure. Read-only tool replay is explicit. Publication keys and provider readback settle external effects.],
        failure: [Transient driver/store conflicts snooze; domain failures follow application retry policy; unresolved publication becomes Uncertain. Unexpected approvals fail explicitly. Cancellation reaches the agent/model and publication workflow without proving that every external effect was undone.],
      )
      #points(
        [A rejected publication is definite only when its draft-deletion undos succeed; a failed cleanup remains uncertain. Draft deletion is idempotent and accepts an already-deleted draft.],
        [On interruption, creation looks up its idempotency key. Upload and publication read the draft's committed state: an uploaded or live draft proves upload, and a live draft with its address proves publication. Missing, malformed or unavailable readback cannot exclude a late commit and never authorizes another mutation. The application requires this readback contract from its publisher; idempotence alone is not evidence that an earlier operation was never sent.],
        [Publication carries a step version and a versioned error codec. A checkpoint written under an earlier step version fails closed as incompatible, including a finished failure, because the earlier error lost effect evidence that its text cannot restore. Such records are reconciled from provider evidence before an operational migration; they are neither deleted nor relabeled as retryable.],
      )
      #adr(24)
      Source owners: `apps/research_agent/src/research_agent/jobs.gleam`, `publish.gleam`, `researcher.gleam`, `node.gleam`, and `wire.gleam`.
      #answers(title: "History-aware turn delivery",
        responsibility: [Demonstrate application-owned turn data across durable admission, Fabric execution and outcome incorporation.],
        interface: [A separate public consumer in the research application uses Grind transactional admission, Fabric history-aware keyed invocation, the leased PostgreSQL store and its registered recovery sweeper.],
        interactions: [The application transaction records a turn and its delivery together. Delivery supplies validated history and the current prompt to Fabric. The sweeper resumes admitted execution after process loss; an idempotent application transaction incorporates the native answer and generated messages.],
        invariants: [The stable principal and turn key identify execution; correlation and live context do not replace that identity. Retain the outcome until incorporation commits. A durable #term("term-applied-marker") prevents a later delivery from reinvoking an incorporated turn after Fabric pruning.],
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
]
