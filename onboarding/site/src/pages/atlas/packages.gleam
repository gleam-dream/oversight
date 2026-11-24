//// The package atlas as data: twelve libraries and three tools, the layer
//// each sits on, the needs it serves and what it builds on. Relations
//// between packages are pure functions of this data.

import gleam/list

// LAYERS ----------------------------------------------------------------------

/// The map's rows, bottom to top. Lower layers are used by higher ones.
pub type Layer {
  Foundations
  Transport
  OutsideWorld
  DurableWork
  AgentsAndOversight
  Inspection
  Tooling
}

pub const layers = [
  Foundations,
  Transport,
  OutsideWorld,
  DurableWork,
  AgentsAndOversight,
  Inspection,
  Tooling,
]

pub type LayerLook {
  LayerLook(name: String, sub: String, band: String, ink: String, tint: String)
}

pub fn look(layer: Layer) -> LayerLook {
  case layer {
    Foundations ->
      LayerLook(
        "Foundations",
        "observe & shape",
        "#EAF7F5",
        "#0B4A45",
        "#DDF3F0",
      )
    Transport ->
      LayerLook(
        "Transport",
        "reach the network",
        "#ECF1FD",
        "#163A8A",
        "#E0E9FD",
      )
    OutsideWorld ->
      LayerLook(
        "Outside world",
        "models, tools, people, mail",
        "#F4EFFE",
        "#3B1785",
        "#EEE7FD",
      )
    DurableWork ->
      LayerLook(
        "Durable work",
        "outlive a request",
        "#FEF6EA",
        "#6B3404",
        "#FDF0DC",
      )
    AgentsAndOversight ->
      LayerLook(
        "Agents & oversight",
        "models act, people decide",
        "#FDF0F7",
        "#5E0B3A",
        "#FCE7F3",
      )
    Inspection ->
      LayerLook(
        "Inspection",
        "see what happened",
        "#EEF8F1",
        "#0E4D25",
        "#E2F4E7",
      )
    Tooling ->
      LayerLook("Tooling", "build & learn", "#F2F3F6", "#3B4452", "#EDEFF3")
  }
}

// NEEDS -----------------------------------------------------------------------

/// A job the reader needs done.
pub type Need {
  Observe
  DescribeData
  CallHttp
  CallModel
  ExposeTools
  SignIn
  SendEmail
  RunJobs
  RunWorkflows
  RunAgent
  PersonDecides
  ReplaySessions
}

pub const needs = [
  Observe,
  DescribeData,
  CallHttp,
  CallModel,
  ExposeTools,
  SignIn,
  SendEmail,
  RunJobs,
  RunWorkflows,
  RunAgent,
  PersonDecides,
  ReplaySessions,
]

pub fn need_label(need: Need) -> String {
  case need {
    Observe -> "see inside my service"
    DescribeData -> "describe data shapes"
    CallHttp -> "call HTTP APIs"
    CallModel -> "call an LLM"
    ExposeTools -> "expose or call tools (MCP)"
    SignIn -> "sign people in"
    SendEmail -> "send email"
    RunJobs -> "run background jobs"
    RunWorkflows -> "run multi-step workflows"
    RunAgent -> "run an agent"
    PersonDecides -> "let a person decide"
    ReplaySessions -> "replay user sessions"
  }
}

/// Which packages the map shows at full strength.
pub type Filter {
  Everything
  Serving(Need)
}

pub const everything_label = "Show everything"

// PACKAGES --------------------------------------------------------------------

pub type Package {
  Sinal
  JsonBlueprint
  HttpGun
  LlmWire
  Relay
  Hellhound
  Correio
  Grind
  Saga
  Fabric
  Decisions
  Retrace
  GleamNix
  GleamAgentTools
  Oversight
}

/// Every package, in map order.
pub const packages = [
  Sinal,
  JsonBlueprint,
  HttpGun,
  LlmWire,
  Relay,
  Hellhound,
  Correio,
  Grind,
  Saga,
  Fabric,
  Decisions,
  Retrace,
  GleamNix,
  GleamAgentTools,
  Oversight,
]

pub type Info {
  Info(
    name: String,
    layer: Layer,
    status: String,
    tiny: String,
    needs: List(Need),
    deps: List(Package),
    repo: String,
    one: String,
    owns: List(String),
    you: List(String),
    not_for: String,
    apps: List(String),
  )
}

const github = "https://github.com/gleam-dream/"

