#import ".render/designlib.typ": *

#let title = [Gleam Dream ecosystem]
#let accent = "teal"
#let index_only = true

#let body = [
  #section(title: "Foundation", lead: "Oversight owns the composition contracts and executable evidence that connect independent Gleam libraries. Each context owns the rest of its foundation.", body: [
    #goal(title: "Compose independently useful libraries")[Applications build complex behavior from small public surfaces backed by cohesive capabilities. Each library remains useful without an ecosystem-wide runtime.]
    #goal(title: "Retain the intended capability scope")[A bounded release surface does not erase the broader #term("term-capability-scope"). Unbuilt requirements remain visible in the package that owns them.]
    #no-goal(title: "A shared application framework")[Oversight supplies no mandatory runtime, service container, universal error type, common retry engine, or global policy registry.]
    #invariant(title: "Every contract has one semantic owner", enforcement: "convention")[Each #term("term-package-authority") defines its own guarantees. Consumers translate meanings explicitly; similar record fields alone do not establish shared meaning.]
    #principle(title: "Simplicity includes application responsibility", lens: "composition")[Prefer the design that removes unnecessary concepts and repeated application decisions while retaining meaningful caller control. A shorter facade that shifts hidden work to every application is not simpler.]
    The documentation ownership decision is recorded in #adr(1). The package and API boundaries are justified by #adr(2) and #adr(3).
  ])

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
    caption: [The map shows the principal runtime dependencies. The package table lists every direct sibling dependency. The Retrace node groups its independently selected core, frontend and server packages. PostgreSQL adapters borrow an application-owned connection pool.],
  ), body: [
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
      [The application selects the participating libraries; no package imports Oversight at runtime. The package set is recorded in #adr(14), #adr(16) and #adr(17); removed bridge rationale is recorded in #adr(3).],
      [A #term("term-consumer-recipe") may join packages absent from each other's dependency graph. The recipe must understand their public semantics, not their private representation.],
    )
  ])

  #section(title: "Contexts", lead: "Three contexts divide the layer by vocabulary. Each context owns its terms, and a context cites another context's term without redefining it.", body: [
    #md-table(3, (
      [*Context*], [*Owns*], [*Vocabulary*],
      [#ctx("composition")], [Caller contracts, execution and evidence boundaries, protocol and authorization composition, observation joins], [Package authority, composition boundary, effect evidence, admission identity],
      [#ctx("applications")], [The composition applications and each application's task, ownership and recovery behavior], [Composition application, business identity, reconciliation decision, applied marker],
      [#ctx("evidence")], [Retained experiments, validation profiles, source qualification and design maintenance], [Public consumer, behavioral oracle, sibling revision set, validation profile],
    ))
    #points(
      [#ctx("applications") conforms to the contracts of #ctx("composition"); each application demonstrates one or more composition boundaries.],
      [#ctx("evidence") judges both other contexts and defines what a passing check does and does not establish.],
      [The relationships between contexts are declared in the context map.],
    )
  ])
]
