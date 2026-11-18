//// The ten runnable applications in the Oversight repository that the
//// studio walks through, and the six composition patterns they share.
////
//// Each system's packages are the gleam-dream packages its `gleam.toml`
//// under `apps/` depends on directly.

import gleam/list
import pages/compose/package.{
  type Actor, type Package, Blueprint, Decisions, Fabric, Grind, Hellhound,
  HttpGun, LlmWire, Relay, Saga, Sinal, Uses, YourApp,
}

pub type System {
  Checkout
  Webhooks
  InvoiceExtractor
  ToolHub
  SecureMcp
  SupportDesk
  ResearchAgent
  ClinicRegistration
  PayoutDesk
  ModerationDesk
}

/// The systems in the order the studio lists them.
pub const all = [
  Checkout,
  Webhooks,
  InvoiceExtractor,
  ToolHub,
  SecureMcp,
  SupportDesk,
  ResearchAgent,
  ClinicRegistration,
  PayoutDesk,
  ModerationDesk,
]

pub type Info {
  Info(
    name: String,
    task: String,
    packages: List(Package),
    blurb: String,
    /// Who does what, in order.
    steps: List(#(Actor, String)),
    why: String,
    owns: String,
  )
}

pub fn step_count(system: System) -> Int {
  list.length(info(system).steps)
}

pub fn info(system: System) -> Info {
  case system {
    Checkout ->
      Info(
        name: "Checkout",
        task: "Reserve, charge, ship",
        packages: [Saga, Grind, HttpGun, Sinal],
        blurb: "An order API. The checkout saga reserves stock, charges a payment token and books a shipment, compensating in reverse on failure. A durable mode runs the same saga from a Grind job.",
        steps: [
          #(
            YourApp,
            "POST /orders. The server prices the order from its own catalog; a body that carries an amount is refused.",
          ),
          #(
            Uses(Grind),
            "Durable mode: the order row and a job are written in one transaction.",
          ),
          #(
            Uses(Grind),
            "A worker claims the job and drives the checkout saga by a stable id.",
          ),
          #(
            Uses(Saga),
            "Reserve stock, charge the token with an idempotency key, book the shipment.",
          ),
          #(
            Uses(HttpGun),
            "Every provider call goes through HTTP Gun, with send evidence on failure.",
          ),
          #(
            Uses(Saga),
            "On failure, undo completed steps in reverse. An uncertain charge is held, never guessed.",
          ),
          #(
            Uses(Sinal),
            "Grind, Saga and HTTP Gun emit lifecycle events to your observers.",
          ),
        ],
        why: "Grind makes the work survive restarts; Saga gives it order and undo. Neither alone covers both.",
        owns: "Pricing, authentication, payment tokens, the orders table and stable error codes.",
      )
    Webhooks ->
      Info(
        name: "Webhooks",
        task: "Deliver signed events",
        packages: [Grind, HttpGun, Sinal],
        blurb: "A multi-tenant outbound webhook service: one event fans out to one durable job per subscription.",
        steps: [
          #(
            YourApp,
            "A tenant registers endpoint URLs. Its API key, never the request body, decides which tenant it is.",
          ),
          #(
            Uses(Grind),
            "Publishing an event fans out to one Grind job per active subscription.",
          ),
          #(
            Uses(HttpGun),
            "The worker signs the delivery and sends it under a per-tenant destination policy.",
          ),
          #(
            Uses(Grind),
            "The HTTP result maps to a Grind retry, snooze, discard or failure.",
          ),
          #(
            YourApp,
            "The delivery id travels on every retry as the receiver’s idempotency key.",
          ),
        ],
        why: "Each delivery is an independent unit that must survive restarts: exactly a Grind job. HTTP Gun’s evidence decides how to retry it.",
        owns: "Signing, tenant isolation, and mapping statuses to retry decisions.",
      )
    InvoiceExtractor ->
      Info(
        name: "Invoice extractor",
        task: "Documents in, typed invoices out",
        packages: [Grind, HttpGun, LlmWire, Blueprint, Sinal],
        blurb: "Batch extraction: each document URL becomes a job that fetches it, asks a model for a typed Invoice, and stores the result.",
        steps: [
          #(
            Uses(Grind),
            "A batch of document URLs becomes a batch of Grind jobs.",
          ),
          #(
            Uses(HttpGun),
            "Each job fetches its document as a bounded stream. An oversized one is refused.",
          ),
          #(Uses(LlmWire), "One structured-output call asks for an Invoice."),
          #(
            Uses(Blueprint),
            "The Invoice codec is both the schema the model sees and the decoder that checks it.",
          ),
          #(
            YourApp,
            "Business rules check it: a total that contradicts its lines, an unknown currency.",
          ),
          #(
            Uses(Grind),
            "A rate-limited call follows LLM Wire’s retry advice and becomes a job retry.",
          ),
        ],
        why: "One job per document isolates failures. The codec turns a model’s answer into a Gleam value or a precise error.",
        owns: "Invoice rules, the retry policy and storage.",
      )
    ToolHub ->
      Info(
        name: "Tool hub",
        task: "MCP in both directions",
        packages: [Relay, Fabric, LlmWire, Blueprint, HttpGun, Sinal],
        blurb: "An inventory MCP server, a Fabric agent that uses it, and a second MCP server that exposes the agent itself as a tool.",
        steps: [
          #(Uses(Relay), "An inventory server exposes three typed tools."),
          #(
            Uses(Fabric),
            "A Fabric agent mounts them through the Relay client.",
          ),
          #(
            Uses(Fabric),
            "Its policy runs only tools the inventory declares read-only. reserve_stock waits for the operator.",
          ),
          #(
            Uses(Relay),
            "A second Relay server exposes the agent as the tool ask_assistant.",
          ),
          #(
            YourApp,
            "The operator approves or rejects; the caller repeats its keyed call to read the answer.",
          ),
        ],
        why: "A question is untrusted model input, so read-only hints become policy, and anything that changes stock waits for a person.",
        owns: "Which tools are safe, the operator credential and the approval step.",
      )
    SecureMcp ->
      Info(
        name: "Secure MCP",
        task: "Tools that act for a user",
        packages: [Relay, Hellhound, Grind, Blueprint, HttpGun, Sinal],
        blurb: "An MCP server whose report tools act for a signed-in user, with long reports running as jobs.",
        steps: [
          #(Uses(Hellhound), "The user signs in through OpenID Connect."),
          #(
            YourApp,
            "POST /me/token hands them an access token to paste into an MCP client.",
          ),
          #(
            Uses(Relay),
            "Relay’s protected endpoint shares the web listener; its verifier validates the token.",
          ),
          #(
            Uses(Grind),
            "generate_report and report_status run as Grind jobs owned by the authenticated subject.",
          ),
          #(
            YourApp,
            "No token, another user’s job, wrong audience, forged or revoked token: each one is refused.",
          ),
        ],
        why: "Identity from Hellhound, protocol from Relay, long work from Grind. Who may see which job stays an app check.",
        owns: "Mapping subjects to permissions and checking job ownership.",
      )
    SupportDesk ->
      Info(
        name: "Support desk",
        task: "Approve and execute refunds",
        packages: [Fabric, Saga, LlmWire, Hellhound, Blueprint, HttpGun, Sinal],
        blurb: "A customer-support agent with typed tools for order lookup, refund eligibility and refunds.",
        steps: [
          #(
            Uses(Hellhound),
            "Each ticket’s session names the customer the application authenticated.",
          ),
          #(Uses(Fabric), "The agent looks up only that customer’s orders."),
          #(
            Uses(Fabric),
            "A refund waits for a human approver at the policy gate.",
          ),
          #(
            Uses(Saga),
            "Approved refunds run as a saga: refund through the payment API, write a ledger entry, notify the customer.",
          ),
          #(
            Uses(Saga),
            "Its first step re-checks: the order is theirs, delivered, and the amount fits.",
          ),
          #(Uses(Fabric), "The agent finishes with a typed Resolution."),
        ],
        why: "A customer’s message can steer the model, so approval isn’t the only guard: the workflow re-validates before money moves.",
        owns: "Ownership checks, refund limits and an idempotency key naming order and amount.",
      )
    ResearchAgent ->
      Info(
        name: "Research agent",
        task: "Resume after a crash, publish",
        packages: [Grind, Fabric, Saga, LlmWire, HttpGun, Blueprint, Sinal],
        blurb: "A research agent that survives a VM restart mid-run and publishes through a compensating workflow.",
        steps: [
          #(
            Uses(Grind),
            "start_research records the request and enqueues a job in one transaction.",
          ),
          #(Uses(Fabric), "The job runs an agent with search and read tools."),
          #(
            Uses(Fabric),
            "Its policy parses every URL the model picks and admits only one host and path prefix.",
          ),
          #(
            Uses(Fabric),
            "Every turn is checkpointed in PostgreSQL, so a restart resumes the run.",
          ),
          #(
            Uses(Saga),
            "A durable saga publishes the article, with compensation.",
          ),
        ],
        why: "Three clear authorities: Grind owns delivery, Fabric owns the agent run, Saga owns the publish.",
        owns: "The URL policy, the publish target and cancellation.",
      )
    ClinicRegistration ->
      Info(
        name: "Clinic registration",
        task: "A patient record from a chat",
        packages: [Decisions, LlmWire, Grind, Blueprint, HttpGun, Sinal],
        blurb: "Patient registration from a messaging conversation, through a decision point on PostgreSQL.",
        steps: [
          #(
            Uses(Decisions),
            "A message arrives as a trigger. Admitting it supersedes older work for the same contact and records that a recommendation is expected.",
          ),
          #(
            Uses(LlmWire),
            "One structured-output call recommends a patient record.",
          ),
          #(
            Uses(Decisions),
            "A stored, versioned policy decides: v1 asks reception; v2 lets a sure registration proceed after a ten-minute undo window.",
          ),
          #(Uses(Grind), "Grind delivers wake-ups and settlement notices."),
          #(
            Uses(Decisions),
            "The record is released once to the gated registration tool.",
          ),
        ],
        why: "A late model answer for an older message writes nothing, because the newer one superseded it.",
        owns: "Patient record rules, the reception roster and the messaging channel.",
      )
    PayoutDesk ->
      Info(
        name: "Payout desk",
        task: "Agent proposes, finance decides",
        packages: [
          Fabric,
          Decisions,
          Relay,
          Saga,
          Grind,
          Hellhound,
          Blueprint,
          Sinal,
        ],
        blurb: "A marketplace pays its sellers. The agent investigates; a decision point decides; a saga pays.",
        steps: [
          #(
            Uses(Fabric),
            "A support agent investigates a disputed order and proposes a payout.",
          ),
          #(
            Uses(Fabric),
            "The policy hands the propose_payout call over. The run ends; nothing is paid.",
          ),
          #(
            Uses(Decisions),
            "The payout point applies versioned policy: small won disputes proceed after an undo window; from 500.00 it takes two from finance.",
          ),
          #(Uses(Relay), "The decision desk is served over MCP."),
          #(
            Uses(Saga),
            "A release check compares the amount to the seller’s balance, then the payout runs as a saga.",
          ),
        ],
        why: "Fabric never moves money. A decision point owns the \"should we\", a saga owns the \"how\".",
        owns: "Who is in finance, balance rules and suspensions that supersede pending payouts.",
      )
    ModerationDesk ->
      Info(
        name: "Moderation desk",
        task: "Moderate posts at volume",
        packages: [Decisions, Blueprint, Sinal],
        blurb: "Moderation with no database: the decisions OTP runtime works through posts with a bounded pool of workers.",
        steps: [
          #(
            Uses(Decisions),
            "Posts arrive as triggers for the moderation point.",
          ),
          #(
            Uses(Decisions),
            "A rule model and a classifier, each isolated with a deadline, recommend publish, hide or escalate.",
          ),
          #(
            Uses(Decisions),
            "Versioned policies let confident answers through and ask moderators or seniors about the rest; a sample is reviewed.",
          ),
          #(
            Uses(Decisions),
            "Policy v2 holds a confident spam hide for five minutes; a senior may take it back.",
          ),
          #(
            Uses(Sinal),
            "A replay gates each new policy version, and Sinal counts what an operator needs to see.",
          ),
        ],
        why: "All of BEAM’s strengths in one place: isolated model processes, live desks, and a supervised runtime.",
        owns: "The rules, the moderator roster and which samples to review.",
      )
  }
}