pub fn info(package: Package) -> Info {
  case package {
    Sinal ->
      Info(
        name: "Sinal",
        layer: Foundations,
        status: "Hex 0.1",
        tiny: "Typed telemetry events and spans",
        needs: [Observe],
        deps: [],
        repo: github <> "sinal",
        one: "Typed events and observers on top of the BEAM’s shared :telemetry registry. Emit a fact once; observe it with typed handlers.",
        owns: [
          "Typed event definitions with field codecs",
          "Attaching and detaching observers, scoped groups, spans",
          "An optional bounded forwarder to keep slow observers off the hot path",
        ],
        you: [
          "Exporters, metric aggregation and dashboards",
          "Which events route through a forwarder",
          "Never building event names from user input",
        ],
        not_for: "durable delivery, metric storage or distributed tracing. It reports facts; it doesn’t keep them.",
        apps: [
          "checkout", "webhooks", "extractor", "support desk", "tool hub",
          "secure MCP", "SSO portal", "research agent", "clinic", "payout desk",
          "moderation desk",
        ],
      )
    JsonBlueprint ->
      Info(
        name: "JSON Blueprint",
        layer: Foundations,
        status: "Hex 2.0",
        tiny: "Codecs that also produce JSON Schema",
        needs: [DescribeData, CallModel, ExposeTools],
        deps: [],
        repo: "https://github.com/gleam-dream/json_blueprint",
        one: "Describe a data shape once to encode, strictly decode, and publish a JSON Schema from the same definition. Validate runtime schemas you receive, too.",
        owns: [
          "Typed codecs for records, unions, enums and bounded numbers",
          "Strict decoding with a JSON path for every error",
          "Schema generation and runtime schema contracts",
        ],
        you: [
          "HTTP, authorization and protocol policy",
          "Extra structural limits on untrusted input",
        ],
        not_for: "simple serialization where gleam/json is enough.",
        apps: [
          "extractor", "support desk", "tool hub", "secure MCP",
          "research agent", "clinic", "payout desk", "moderation desk",
        ],
      )
    HttpGun ->
      Info(
        name: "HTTP Gun",
        layer: Transport,
        status: "Hex 0.1",
        tiny: "Pooled, bounded HTTP client",
        needs: [CallHttp],
        deps: [Sinal],
        repo: github <> "http_gun",
        one: "An HTTP client with a reusable connection pool, collected or streamed responses, explicit limits, offline cassettes and honest failure evidence.",
        owns: [
          "Connection pooling over HTTP/1.1 and HTTP/2, verified TLS",
          "Destination policy checked against resolved addresses",
          "Limits, deadlines, cancellation, NotSent / MaybeSent evidence",
          "Recording and replaying cassettes for tests",
        ],
        you: [
          "What a status or body means",
          "Retries, authentication and protocol framing like SSE",
          "The client’s lifetime in your supervision tree",
        ],
        not_for: "automatic retries, redirects, cookies or caching. It moves bytes and tells the truth about them.",
        apps: [
          "checkout", "webhooks", "extractor", "support desk", "tool hub",
          "secure MCP", "SSO portal", "research agent", "clinic",
        ],
      )
    LlmWire ->
      Info(
        name: "LLM Wire",
        layer: OutsideWorld,
        status: "Hex 0.1",
        tiny: "Typed, bounded calls to model providers",
        needs: [CallModel],
        deps: [JsonBlueprint, Sinal, HttpGun],
        repo: github <> "llm_wire",
        one: "Typed, bounded model calls to OpenAI, Anthropic and Google: structured answers decoded into Gleam values, tool calls, streaming and classification.",
        owns: [
          "Provider adapters and request encoding",
          "Structured output checked against each provider’s schema profile",
          "Streaming progress, timeouts, retry advice",
        ],
        you: [
          "The conversation loop and its history",
          "Authorizing and running tool calls",
          "Retries, budgets and durable recovery",
        ],
        not_for: "running an agent. It’s the wire; Fabric is the agent runtime.",
        apps: [
          "extractor", "support desk", "tool hub", "research agent", "clinic",
        ],
      )
    Relay ->
      Info(
        name: "Relay",
        layer: OutsideWorld,
        status: "Hex 0.2",
        tiny: "MCP server and client",
        needs: [ExposeTools],
        deps: [JsonBlueprint, Sinal, HttpGun],
        repo: github <> "relay",
        one: "Expose typed Gleam operations as MCP tools, resources and prompts, or call another MCP server, over stdio or Streamable HTTP.",
        owns: [
          "The MCP protocol: discovery, calls, resources, prompts, notifications",
          "One typed tool definition shared by server and client",
          "Isolated handler workers, deadlines, cancellation",
        ],
        you: [
          "Handlers and business policy",
          "The token verifier and per-request context",
          "Where the endpoint is mounted",
        ],
        not_for: "authorization decisions. It admits a bearer token through your verifier; you decide what that caller may do.",
        apps: ["tool hub", "secure MCP", "payout desk"],
      )
    Hellhound ->
      Info(
        name: "Hellhound",
        layer: OutsideWorld,
        status: "Hex 0.2 · pre-production",
        tiny: "OIDC sign-in, OAuth tokens, JWTs",
        needs: [SignIn],
        deps: [Sinal, HttpGun],
        repo: github <> "hellhound",
        one: "Sign users in through an existing identity provider, get OAuth tokens for services, and validate JWT access tokens on your API.",
        owns: [
          "OIDC login with PKCE, provider discovery and signing keys",
          "Token custody, near-expiry refresh, logout outcomes",
          "JWT validation, signed assertions and credential exchange",
        ],
        you: [
          "Accounts and session cookies",
          "Permission checks",
          "Where durable custody is stored",
        ],
        not_for: "being an identity provider itself. It talks to one. Production use needs independent security review.",
        apps: ["SSO portal", "secure MCP", "support desk", "payout desk"],
      )
    Correio ->
      Info(
        name: "Correio",
        layer: OutsideWorld,
        status: "Hex 0.1",
        tiny: "Transactional email and passwordless",
        needs: [SendEmail, SignIn],
        deps: [],
        repo: github <> "correio",
        one: "Send transactional email through SMTP, Postmark or a test capture, and add magic-link or email-code verification. Delivery and verification stay separate.",
        owns: [
          "Validated messages and MIME rendering",
          "Bounded SMTP with Accepted / NotSent / Rejected / OutcomeUnknown",
          "Challenges bound to subject, purpose and destination",
        ],
        you: [
          "Templates and wording",
          "Accounts, sessions and what verification unlocks",
          "Connecting a challenge to its email",
        ],
        not_for: "an outbox, bounce handling or inbound mail. Pair it with Grind when sending must be durable.",
        apps: ["email portal"],
      )
    Grind ->
      Info(
        name: "Grind",
        layer: DurableWork,
        status: "Hex 0.1",
        tiny: "Durable background jobs on PostgreSQL",
        needs: [RunJobs],
        deps: [Sinal],
        repo: github <> "grind",
        one: "Typed, durable background jobs on OTP and PostgreSQL. Submit in the same transaction as your own write; outcomes are stored rows.",
        owns: [
          "Queues, leases, retries, snoozes, uniqueness",
          "Typed outcomes and stored contracts",
          "Transactional admission and recovery of uncertain attempts",
        ],
        you: [
          "The PostgreSQL pool and migrations owner",
          "External effects inside handlers",
          "Queue concurrency per node",
        ],
        not_for: "cron schedules, multi-step dependencies or cluster-wide rate limits.",
        apps: [
          "checkout", "financial recovery", "webhooks", "extractor",
          "secure MCP", "research agent", "clinic", "payout desk",
        ],
      )
    Saga ->
      Info(
        name: "Saga",
        layer: DurableWork,
        status: "Hex 0.2",
        tiny: "Typed workflows with compensation",
        needs: [RunWorkflows],
        deps: [Sinal],
        repo: github <> "saga",
        one: "Typed, source-written workflows of dependent steps: concurrency, retries, undo of completed steps, and checkpoints to resume after a crash.",
        owns: [
          "A typed dependency graph of steps",
          "Concurrency limits, timeouts, retry and compensation policy",
          "Evidence for uncertain effects and durable checkpoints",
        ],
        you: [
          "Clients, stable operation ids and idempotency",
          "Storage and job scheduling for durable runs",
          "Deciding to drive, resume or cancel",
        ],
        not_for: "making remote effects transactional. It undoes what it knows succeeded and holds what it can’t prove.",
        apps: [
          "checkout", "financial recovery", "support desk", "research agent",
          "payout desk",
        ],
      )
    Fabric ->
      Info(
        name: "Fabric",
        layer: AgentsAndOversight,
        status: "Hex 0.3",
        tiny: "Bounded LLM agents and durable graphs",
        needs: [RunAgent],
        deps: [HttpGun, JsonBlueprint, LlmWire, Sinal],
        repo: github <> "fabric",
        one: "Runs bounded LLM agents with typed tools and an explicit policy gate, plus durable control graphs. Runs are recorded so they can be approved, inspected and recovered.",
        owns: [
          "The agent loop, turn and tool limits, budgets",
          "The policy gate: allow, deny, approval or hand over",
          "Run records, recovery, uncertain-effect blocking",
        ],
        you: [
          "Models, domain tools and policy",
          "Store backend and supervision",
          "Credentials and context (never stored with runs)",
        ],
        not_for: "retrieval or vector search, token streaming to users, or distributed Erlang.",
        apps: ["support desk", "tool hub", "research agent", "payout desk"],
      )
    Decisions ->
      Info(
        name: "Decisions",
        layer: AgentsAndOversight,
        status: "Git only · not on Hex yet",
        tiny: "Decision points with release-once",
        needs: [PersonDecides],
        deps: [JsonBlueprint, Sinal, Grind],
        repo: github <> "decisions",
        one: "A decision point: a model recommends, a versioned policy proceeds or asks a person, and the final output reaches a gated tool at most once. Everything is an append-only record.",
        owns: [
          "Occurrences as append-only entries",
          "Policy as versioned data, approvals, holds and undo windows",
          "Release at most once, inside your transaction",
          "Learning: agreement and accuracy per recommender",
        ],
        you: [
          "Transactions and the database pool",
          "The gated tool and who holds which decision set",
          "How a trigger becomes a recommendation",
        ],
        not_for: "calling a model, running an agent or delivering jobs. It composes with Fabric, LLM Wire and Grind for those.",
        apps: ["clinic", "payout desk", "moderation desk"],
      )
    Retrace ->
      Info(
        name: "Retrace",
        layer: Inspection,
        status: "Hex 0.1 · experimental",
        tiny: "Session recording and replay",
        needs: [ReplaySessions],
        deps: [],
        repo: github <> "retrace",
        one: "Record selected state and messages from a Lustre app, deliver them durably, and reconstruct the session later in an inert replay frame.",
        owns: [
          "Typed recording, checkpoints and wire validation",
          "Lustre capture, delivery and a replay viewer",
          "A server library for admission, indexing and archiving",
        ],
        you: [
          "Deciding what is safe to record",
          "Routing, authentication and storage",
          "Keeping the exact build of each recording",
        ],
        not_for: "screen recording. It records your app’s own typed events, not pixels.",
        apps: ["session replay"],
      )
    GleamNix ->
      Info(
        name: "Gleam Nix",
        layer: Tooling,
        status: "Nix flake",
        tiny: "Per-package Nix builds",
        needs: [],
        deps: [],
        repo: github <> "gleam-nix",
        one: "Builds each Gleam dependency as its own Nix derivation from manifest.toml, so projects share compiled packages and app edits rebuild only the app.",
        owns: [
          "Per-package builds and reuse",
          "Composing Rebar3 and Mix packages",
        ],
        you: ["Your flake and Nixpkgs input"],
        not_for: "resolving versions; Gleam still does that.",
        apps: [],
      )
    GleamAgentTools ->
      Info(
        name: "Gleam Agent Tools",
        layer: Tooling,
        status: "skills",
        tiny: "Skills for AI coding agents",
        needs: [],
        deps: [],
        repo: github <> "gleam-agent-tools",
        one: "Agent skills for writing Gleam well, with an optional language-server bridge, installable for AI coding assistants.",
        owns: ["Curated skills with decision trees and red flags"],
        you: ["Your agent configuration"],
        not_for: "runtime use; it’s for development.",
        apps: [],
      )
    Oversight ->
      Info(
        name: "Oversight",
        layer: Tooling,
        status: "catalogue",
        tiny: "Catalogue plus 14 runnable apps",
        needs: [],
        deps: [],
        repo: github <> "oversight",
        one: "The ecosystem’s front door: a catalogue of the libraries and runnable example applications that compose them, all with scripted services.",
        owns: ["Reference compositions and their tests"],
        you: ["Adapting them, not inheriting them"],
        not_for: "a framework. Read it, copy what fits.",
        apps: [],
      )
  }
}

// RELATIONS -------------------------------------------------------------------

/// How a tile on the map relates to the selected package.
pub type Relation {
  IsSelected
  BuildsOn
  UsesIt
  Unrelated
}

pub fn relation(selected: Package, package: Package) -> Relation {
  case package == selected {
    True -> IsSelected
    False ->
      case
        list.contains(info(selected).deps, package),
        list.contains(info(package).deps, selected)
      {
        True, _ -> BuildsOn
        _, True -> UsesIt
        _, _ -> Unrelated
      }
  }
}

/// The packages that build on this one.
pub fn used_by(package: Package) -> List(Package) {
  list.filter(packages, fn(p) { list.contains(info(p).deps, package) })
}

pub fn in_layer(layer: Layer) -> List(Package) {
  list.filter(packages, fn(p) { info(p).layer == layer })
}

pub fn serves(package: Package, filter: Filter) -> Bool {
  case filter {
    Everything -> True
    Serving(need) -> list.contains(info(package).needs, need)
  }
}

/// The first package on the map that serves a need.
pub fn first_serving(need: Need) -> Result(Package, Nil) {
  list.find(packages, fn(p) { serves(p, Serving(need)) })
}
