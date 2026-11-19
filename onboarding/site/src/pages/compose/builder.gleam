//// The system builder: from what a system must do to the packages it needs,
//// the composition patterns that apply, the nearest example application
//// and what stays the application's own work. A pure function of the needs.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import pages/compose/package.{
  type Package, Blueprint, Correio, Decisions, Fabric, Grind, Hellhound, HttpGun,
  LlmWire, Relay, Retrace, Saga, Sinal,
}

pub type Need {
  CallsServices
  TypedModelAnswers
  AgentWithTools
  ExposesTools
  SignsUsersIn
  SendsEmail
  BackgroundWork
  UndoableSteps
  HumanApproval
  ReplaysSessions
}

/// The needs in the order the builder lists them.
pub const needs = [
  CallsServices,
  TypedModelAnswers,
  AgentWithTools,
  ExposesTools,
  SignsUsersIn,
  SendsEmail,
  BackgroundWork,
  UndoableSteps,
  HumanApproval,
  ReplaysSessions,
]

pub fn label(need: Need) -> String {
  case need {
    CallsServices -> "Call other services over HTTP"
    TypedModelAnswers -> "Get typed answers from an LLM"
    AgentWithTools -> "Let a model use tools in a loop"
    ExposesTools -> "Expose tools to AI agents (MCP)"
    SignsUsersIn -> "Sign users in or protect an API with tokens"
    SendsEmail -> "Send email or magic links"
    BackgroundWork -> "Run work in the background, surviving restarts"
    UndoableSteps -> "Multi-step operations that can be undone"
    HumanApproval -> "Have a person approve some outputs"
    ReplaysSessions -> "Replay what users did in a Lustre UI"
  }
}

/// The packages a need brings in by itself.
pub fn packages_for(need: Need) -> List(Package) {
  case need {
    CallsServices -> [HttpGun]
    TypedModelAnswers -> [LlmWire, Blueprint, HttpGun]
    AgentWithTools -> [Fabric, LlmWire, HttpGun]
    ExposesTools -> [Relay, Blueprint]
    SignsUsersIn -> [Hellhound, HttpGun]
    SendsEmail -> [Correio]
    BackgroundWork -> [Grind]
    UndoableSteps -> [Saga]
    HumanApproval -> [Decisions]
    ReplaysSessions -> [Retrace]
  }
}

/// Why a package is in the design.
pub fn reason(package: Package) -> String {
  case package {
    HttpGun -> "one bounded client for every outbound call"
    LlmWire -> "typed, bounded provider calls"
    Blueprint -> "codecs for answers, tool arguments and schemas"
    Fabric -> "the agent loop, policy gate and run records"
    Relay -> "MCP server and client"
    Hellhound -> "OIDC sign-in, tokens and JWT checks"
    Correio -> "mail delivery and passwordless challenges"
    Grind -> "durable jobs on PostgreSQL"
    Saga -> "ordered steps with undo and checkpoints"
    Decisions -> "policy, approvals and release at most once"
    Retrace -> "typed recording and inert replay"
    Sinal -> "comes along: attach observers to see inside all of the above"
  }
}

/// An example application in the Oversight repository and the gleam-dream
/// packages its `gleam.toml` depends on, Sinal left out.
pub type Example {
  Example(name: String, packages: List(Package))
}

pub const examples = [
  Example("Checkout", [Saga, Grind, HttpGun]),
  Example("Financial recovery", [Saga, Grind, HttpGun]),
  Example("Webhooks", [Grind, HttpGun]),
  Example("Invoice extractor", [Grind, HttpGun, LlmWire, Blueprint]),
  Example("Tool hub", [Relay, Fabric, LlmWire, Blueprint, HttpGun]),
  Example("Secure MCP", [Relay, Hellhound, Grind, Blueprint, HttpGun]),
  Example("SSO portal", [Hellhound, HttpGun]),
  Example("Email portal", [Correio]),
  Example(
    "Support desk",
    [Fabric, Saga, LlmWire, Hellhound, Blueprint, HttpGun],
  ),
  Example("Research agent", [Grind, Fabric, Saga, LlmWire, HttpGun, Blueprint]),
  Example("Session replay", [Retrace]),
  Example(
    "Clinic registration",
    [Decisions, LlmWire, Grind, Blueprint, HttpGun],
  ),
  Example(
    "Payout desk",
    [
      Fabric,
      Decisions,
      Relay,
      Saga,
      Grind,
      Hellhound,
      Blueprint,
    ],
  ),
  Example("Moderation desk", [Decisions, Blueprint]),
]