// PATTERNS --------------------------------------------------------------------

pub type Pattern {
  Pattern(name: String, chain: List(Actor), text: String)
}

pub const patterns = [
  Pattern(
    name: "Transactional enqueue",
    chain: [YourApp, Uses(Grind)],
    text: "Write your row and submit the job in one transaction. Both exist or neither does: the outbox pattern, built in.",
  ),
  Pattern(
    name: "A job drives a saga",
    chain: [Uses(Grind), Uses(Saga)],
    text: "Grind redelivers after a crash; the saga reconnects by id and resumes from its checkpoint.",
  ),
  Pattern(
    name: "Typed model call",
    chain: [Uses(LlmWire), Uses(Blueprint), Uses(HttpGun)],
    text: "A codec describes the answer, LLM Wire makes one bounded call, and you get a Gleam value or a precise error.",
  ),
  Pattern(
    name: "Agent with gated tools",
    chain: [Uses(Fabric), Uses(LlmWire), Uses(Relay)],
    text: "Fabric runs the loop on LLM Wire; tools can come from MCP servers through Relay. Policy sees every call.",
  ),
  Pattern(
    name: "Hand over to a decision point",
    chain: [Uses(Fabric), Uses(Decisions), Uses(Saga)],
    text: "The agent proposes, a decision point decides with policy and people, and a saga performs the effect once.",
  ),
  Pattern(
    name: "Protected tools, long work",
    chain: [Uses(Hellhound), Uses(Relay), Uses(Grind)],
    text: "Hellhound validates tokens, Relay admits the caller, Grind runs long work owned by that subject.",
  ),
]
