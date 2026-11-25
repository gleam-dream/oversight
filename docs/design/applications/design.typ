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
    The application set and its package boundaries are recorded in #adr(3), #adr(10), #adr(13), #adr(16), #adr(17), #adr(18) and #adr(33).
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
        interface: [Order placement and lookup for an authenticated customer; local execution and a durable-job mode with native order/receipt/error codecs. Every request carries a bearer token that the application's configured table resolves to one customer, or it is refused with 401. A placement carries a SKU, quantity, address and a payment token that the payment provider issued to the customer; it carries no amount and no card number, and a body with any other field is refused.],
        interactions: [Saga orders effects and undo; HTTP Gun calls scripted payment/shipping peers; Grind delivers durable runs and receipts; saga_postgres and application rows use the shared pool.],
        invariants: [The server prices every order from its catalog (unit price times quantity) before the saga starts; the charged amount never comes from the client. Grind job rows, Saga checkpoints and application rows hold the payment token, never a card number. An order belongs to the customer who placed it; another customer reads it as absent. The client's order id is that customer's own idempotency key, scoped to the customer: a repeated placement returns the existing order, and the same customer's reuse with a different SKU or quantity is refused as a conflict. Neither runs the saga again. Another customer's placement under the same id is a separate order with its own reservation, provider keys and jobs, so the answer never reveals whether the id is in use. Order insertion and durable-job admission share one application transaction. Confirmation and receipt admission share a transaction. Stable destination keys and explicit unknown_when policy preserve payment uncertainty.],
        failure: [Known failures compensate in reverse completion order. Lost driver ownership permits checkpoint resumption; requested job cancellation is translated into durable Saga cancellation and rollback. Response bodies carry a stable error code and a message built from order facts; driver and transport detail goes to the log.],
      )
      #points([Checkout's bearer table, configured through `app.Config`, stands in for a verified credential; the Protected MCP service shows token verification. The order API relies only on one authenticated customer id per request, resolved before the body is read.], [The application owns payment/shipment reconciliation and release policy. A job retry alone cannot decide whether stock or money should be restored.], [Source owners: `apps/checkout/src/checkout/workflow.gleam`, `orders.gleam`, `jobs.gleam`, `gateway.gleam`, `db.gleam`, `customers.gleam` and `web.gleam`.])
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
        interface: [Subscription/event operations authenticated by a per-tenant API key, and a contextual Grind worker with a stable delivery identity.],
        interactions: [Application rows and enqueue share a transaction. HTTP Gun applies per-tenant destination views; Grind executes explicit retry/snooze/discard policy.],
        invariants: [The caller's API key, never the request, names the tenant; registration, publishing and reads act for that tenant only. The same delivery id signs and identifies every retry and is the receiver's idempotency key. Registration and delivery use destination policy; delivery re-reads subscription configuration so disablement and key rotation are effective.],
        failure: [Successful status can settle delivery despite an oversized unused body. Rate limits snooze within the cap; gone/unsafe destinations disable subscriptions; retryable transport/server failures consume bounded attempts.],
      )
      #points(
        [Destination policy is per tenant tier on one HTTP client. A public tenant reaches public addresses only and every DNS answer is checked; the internal tier reaches allowlisted loopback host entries. Registration applies the same policy value, so a refused address is rejected before any delivery.],
        [A response body beyond the read limit keeps its success status, so delivery settles once. A rate-limit response snoozes for the advised interval up to a configured cap and then consumes an attempt.],
        [Worker tests replay recorded refusals and body-limit failures from cassettes without a receiver, and a request that skips the tenant's client view is refused before sending.],
        [The scripted receiver refuses a signature whose timestamp is outside a tolerance window and acknowledges an already processed delivery id without running the endpoint again, so a retry or a captured copy is processed once. It bounds every request body before reading, whatever its framing.],
        [Event ids follow a fixed grammar and event bodies have a size limit, both enforced before anything is stored.],
      )
      Source owners: `apps/webhooks/src/webhooks/attempt.gleam`, `delivery.gleam`, `subscription.gleam`, `egress.gleam`, `tenant.gleam`, `receiver.gleam`, and `web.gleam`.
    ]
      #subsection(title: "Document extraction")[
      #answers(title: "Typed document extraction",
        responsibility: [Fetch bounded documents, obtain a typed invoice from a provider and persist the result.],
        interface: [Batch job submission and native Invoice/LineItem/Currency values with semantic validation.],
        interactions: [Separate HTTP clients carry document and provider policies. LLM Wire uses one Blueprint codec for structured output; small adapters reuse the codec for the Grind output and database values. The Grind job payload uses a codec generated from a typed definition, checked against it by the tests (#adr(41)).],
        invariants: [Document content, declared length and collected bytes are bounded before model input. Unsupported content and invalid invoices do not become successful stored outputs.],
        failure: [The application translates fetch, provider, validation and storage failures into retry, snooze or discard. Provider advice does not directly own job policy.],
      )
      Source owners: `apps/extractor/src/extractor/invoice.gleam`, `document.gleam`, `document_job.gleam`, `generated/document_job_codec.gleam`, `llm.gleam`, `outcome.gleam`, and `jobs.gleam`.
    ]
    #subsection(title: "Support desk")[
      #answers(title: "Approved compensating refunds",
        responsibility: [Run a support agent whose refunds require an authorized approval and a compensating workflow.],
        interface: [Ticket/run operations, typed tools, typed Resolution, and approve/reject commands carrying checked proof.],
        interactions: [Fabric owns agent state and approval; Hellhound checks approver identity; Saga performs refund/ledger/notification; the consumer recipe retains full reports before mapping them.],
        invariants: [The proof comes from the configured verifier and required scope. Ticket correlation reaches model, tool, Saga and HTTP calls. Reopening a ticket converges on its run. The session names the authenticated customer; tools read only that customer's orders, and the workflow's first step refuses a refund of another customer's or undelivered order, of an amount beyond the total less earlier refunds, or of an amount already refunded on that order. The payment idempotency key names order and amount.],
        failure: [Unauthenticated, unauthorized and unavailable-verifier outcomes are separate. Unknown payment effects require reconciliation; failed notification triggers the workflow's compensation policy.],
      )
      Source owners: `apps/support_desk/src/support_desk/desk.gleam`, `approvers.gleam`, `refund.gleam`, `domain.gleam`, and the local Saga recipe.
    ]
      #subsection(title: "Tool hub")[
      #answers(title: "MCP in both directions",
        responsibility: [Let an agent call discovered MCP tools and expose agent execution as an MCP tool.],
        interface: [Relay declarations/calls, admitted dynamic contracts, Fabric invocation, and application recipes.],
        interactions: [The application starts the inventory peer it discovers. Relay carries idempotency/correlation metadata; Fabric owns durable keyed invocation.],
        invariants: [Dynamic schema rejection is explicit. The local peer's trusted read-only declaration is an application precondition, not a trust rule for arbitrary external peers. The agent's policy runs only tools declared read-only; a reservation or any undeclared tool waits for an operator approval, and no MCP route carries the operator credential.],
        failure: [Keyed disconnect can leave durable work inspectable; unkeyed cancellation stops its owned invocation. Tool failure and uncertain delivery remain separate from a completed protocol exchange.],
      )
      Source owners: `apps/tool_hub/src/tool_hub.gleam`, `assistant.gleam`, `relay_discovery.gleam`, `relay_run.gleam` and `relay_serve.gleam`, and `relay_tools.gleam`.
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
        [The browser receives its access token only from a POST that carries the signed same-site session cookie, answered `no-store`; a GET is refused so the token stays out of history and logs. The scripted browser verifies the provider's certificate against the provider's own root, and the client secret comes from configuration or from random bytes generated at boot, never from source.],
      )
      Source owners: `apps/secure_mcp/src/secure_mcp/auth.gleam`, `tools.gleam`, `reports.gleam`, and `web.gleam`.
    ]
    #subsection(title: "Email portal")[
      #answers(title: "Delivery, inspection and application sessions",
        responsibility: [Retain a complete email sign-in recipe under apps/email_portal using public Correio contracts.],
        interface: [Application-native account and session types, explicit challenge request and confirmation operations, capture checkpoints and the standard Gleam HTTP mailbox handler.],
        interactions: [Correio's memory store owns atomic challenge state. Capture retains local mail. The application owns both runtimes, its account policy, pending verification evidence and idempotent #term("term-session-publication").],
        invariants: [The mailbox route is explicitly configured for development. The challenge HMAC key comes from configuration or from strong random bytes generated at boot, never from source, and an all-zero key is refused. Pending values and confirmed evidence are not application sessions. A disabled or changed account cannot receive a session. Repeated publication of one verification identity returns the same session.],
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
        invariants: [The application does not implement a second refresh state machine. Custody records and browser session references have separate owners and lifetimes. A browser session row carries its own expiry, matching the cookie lifetime; lookup refuses and deletes an expired row and sign-in sweeps expired rows, so a copied cookie does not outlive it. Redirects back to the portal, including the post-logout redirect, use the configured public origin, never the request `Host`. Guarded consumption checks version and database wall time under row ownership after lock waiting; validity and storage retention remain separate.],
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
        invariants: [A fresh driver resumes durable state rather than replaying an arbitrary closure. Read-only tool replay is explicit. The read policy compares the parsed URL's scheme, host and port with the library's and its path segment by segment; a dot segment, an empty segment or a percent-encoded separator is denied. Publication keys and provider readback settle external effects.],
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
    #subsection(title: "Patient registration")[
      #answers(title: "A patient record from a conversation",
        responsibility: [Turn a contact's message into one patient record through the decision point `registration`, and confirm the registration to the contact once.],
        interface: [A webhook route `POST /inbound` and a JSON desk API: `GET /queue`, `POST /cards/:id/open`, `POST /cards/:id/verdict`, `POST /cards/:id/withdraw`, `GET /reviews`, `POST /cards/:id/review`, and `GET /pending`, which lists the messages still waiting for a recommendation. A desk request carries a bearer token that the application's configured staff table resolves to one validator and the decision sets that validator holds, or it is refused with 401. A webhook delivery carries the channel's HMAC-SHA256 signature of its body, checked against the configured channel secret before the body is parsed, or it is refused with 401. With no staff or no channel secret configured, which is the default, the routes that need them refuse every request. Native `Inbound`, `Registration` and `Context` types; `Registration` is the point's output.],
        interactions: [One LLM Wire call with structured output recommends a record. It runs as a `decisions_otp` isolated model call with a deadline, outside any transaction. `decisions_postgres` supplies the storage port, the queue reads and the Grind workers that deliver wake-ups and settlement notices. Grind owns the one pool and delivers the application's register and confirm jobs. HTTP Gun calls the scripted model provider and messaging provider; Wisp and Mist serve the desk; Sinal carries the application's events. Start-up migrates the tables on a pool of its own, builds the store from Grind's name and the desk over its port, registers the workers, starts Grind, and then sweeps, so that every pending wake-up and undelivered settlement notice has a job.],
        invariants: [The occurrence key is derived from the message id, or from its SHA-256 digest when the id exceeds 200 bytes. One admission transaction supersedes the contact's pending occurrences (`happened`, which first takes the library's lock on the contact, so admissions about one contact run one after the other), keeps the message, records that a recommendation is expected for its key (`expect`), and admits the register job. A recommendation for a message that a newer message superseded is refused by the record (`SupersededBefore`) and writes nothing. The gated tool inserts the patient row in the releasing transaction. Its guard refuses a contact whose phone already names a patient. The release check refuses a missing birth date, missing consent, and a corrected phone that names another patient. A unique phone constraint backs both. The desk opens a card only for a validator who may decide it. The card shows the context through the reader the model used and marks each read whose revision changed.],
        failure: [A failed model attempt is recorded and retried while it is retryable and below the attempt limit. A guard or release check refuses with `Refuse` for a judgment about the release: the refusal is recorded and the occurrence keeps waiting. One whose query failed answers `Unsure`: the release rolls back, nothing is recorded as refused, and the desk API answers `503 try_again`. A confirmation whose answer was lost is reported uncertain and settled by a lookup under the release key; a send the provider refuses is reported as not performed. An admission that waits longer than the store's lock wait for the contact ends as contention and keeps nothing, and the webhook answers `503 try_again` so that the channel delivers the message again.],
      )
      #points(
        [The settlement follower admits the confirm job, keyed by the release key, in the transaction that delivers the settlement notice, and only for a released occurrence. Every delivery of that job looks the message up by the release key before sending, and the send carries the release key as its idempotency key.],
        [Every provider exchange is a #term("term-model-exchange"), stored before its answer is used, including an undecodable answer. Replay over the recorded exchanges answers an unchanged request without transport. A changed prompt stays unanswered until a live rerun records new exchanges.],
        [Policy versions are rows of an application table. The desk reads the newest version in each verb's transaction, and publication requires the library's publishability check. Version 1 asks reception and, after 30 minutes waited, reception or the manager. Version 2 lets a confident, complete and consented record with an accepted insurer and no similar patient proceed after an undo window of 10 minutes, samples 20 in a hundred of those for the manager's review, and asks the manager about a possible duplicate. During the undo window reception may withdraw the registration, and a newer message from the contact supersedes it. A #term("term-promotion-gate") over the record's tally publishes version 2 only above a minimum number of judged occurrences and a minimum agreement.],
        [The staff table stands in for sign-in: identity and decision sets come from the application's configuration, never from a field the client writes. A production application verifies its own session or access token in the same place and looks the decision sets up by the verified subject. The webhook signature covers the body only; a repeated delivery is a duplicate by message id and admits nothing.],
        [Source owners: `apps/clinic_registration/src/clinic_registration/domain.gleam`, `llm.gleam`, `desk.gleam`, `jobs.gleam`, `store.gleam`, `messaging.gleam`, `evaluation.gleam` and `web.gleam`.],
      )
      #behavior(title: "A corrected registration is released once and confirmed once", area: "Patient registration", level: "boundary")[
        #given[Policy version 1 asks reception about a registration the model was unsure of.]
        #when[A receptionist corrects the birth date on the card.]
        #then[One patient row holds the corrected date, names the receptionist and carries the occurrence id.]
        #then[One confirmation is sent under the release key and the reported effect is performed.]
      ]
      #behavior(title: "Concurrent deliveries admit one registration", area: "Patient registration", level: "boundary")[
        #given[The same message is delivered twice at once.]
        #when[Both deliveries are admitted.]
        #then[One is admitted and one is a duplicate: one message row, one occurrence, one register job and one model call.]
      ]
      #behavior(title: "A card shown before a correction is refused", area: "Patient registration", level: "boundary")[
        #given[A policy needs two approvals from reception, and a receptionist corrects the record after another opened the card.]
        #when[The other receptionist approves on the earlier card.]
        #then[The desk answers `409 stale_card` and the occurrence keeps waiting.]
        #then[The reopened card shows the correction, and an approval on it releases the corrected record.]
      ]
      #behavior(title: "A refused release registers nobody and stays on the record", area: "Patient registration", level: "boundary")[
        #given[Another patient with the contact's phone is inserted while the card is open.]
        #when[A receptionist approves.]
        #then[The desk answers `409 not_registered`, no patient row exists for the contact, and the occurrence keeps waiting with one recorded refusal.]
      ]
      #behavior(title: "A worker killed after the model answered recommends once", area: "Patient registration", level: "boundary")[
        #given[The register worker is killed after the model answered and before the recommendation committed.]
        #when[Grind delivers the job again after its lease expires.]
        #then[One occurrence awaits a verdict and no failed attempt is recorded.]
      ]
      #behavior(title: "A message overtaken by a newer one leaves one card", area: "Patient registration", level: "boundary")[
        #given[A contact sends a second message while the model is still answering the first.]
        #when[The first model call finishes after the second message was admitted.]
        #then[The first message's record is superseded before it began, and reception is offered only the second message's card.]
        #then[A recommendation sent for the first message is refused as superseded and leaves its record unchanged.]
      ]
      #behavior(title: "Two messages from one contact at once leave one expected", area: "Patient registration", level: "boundary")[
        #given[Two different messages from one contact are admitted by two processes at once.]
        #when[Both admissions commit.]
        #then[Both are admitted; one record is superseded before anything was recommended for it, and the remaining card's conversation holds both messages.]
      ]
      #behavior(title: "An admission that waits too long is delivered again", area: "Patient registration", level: "boundary")[
        #given[Another transaction holds the library's lock on the contact for longer than the store waits for a lock.]
        #when[The webhook receives a message from that contact, and later receives it again.]
        #then[The first delivery answers 503 and keeps nothing; the second is admitted and its occurrence awaits a verdict.]
      ]
      #behavior(title: "A registration accepted by the policy waits out its undo window", area: "Patient registration", level: "boundary")[
        #given[Policy version 2 accepts a confident registration and holds it.]
        #when[Eleven minutes pass on the store clock, or reception withdraws it first, or the contact sends a newer message first.]
        #then[After the window the policy releases it, the patient row names `policy v2`, and the confirmation is performed.]
        #then[A manager's withdrawal is refused and reception's succeeds; a withdrawn or superseded registration writes no patient row.]
      ]
      #behavior(title: "A wake-up whose job was lost is swept and delivered", area: "Patient registration", level: "boundary")[
        #given[An occurrence awaits reception with its escalation due in seconds, and the application restarts with none of its Grind jobs.]
        #when[The start-up sweep runs.]
        #then[It admits a job for each of the two pending wake-ups, and the escalation is delivered: the occurrence then waits for reception or the manager.]
      ]
      #behavior(title: "A message id too long for a key is bounded", area: "Patient registration", level: "boundary")[
        #given[A channel message id of more than 300 bytes.]
        #when[The message is admitted.]
        #then[The occurrence id is the key built from the id's digest and is shorter than 255 bytes.]
      ]
      #behavior(title: "A lost confirmation answer is settled by lookup", area: "Patient registration", level: "boundary")[
        #given[The messaging provider sends the confirmation and answers after the client's deadline.]
        #when[The confirm job runs again.]
        #then[The reported effects are uncertain and then performed, and the contact received one message.]
      ]
      #behavior(title: "A promotion gate publishes a version only above its threshold", area: "Patient registration", level: "boundary")[
        #given[Six registrations were decided under version 1.]
        #when[The gate's thresholds are not met, and then they are.]
        #then[The stored versions stay at version 1, then version 2 is published and a confident registration is accepted by it and held for its undo window.]
      ]
      #adr(33) #adr(38) #adr(37)
    ]
    #subsection(title: "Payout desk")[
      #answers(title: "An agent's payout decided by people and paid once",
        responsibility: [Admit a support agent's payout tool call at the `payout` decision point, let finance decide it over MCP, pay a released payout once, and tell the seller only the #term("term-recorded-outcome").],
        interface: [Request admission through `app.request`, and a seller's suspension through `app.suspend_seller`. Three Relay tools, `payout_queue`, `open_payout` and `decide_payout`, behind Hellhound bearer verification with the scope `payouts`. The card is the `decisions/view` document with its own codec. Native `Payout`, `Reply` and recorded-outcome types. Grind workers for the agent run, the payment, reconciliation and telling.],
        interactions: [Fabric runs the agent with its runs in `fabric_postgres`, and the agent's policy hands the gated call over, which ends the run. The application records the handed-over call as an occurrence with the reads the model received. When the occurrence settles, a follow-on run continues the handed-over run's conversation with the recorded outcome as the call's result. A consult handler asks the `risk` point first for a seller with a recent chargeback. `decisions_postgres` supplies the storage port and the wake-up and settlement workers. The settlement follower admits the payment or the telling. Saga reserves, pays and posts. Grind owns the one pool, which the record, Fabric, Saga and the application tables borrow. Start-up migrates every package's tables on a pool of its own, publishes the policies, starts Grind and the Fabric store, sweeps so that every pending wake-up and undelivered settlement notice has a job, and then starts the MCP listener.],
        invariants: [The occurrence key is `payout:` followed by the request id, which is at most 64 bytes, so that the release key stays within the store's bound. One transaction records the request, records that a payout is expected for its key (`expect`), and admits the agent job. A failed agent run is a failed attempt under the same key, and the retried job starts a fresh run; a retry's run id has its own prefix with the attempt number before the request id, so no request id names another request's retry. The handed-over call's run and action are the occurrence's trigger and explanation, written and read back in Fabric's text forms of an action reference and an action id, and a redelivered or replayed agent job reads the ended run again, calls no model and admits one occurrence. The follow-on run's id is derived from the request, so a telling delivered again finds the run it started. The desk opens a card only for a validator who may decide it, so the requester gets none. The gated tool writes one payout instruction keyed by the release key in the releasing transaction. The release check compares the amount with the seller's available balance under a row lock and records the balance it compared. The Saga run identity and the provider's idempotency key derive from the release key. The seller is told once, only after the record states the outcome, and only that outcome.],
        failure: [A guard or release check answers `Refuse` for a judgment about the release, and `Unsure` when a database query failed. A refused release keeps the occurrence waiting with the refusal on the record; a release refused after a hold settles the occurrence as refused. An `Unsure` answer rolls the release back and records nothing as refused: a wake-up is delivered again, and the MCP tool answers "try again", as it does when the desk is busy. A provider timeout is reported uncertain, and a reconciliation lookup reports the payment without sending it again. A desk refusal's disposition chooses whether the job snoozes, is discarded or fails. A seller's suspension supersedes every pending payout to that seller, expected, waiting or held, in the suspension's transaction; nothing is released, and the seller is told the payout was superseded. A proposal for a payout superseded before the agent proposed is refused (`SupersededBefore`); its run already ended with the handover, so nothing is cancelled.],
      )
      #points(
        [The policy is data, version 1. A seller with a recent chargeback and no known risk consults `risk`; high risk needs two approvals from finance. From 500.00, two from finance approve, and after 60 minutes waited two from finance or one from the head of finance. A payout below 50.00 whose dispute the seller won proceeds. Anything else needs one approval from someone in finance other than the requester.],
        [The undo window is part of the policy: the rule that lets a payout proceed holds it, 5 minutes by default, and its decider or any holder of `finance` may withdraw it meanwhile. A new policy version changes the window only for payouts admitted after it. A validator-accepted payout is released at once.],
        [The decision point answers the #term("term-gated-agent-call"). The agent's policy hands `propose_payout` over (`policy.HandOver`): the tool never runs, no approval exists, and the model takes no turn between the handover and the decision. Once the record states the outcome, including after an uncertain effect is settled, `fabric.handover_history` gives a follow-on run the handed-over run's conversation with the recorded outcome as the call's result, and `input.continuation` starts it with no new user message, so the model's first turn continues from that result. The follow-on run's policy refuses a second proposal with "the payout is already decided". A reply whose outcome or amount differs from the record, or a follow-on run that ends without an answer, is replaced by a message built from the record, and the agent's text is kept.],
        [The access token names the person; the application's staff table supplies the decision sets that person holds. The identity provider is Hellhound's in-process testing provider. Fabric runs live in `fabric_postgres` because the follow-on run reads the handed-over run's transcript after people decide, across restarts and on any node.],
        [Source owners: `apps/payout_desk/src/payout_desk/domain.gleam`, `desks.gleam`, `agent.gleam`, `jobs.gleam`, `workflow.gleam`, `desk_tools.gleam`, `auth.gleam`, `db.gleam`, `provider.gleam`, `review.gleam` and `app.gleam`.],
      )
      #behavior(title: "A correction is paid and told as recorded", area: "Payout desk", level: "boundary")[
        #given[An agent proposes 80.00 and the seller's dispute changed after the model read it.]
        #when[A finance validator opens the card over MCP and corrects the payout to 60.00.]
        #then[The card marks only the dispute as changed, and the release records the balance the release check compared.]
        #then[One payment of 60.00 is made under the release key, and the seller is told it was paid.]
      ]
      #behavior(title: "A handed-over call leaves nothing to expire", area: "Payout desk", level: "boundary")[
        #given[The agent's model says a payout is paid whatever its result says, and its run handed the proposal over.]
        #when[More than a second passes and the run is recovered while the occurrence still waits.]
        #then[The run stays ended as handed over, with no pending approval and two model turns, and nothing is told to the seller.]
        #then[After a correction to 60.00 the follow-on run's model claims 80.00; the seller receives the application's message with the recorded amounts, and the claim is kept, not sent.]
      ]
      #behavior(title: "A job killed between the handover and the filing files once", area: "Payout desk", level: "boundary")[
        #given[The agent job's handler dies after the run handed its proposal over and before the occurrence is filed.]
        #when[Grind delivers the job again.]
        #then[The ended run is read again with its two model turns, one occurrence is filed with no failed attempt, and the payout is paid and told as usual.]
      ]
      #behavior(title: "A settlement notice delivered twice tells once", area: "Payout desk", level: "boundary")[
        #given[A payout was paid and told through its follow-on run.]
        #when[The settlement follower runs again and the telling job runs twice at once.]
        #then[The follow-on run takes no further turn, the seller has one reply, and one payment exists.]
      ]
      #behavior(title: "A release the balance does not cover is refused and kept", area: "Payout desk", level: "boundary")[
        #given[The seller's available balance is below the payout.]
        #when[A finance validator approves.]
        #then[The approval is refused, the occurrence keeps waiting with one recorded refusal, and no instruction is written.]
      ]
      #behavior(title: "Redelivery and racing verdicts release one payout", area: "Payout desk", level: "boundary")[
        #given[The request's agent job runs twice at once and the request is submitted again, or two validators approve one payout at once.]
        #when[The desk handles both.]
        #then[One occurrence exists; one approval releases it, the other is refused as already decided, and one instruction is written.]
      ]
      #behavior(title: "A guard that could not tell at the wake-up is retried", area: "Payout desk", level: "boundary")[
        #given[A small payout is held by policy, and its guard loses its database connection once when the hold ends.]
        #when[The wake-up is delivered again.]
        #then[The payout is released and told as paid, with one payment and one instruction.]
        #then[The record holds no refused release and no refused entry.]
      ]
      #behavior(title: "A hold whose wake-up job was lost is swept and released", area: "Payout desk", level: "boundary")[
        #given[A small payout is held by policy, and the Grind job of its wake-up is deleted before the application stops.]
        #when[The application starts again.]
        #then[The start-up sweep admits one wake-up job, and the payout is released, told as paid and paid once.]
      ]
      #behavior(title: "A suspension supersedes pending payouts", area: "Payout desk", level: "boundary")[
        #given[A seller has one payout held by policy and one waiting for finance, or one request whose agent has not run.]
        #when[The seller's account is suspended.]
        #then[The held and the waiting payout lapse as superseded, nothing is paid, and the seller is told each was superseded.]
        #then[The expected request is superseded before it began, and its agent job drives no run.]
      ]
      #behavior(title: "A suspension while the agent works leaves nothing to cancel", area: "Payout desk", level: "boundary")[
        #given[A request's run has handed its proposal over, and the occurrence is not filed yet.]
        #when[The seller is suspended, and then the proposal is admitted.]
        #then[The proposal is refused as superseded before it began, the run stays ended as handed over with no follow-on run, nothing is paid, and the seller is told once.]
      ]
      #behavior(title: "A failed agent run and its payout are one record", area: "Payout desk", level: "boundary")[
        #given[The model's provider refuses the first call of a request's agent run.]
        #when[Grind retries the agent job.]
        #then[The occurrence's key is the request's, it holds the failed attempt, and its recommendation comes from a fresh run.]
      ]
      #behavior(title: "A request named like another's retry has its own run", area: "Payout desk", level: "boundary")[
        #given[Request `c`'s first agent run fails and is retried, and then request `c-1` arrives.]
        #when[Both agents propose.]
        #then[Each occurrence is explained by its own request's run and holds its own order and amount.]
      ]
      #behavior(title: "A follow-on model that proposes again is denied", area: "Payout desk", level: "boundary")[
        #given[A payout was approved, and the follow-on run's model proposes it again.]
        #when[The policy answers the repeated call.]
        #then[The call is denied as already decided, the follow-on run completes without a second handover, and the seller is told from the record with the agent's reply kept.]
      ]
      #behavior(title: "A new undo window applies only to new payouts", area: "Payout desk", level: "boundary")[
        #given[Version 1 holds a small payout for 2 seconds.]
        #when[Version 2 with a 10-second window is published and another small payout arrives.]
        #then[The new payout is held for 10 seconds, and the earlier one keeps its 2 seconds and is paid.]
      ]
      #behavior(title: "A provider timeout is settled by a lookup", area: "Payout desk", level: "boundary")[
        #given[The payment provider pays and answers after the client's deadline.]
        #when[The payment is reconciled.]
        #then[The reported effects are uncertain and then performed, with one payment request, one payment and one lookup.]
      ]
      #behavior(title: "A worker killed after the provider answered pays once", area: "Payout desk", level: "boundary")[
        #given[The payment worker is killed after the provider answered.]
        #when[The payment runs again.]
        #then[One payment exists, at least one lookup ran, and the reported effect is performed.]
      ]
      #behavior(title: "A hold may be withdrawn only while it lasts", area: "Payout desk", level: "boundary")[
        #given[A small payout is held by policy.]
        #when[A validator who is neither its decider nor a withdrawer withdraws it, a withdrawer withdraws it during the hold, or a withdrawer withdraws another after its hold ended.]
        #then[The first is refused; the second settles the occurrence as withdrawn and the seller is told so; the third is refused as not held and that payout is paid.]
      ]
      #behavior(title: "An escalation lets the head of finance decide", area: "Payout desk", level: "boundary")[
        #given[A payout of 800.00 has one approval from finance, the head of finance is refused as not eligible, and the application restarts with the store clock 61 minutes later.]
        #when[The wake-ups due on the store clock are delivered through the wake-up worker's code path.]
        #then[The head of finance becomes eligible, and the card shows each alternative's count: one of two approvals from finance, none of one from the head of finance.]
        #then[The head of finance approves alone, and the payout is released and told as paid.]
      ]
      #adr(33) #adr(38) #adr(35) #adr(37) #adr(39)
    ]
    #subsection(title: "Moderation desk")[
      #answers(title: "Moderation at volume without a database",
        responsibility: [Moderate posts at the `moderation` decision point in one VM: a cascade of models recommends, versioned policies proceed or ask people at a live desk, and the follower applies the platform consequence.],
        interface: [`app.start`, `app.stop` and `app.receive`; `intake.receive`, which answers admitted or duplicate, `intake.edit` and `intake.appeal`; one desk process per person on duty; `gate.publish_if_clear`, which answers published or held. Native `Post` and `Action` types; `Action` is the point's output: publish, hide for a violation, or escalate.],
        interactions: [The `decisions` core owns the record, the verbs, policy evaluation, cards, examples, sequential replay and the invariant check. `decisions_otp` owns the in-memory store, the runtime's sweeper, dispatcher and eight workers, the isolated model call of each cascade stage, parallel replay and hints. Sinal carries the application's events and the runtime's events to the operator's counter.],
        invariants: [A post revision is admitted once by its key, in the transaction that submits its trigger and records that a recommendation is expected for it (`expect`). The gated tool records only the action under the release key; its guard refuses a post that no longer exists. The follower applies visibility, a strike, a safety case and one notification in the transaction that delivers the settlement notice, and changes nothing for a revision an edit replaced. An edit supersedes every occurrence about the post that is expected, waiting or held; a recommendation about the replaced revision is then refused and writes nothing. A claim row keeps a second moderator off an open card. A policy version and its classifier version are published together.],
        failure: [A model that hangs is killed at its deadline and one that raises is contained; each failure is a recorded attempt, and after 3 attempts the trigger is set aside while later posts still settle. A refused release is recorded. A stale card is refused and the moderator reopens it; a refusal whose disposition is `Retry` is tried again up to 3 times; a moderator who missed hints reads the whole queue again. A desk process whose subscriptions cannot be made fails its start, and the desk supervisor starts it again. When the store owner exits, the tree restarts on an empty store and seeds it again.],
      )
      #points(
        [Version 1 lets the rule model's answers proceed and asks moderators about the rest, then seniors after 30 minutes waited. Version 2 also lets a confident publish by an established author proceed, and a confident spam hide proceed after an undo window of 5 minutes during which a senior may withdraw it, each with a 2 per cent sample for reviewers. It asks seniors about self-harm and violence, and it needs two different holders of `moderators` for a hide for abuse. After 30 minutes waited, either version asks one senior; a senior's approval already standing meets that step and releases the output, and a moderator's does not.],
        [The rule model declines when no rule applies and the classifier answers. Each stage is an isolated model call with its own deadline: 100 ms for the rules and 300 ms for the classifier. Replay runs the same cascade over recorded reads.],
        [A #term("term-promotion-gate") replays the recorded examples across schedulers under a candidate classifier and policy, and publishes both only when the candidate's agreement clears 98 per cent over at least 50 proceeding examples. Publication itself checks only publishability; the gate is the application's rule for when to call it.],
        [The root supervisor is rest-for-one over the store owner, the platform seeder, the operator's counter, the desk supervisor and the runtime. A store owner restart loses the whole record; this application makes no durability claim, and `decisions_postgres` is the durable store.],
        [The `gleam run` figures are one run on one machine; no test asserts them.],
        [Source owners: `apps/moderation_desk/src/moderation_desk/app.gleam`, `point.gleam`, `domain.gleam`, `wiring.gleam`, `models.gleam`, `intake.gleam`, `desk.gleam`, `followers.gleam` and `gate.gleam`.],
      )
      #behavior(title: "Killed processes lose no decision", area: "Moderation desk", level: "boundary")[
        #given[3 000 posts move while a worker, the sweeper, the dispatcher or a desk process is killed every 50 ms, some classifiers hang once and two always raise.]
        #when[The healthy posts settle.]
        #then[The library's invariant check passes, every healthy post settled with exactly one notification, and the eight workers are running.]
        #then[Exactly the two broken posts are set aside, each with at least three recorded attempts.]
      ]
      #behavior(title: "A store owner restart starts an empty store", area: "Moderation desk", level: "boundary")[
        #given[The store owner is killed.]
        #when[The root supervisor restarts the tree.]
        #then[The store and the runtime are new processes, the store holds no occurrence, and a new post is moderated.]
      ]
      #behavior(title: "A post delivered by many is admitted once", area: "Moderation desk", level: "boundary")[
        #given[Twenty processes deliver one post at once.]
        #when[Intake receives them.]
        #then[One is admitted and nineteen are duplicates, with one occurrence and one notification.]
      ]
      #behavior(title: "A raising classifier is set aside after three attempts", area: "Moderation desk", level: "boundary")[
        #given[The classifier raises on one post every time.]
        #when[The runtime works its trigger.]
        #then[The record holds three raised attempts, the trigger is set aside, and the next post still settles.]
      ]
      #behavior(title: "The promotion gate holds a candidate that disagrees", area: "Moderation desk", level: "boundary")[
        #given[400 posts were decided under version 1.]
        #when[A candidate whose answers would let abuse through is replayed, and then a candidate that agrees.]
        #then[The first is held and policy version 1 and classifier 1 stay published; the second publishes version 2 with classifier 2.]
        #then[A replay across processes produces the same tally as the sequential replay.]
      ]
      #behavior(title: "A correction makes an open card stale", area: "Moderation desk", level: "boundary")[
        #given[A moderator holds a card and a senior corrects its output.]
        #when[The moderator approves on the earlier card.]
        #then[The verdict is refused as stale, and the moderator's approval on the reopened card releases the correction.]
      ]
      #behavior(title: "An escalation accepts only what the standing approvals meet", area: "Moderation desk", level: "boundary")[
        #given[Under version 2, two hides for abuse each have one approval standing: one from a moderator and one from a senior.]
        #when[The store clock passes 30 minutes waited.]
        #then[The hide a senior approved is released and the post is hidden.]
        #then[The hide a moderator approved goes on waiting, now for seniors, and its post stays pending.]
      ]
      #behavior(title: "An edit before the answer supersedes the expected recommendation", area: "Moderation desk", level: "boundary")[
        #given[The runtime is paused after a post was admitted.]
        #when[The author edits the post and the runtime resumes.]
        #then[The first revision's record is superseded before it began, the backlog is empty, and the coverage counts one record superseded before a recommendation.]
      ]
      #behavior(title: "A held hide can be taken back or superseded", area: "Moderation desk", level: "boundary")[
        #given[Version 2 accepts a confident spam hide and holds it.]
        #when[A moderator and then a senior withdraw it, or the author edits the post during the hold.]
        #then[The moderator is refused; the senior's withdrawal settles it as withdrawn, nothing is released, and the post stays published.]
        #then[After an edit the held hide expires as superseded, and the only release is the new revision's publish.]
      ]
      #behavior(title: "Escalations survive a stopped runtime", area: "Moderation desk", level: "boundary")[
        #given[The runtime is paused while three occurrences wait for moderators.]
        #when[The store clock passes 30 minutes waited and the runtime is started again.]
        #then[Nothing moves while it is paused, and after the restart all three wait for seniors.]
      ]
      #behavior(title: "An upheld appeal changes no verdict", area: "Moderation desk", level: "boundary")[
        #given[A hidden post is appealed and the appeal is upheld.]
        #when[The application records the appeal.]
        #then[The record gains an assessment that the output was wrong; its status and verdicts are unchanged, the post is published and the strike is removed.]
      ]
      #adr(33) #adr(38) #adr(36) #adr(37)
    ]
  ])
]