/// What the builder shows for a set of needs.
pub type Design {
  Design(
    /// In the studio's package order, Sinal included when it comes along.
    packages: List(Package),
    patterns: List(String),
    /// The example sharing the largest fraction of packages, if any shares one.
    nearest: Option(Example),
    yours: List(String),
  )
}

/// Packages that bring Sinal along: they emit telemetry worth observing.
const observed = [
  HttpGun,
  Grind,
  Saga,
  Fabric,
  Relay,
  Hellhound,
  Decisions,
  LlmWire,
]

pub fn design(chosen: Set(Need)) -> Design {
  let has = fn(need) { set.contains(chosen, need) }
  let wanted =
    list.filter(needs, has)
    |> list.flat_map(packages_for)
    |> set.from_list
  let wanted = case list.any(observed, set.contains(wanted, _)) {
    True -> set.insert(wanted, Sinal)
    False -> wanted
  }
  let mine = set.delete(wanted, Sinal)
  Design(
    packages: list.filter(package.all, set.contains(wanted, _)),
    patterns: patterns(has),
    nearest: nearest(mine),
    yours: yours(has),
  )
}

fn patterns(has: fn(Need) -> Bool) -> List(String) {
  let rules = [
    #(
      has(BackgroundWork) && has(SendsEmail),
      "Send email from a Grind job submitted in the same transaction as your write. Correio has no outbox of its own.",
    ),
    #(
      has(BackgroundWork) && has(UndoableSteps),
      "A job drives a durable saga (checkout, financial recovery).",
    ),
    #(
      has(AgentWithTools) && has(HumanApproval),
      "Fabric hands risky calls over to a Decisions point (payout desk).",
    ),
    #(
      has(AgentWithTools) && has(ExposesTools),
      "Mount MCP tools in a Fabric agent through Relay, or serve the agent itself as a tool (tool hub).",
    ),
    #(
      has(ExposesTools) && has(SignsUsersIn),
      "Back Relay’s verifier with Hellhound token validation (secure MCP).",
    ),
    #(
      has(TypedModelAnswers) && has(BackgroundWork) && !has(AgentWithTools),
      "One Grind job per document; LLM Wire’s retry advice becomes a job retry (extractor).",
    ),
    #(
      has(HumanApproval) && has(TypedModelAnswers) && !has(AgentWithTools),
      "One LLM Wire call recommends; a decision point decides (clinic registration).",
    ),
    #(
      has(AgentWithTools) && has(UndoableSteps),
      "Run approved effects as a saga that re-validates and can undo (support desk).",
    ),
    #(
      has(AgentWithTools) && has(BackgroundWork),
      "Start agent runs from jobs and keep the Fabric store in PostgreSQL to survive restarts (research agent).",
    ),
  ]
  let applies = list.filter_map(rules, keep)
  case applies, has(BackgroundWork) {
    [], True -> [
      "Submit jobs in the same transaction as the write that caused them.",
    ]
    _, _ -> applies
  }
}

fn keep(rule: #(Bool, String)) -> Result(String, Nil) {
  case rule {
    #(True, text) -> Ok(text)
    #(False, _) -> Error(Nil)
  }
}

/// The example with the highest share of packages in common (intersection
/// over union). Ties go to the earlier example; nothing in common is no match.
fn nearest(mine: Set(Package)) -> Option(Example) {
  let best =
    list.fold(examples, #(None, 0, 1), fn(best, example) {
      let #(_, best_shared, best_union) = best
      let theirs = set.from_list(example.packages)
      let shared = set.size(set.intersection(theirs, mine))
      let union = set.size(set.union(theirs, mine))
      case union > 0 && shared * best_union > best_shared * union {
        True -> #(Some(example), shared, union)
        False -> best
      }
    })
  best.0
}

fn yours(has: fn(Need) -> Bool) -> List(String) {
  let extra = [
    #(
      has(TypedModelAnswers) || has(AgentWithTools),
      "conversation history and retry budgets",
    ),
    #(has(AgentWithTools), "each tool’s domain logic"),
    #(has(BackgroundWork), "the PostgreSQL pool and who runs migrations"),
    #(has(SendsEmail), "templates"),
    #(has(SignsUsersIn), "accounts and session cookies"),
    #(has(HumanApproval), "who holds which decision set"),
    #(has(ReplaysSessions), "what is safe to record"),
    #(
      has(UndoableSteps) || has(CallsServices),
      "idempotency keys for external effects",
    ),
  ]
  [
    "policy and permissions",
    "resource lifetimes: pools, clients, supervisors",
    ..list.filter_map(extra, keep)
  ]
}
