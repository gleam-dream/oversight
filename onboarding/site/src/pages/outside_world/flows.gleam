//// Four flows at the edge of a service, as step-through sequence charts.
//// The reader walks a flow step by step and flips options that change its
//// path. Everything here is pure: a walk is a value and the chart is
//// computed from it.

import gleam/int
import gleam/list
import gleam/option.{Some}
import site/msc

// CHOICES ---------------------------------------------------------------------

pub type Flow {
  LlmWireFlow
  RelayFlow
  HellhoundFlow
  CorreioFlow
}

pub const flows = [LlmWireFlow, RelayFlow, HellhoundFlow, CorreioFlow]

pub fn flow_label(flow: Flow) -> String {
  case flow {
    LlmWireFlow -> "LLM Wire"
    RelayFlow -> "Relay"
    HellhoundFlow -> "Hellhound"
    CorreioFlow -> "Correio"
  }
}

/// LLM Wire: does the model ask for a tool?
pub type ToolRequest {
  AsksForTool
  AnswersDirectly
}

/// LLM Wire: does your policy allow the requested tool?
pub type Policy {
  Allows
  Refuses
}

/// Relay: the bearer token on the request.
pub type Token {
  ValidToken
  MissingToken
}

/// Relay: what your handler does with the call.
pub type Handler {
  ReturnsResult
  RefusesCall
  AsksForInput
}

/// Hellhound: whether the app later calls an API with the user's token.
pub type Later {
  CallsApi
  StopsAtSignIn
}

/// Correio: sending mail or verifying with a magic link.
pub type Mail {
  SendMail
  MagicLink
}

/// Correio: how a send ends.
pub type Outcome {
  Accepted
  NotSent
  Rejected
  OutcomeUnknown
}

/// The reader's options. Each one is remembered while it is hidden, so
/// flipping a parent option back restores the path the reader had.
pub type Choices {
  Choices(
    tool: ToolRequest,
    policy: Policy,
    token: Token,
    handler: Handler,
    later: Later,
    mail: Mail,
    outcome: Outcome,
  )
}

pub const default_choices =
  Choices(
    tool: AsksForTool,
    policy: Allows,
    token: ValidToken,
    handler: ReturnsResult,
    later: CallsApi,
    mail: SendMail,
    outcome: Accepted,
  )

/// One option the reader can flip.
pub type Choice {
  ChooseTool(ToolRequest)
  ChoosePolicy(Policy)
  ChooseToken(Token)
  ChooseHandler(Handler)
  ChooseLater(Later)
  ChooseMail(Mail)
  ChooseOutcome(Outcome)
}

/// Every option as a choice, which together restore `choices`.
pub fn as_choices(choices: Choices) -> List(Choice) {
  [
    ChooseTool(choices.tool),
    ChoosePolicy(choices.policy),
    ChooseToken(choices.token),
    ChooseHandler(choices.handler),
    ChooseLater(choices.later),
    ChooseMail(choices.mail),
    ChooseOutcome(choices.outcome),
  ]
}

pub fn choose(choices: Choices, choice: Choice) -> Choices {
  case choice {
    ChooseTool(tool) -> Choices(..choices, tool:)
    ChoosePolicy(policy) -> Choices(..choices, policy:)
    ChooseToken(token) -> Choices(..choices, token:)
    ChooseHandler(handler) -> Choices(..choices, handler:)
    ChooseLater(later) -> Choices(..choices, later:)
    ChooseMail(mail) -> Choices(..choices, mail:)
    ChooseOutcome(outcome) -> Choices(..choices, outcome:)
  }
}

pub fn is_chosen(choices: Choices, choice: Choice) -> Bool {
  choose(choices, choice) == choices
}

/// A labelled row of options shown above the chart.
pub type OptionRow {
  OptionRow(label: String, choices: List(#(String, Choice)))
}

pub fn option_rows(flow: Flow, choices: Choices) -> List(OptionRow) {
  let mode =
    OptionRow("Flow", [
      #("send", ChooseMail(SendMail)),
      #("magic link", ChooseMail(MagicLink)),
    ])
  case flow {
    LlmWireFlow -> [
      OptionRow("Model asks for a tool", [
        #("yes", ChooseTool(AsksForTool)),
        #("no", ChooseTool(AnswersDirectly)),
      ]),
      ..case choices.tool {
        AsksForTool -> [
          OptionRow("Your policy allows it", [
            #("yes", ChoosePolicy(Allows)),
            #("no", ChoosePolicy(Refuses)),
          ]),
        ]
        AnswersDirectly -> []
      }
    ]
    RelayFlow -> [
      OptionRow("Bearer token", [
        #("valid", ChooseToken(ValidToken)),
        #("missing", ChooseToken(MissingToken)),
      ]),
      ..case choices.token {
        ValidToken -> [
          OptionRow("Handler", [
            #("ok", ChooseHandler(ReturnsResult)),
            #("refuse", ChooseHandler(RefusesCall)),
            #("input", ChooseHandler(AsksForInput)),
          ]),
        ]
        MissingToken -> []
      }
    ]
    HellhoundFlow -> [
      OptionRow("Then call an API", [
        #("yes", ChooseLater(CallsApi)),
        #("no", ChooseLater(StopsAtSignIn)),
      ]),
    ]
    CorreioFlow ->
      case choices.mail {
        SendMail -> [
          mode,
          OptionRow("Outcome", [
            #("Accepted", ChooseOutcome(Accepted)),
            #("NotSent", ChooseOutcome(NotSent)),
            #("Rejected", ChooseOutcome(Rejected)),
            #("OutcomeUnknown", ChooseOutcome(OutcomeUnknown)),
          ]),
        ]
        MagicLink -> [mode]
      }
  }
}

// STEPS -----------------------------------------------------------------------

/// Who owns a step.
pub type Owner {
  YourApp
  Library
  Outside
}

pub type Look {
  Look(label: String, background: String, ink: String, colour: msc.Colour)
}

pub fn look(owner: Owner) -> Look {
  case owner {
    YourApp -> Look("your app", "#FDF0DC", "#6B3404", msc.Amber)
    Library -> Look("library", "#EEE7FD", "#3B1785", msc.Pink)
    Outside -> Look("outside", "#EDEFF3", "#3B4452", msc.Ink)
  }
}

/// One step of a flow, on the lane of the participant that acts.
pub type Step {
  Step(lane: Int, title: String, text: String, owner: Owner)
}

pub type Script {
  Script(
    actors: List(String),
    steps: List(Step),
    intro: String,
    takeaway: String,
  )
}

/// The flow as the reader's options shape it.
pub fn script(flow: Flow, choices: Choices) -> Script {
  case flow {
    LlmWireFlow -> llm_wire(choices)
    RelayFlow -> relay(choices)
    HellhoundFlow -> hellhound(choices)
    CorreioFlow ->
      case choices.mail {
        SendMail -> correio_send(choices.outcome)
        MagicLink -> correio_magic_link()
      }
  }
}

fn llm_wire(choices: Choices) -> Script {
  let tool_round = case choices.tool {
    AnswersDirectly -> []
    AsksForTool -> [
      Step(
        1,
        "Tool call admitted",
        "The model asked for lookup_order. Its arguments are decoded into your typed value.",
        Library,
      ),
      case choices.policy {
        Allows ->
          Step(
            0,
            "Authorize and run it",
            "Your policy says yes. Your code runs the lookup and appends the result to history.",
            YourApp,
          )
        Refuses ->
          Step(
            0,
            "Refuse it",
            "Your policy says no. You append a refusal to history so the model can adapt.",
            YourApp,
          )
      },
      Step(
        0,
        "Call again",
        "A new request with the longer history: round two. Counting rounds and budgets is your job.",
        YourApp,
      ),
      Step(
        3,
        "Generate the final answer",
        "The provider now answers with what it learned.",
        Outside,
      ),
    ]
  }
  Script(
    actors: ["Your app", "LLM Wire", "HTTP Gun", "Provider"],
    steps: list.flatten([
      [
        Step(
          0,
          "Build a request",
          "Model, your conversation history, tool declarations and the codec for the answer.",
          YourApp,
        ),
        Step(
          1,
          "prepare",
          "Validates and encodes. No network. Rejects a schema the provider can’t accept, before you spend a token.",
          Library,
        ),
        Step(
          2,
          "run or stream",
          "One bounded call through the HTTP Gun client your app started.",
          Library,
        ),
        Step(
          3,
          "Generate",
          "The provider streams progress: text, tool arguments, usage.",
          Outside,
        ),
      ],
      tool_round,
      [
        Step(
          1,
          "Outcome",
          "The answer decoded into your type, plus usage. Or a Failure with send evidence and retry advice.",
          Library,
        ),
        Step(
          0,
          "Keep the history",
          "Store the conversation wherever you like. LLM Wire keeps none of it.",
          YourApp,
        ),
      ],
    ]),
    intro: "LLM Wire turns one model call into typed values with firm limits. It’s a wire, not an agent: the loop, the history and every tool decision stay in your code. (Fabric, in module 9, is the agent runtime built on top.)",
    takeaway: case choices.tool {
      AsksForTool ->
        "A tool loop is just your code calling LLM Wire repeatedly with a growing history. You authorize every tool call; the library never runs one."
      AnswersDirectly ->
        "Without tools it’s one prepared call and one typed outcome. Structured output means the answer arrives as your own Gleam type, not text to parse."
    },
  )
}

fn relay(choices: Choices) -> Script {
  let admitted = case choices.token {
    ValidToken -> " and asks your verifier about the bearer token: accepted."
    MissingToken ->
      " and asks your verifier about the bearer token: there isn’t one."
  }
  let rest = case choices.token {
    MissingToken -> [
      Step(
        0,
        "Rejected",
        "No valid token, so the request never reaches a handler. Nothing ran.",
        Library,
      ),
    ]
    ValidToken -> {
      let #(title, text, reply) = case choices.handler {
        ReturnsResult -> #(
          "Return a result",
          "Your handler returns a typed output.",
          "Succeeded(output), encoded with the same codec.",
        )
        RefusesCall -> #(
          "Refuse the call",
          "Your handler refuses: say, that order isn’t this caller’s. A refusal is an answer, not a crash.",
          "A tool refusal, distinct from success and from failure.",
        )
        AsksForInput -> #(
          "Ask for more input",
          "Your handler needs more information, and Relay sends a request for input back to the client.",
          "A request for more input, with what’s needed.",
        )
      }
      [
        Step(
          2,
          "Order the protocol",
          "A runtime actor applies a pure reducer to protocol state, then starts an isolated worker for this call.",
          Library,
        ),
        Step(
          3,
          "Your handler: " <> title,
          text <> " It sees decoded input and the request context.",
          YourApp,
        ),
        Step(2, "Reply", reply, Library),
        Step(
          0,
          "Typed result",
          "A Gleam client gets Succeeded, a refusal or a request for input. Client failures also keep send evidence.",
          Outside,
        ),
      ]
    }
  }
  Script(
    actors: [
      "MCP client (agent)",
      "Relay transport",
      "Relay runtime",
      "Your handler",
    ],
    steps: [
      Step(
        0,
        "Discover tools",
        "The agent lists tools. Each schema comes from the same codecs your handler uses.",
        Outside,
      ),
      Step(
        1,
        "Admit the request",
        "Streamable HTTP request in. Relay builds per-request context"
          <> admitted,
        Library,
      ),
      ..rest
    ],
    intro: "MCP is how agents discover and call tools. With Relay, one typed tool definition serves both sides: the server declares and handles it, a client calls it and gets typed values back. The tool hub example even serves a Fabric agent as an MCP tool.",
    takeaway: case choices.token {
      MissingToken ->
        "Admission happens before any handler runs. Relay asks your verifier; what a valid caller may then do is still your policy."
      ValidToken ->
        "Each call runs in its own worker, and outcomes come in three honest shapes: succeeded, refused, or needs more input."
    },
  )
}

fn hellhound(choices: Choices) -> Script {
  let later = case choices.later {
    StopsAtSignIn -> []
    CallsApi -> [
      Step(
        1,
        "Later: call an API",
        "Your app needs the user’s access token for a downstream API.",
        YourApp,
      ),
      Step(
        2,
        "Refresh near expiry",
        "The token is about to expire, so Hellhound refreshes it. Ten requests asking at once share one refresh.",
        Library,
      ),
      Step(
        3,
        "API checks the token",
        "On the API side, Hellhound validates the JWT locally with audience and scope policy.",
        Library,
      ),
    ]
  }
  Script(
    actors: ["Browser", "Your app", "Hellhound", "Identity provider"],
    steps: list.append(
      [
        Step(0, "Click \"Sign in\"", "The user wants in.", Outside),
        Step(
          2,
          "Begin login",
          "Builds the provider’s authorization address with PKCE (S256), using cached discovery.",
          Library,
        ),
        Step(
          3,
          "User signs in",
          "At the identity provider you already use. Your app never sees a password.",
          Outside,
        ),
        Step(
          1,
          "Callback arrives",
          "The browser returns with a one-time code. Your route hands it to Hellhound.",
          YourApp,
        ),
        Step(
          2,
          "Exchange and check",
          "Swaps the code for tokens, verifies signatures with cached keys, checks issuer and audience. You get a checked identity and your own decoded claims.",
          Library,
        ),
        Step(
          1,
          "Your account, your cookie",
          "Find or create the account by issuer and subject. Set your own session cookie. Tokens stay in Hellhound’s custody.",
          YourApp,
        ),
      ],
      later,
    ),
    intro: "Hellhound signs people in through an existing OpenID Connect provider, keeps their tokens, and checks access tokens on your APIs. It is pre-production: real deployments need an independent security review first.",
    takeaway: "Hellhound proves who someone is and keeps their tokens. Your app decides what an account is, how sessions work and what anyone may do.",
  )
}

pub fn outcome_name(outcome: Outcome) -> String {
  case outcome {
    Accepted -> "Accepted"
    NotSent -> "NotSent"
    Rejected -> "Rejected"
    OutcomeUnknown -> "OutcomeUnknown"
  }
}

fn correio_send(outcome: Outcome) -> Script {
  let #(meaning, next) = case outcome {
    Accepted -> #(
      "The server took responsibility for the message. Not proof it reached an inbox.",
      "Record it as sent.",
    )
    NotSent -> #(
      "Provably not sent: the connection failed before the message went out.",
      "Safe to retry.",
    )
    Rejected -> #(
      "The server refused it, for example a bad address.",
      "Fix the cause; a blind retry will fail again.",
    )
    OutcomeUnknown -> #(
      "The connection broke mid-submission. It may or may not be on its way.",
      "Don’t assume either way. Record it and reconcile, or let the user ask again.",
    )
  }
  Script(
    actors: ["Your app", "Correio", "Sender", "Mail server"],
    steps: [
      Step(
        0,
        "Compose",
        "Parse addresses, write text and HTML, add attachments. Building a message sends nothing.",
        YourApp,
      ),
      Step(
        1,
        "Admit and render",
        "Validates the message and renders MIME.",
        Library,
      ),
      Step(
        2,
        "Hand to a sender",
        "The Sender is a plain function you inject: SMTP, Postmark, or a capture for tests.",
        YourApp,
      ),
      Step(3, "Submit", "Bounded SMTP with STARTTLS or implicit TLS.", Outside),
      Step(1, outcome_name(outcome), meaning, Library),
      Step(0, "Decide", next, YourApp),
    ],
    intro: "Correio sends transactional mail through a sender you inject, so swapping SMTP for a test capture is one line. Each send ends in one of four distinct outcomes.",
    takeaway: "Four outcomes, four different next moves. OutcomeUnknown is the same honesty as MaybeSent from module 4.",
  )
}

fn correio_magic_link() -> Script {
  Script(
    actors: ["Your app", "Passwordless service", "Store", "User’s inbox"],
    steps: [
      Step(
        0,
        "Issue a challenge",
        "For a subject, a purpose (sign-in), a scope and a destination address.",
        YourApp,
      ),
      Step(
        1,
        "Create it",
        "A magic link or email code bound to exactly those things.",
        Library,
      ),
      Step(
        2,
        "Keep it",
        "In memory for tests, or the PostgreSQL adapter over your pool.",
        Library,
      ),
      Step(
        0,
        "Send the email",
        "A separate step: you put the link in a message and send it through your sender.",
        YourApp,
      ),
      Step(
        3,
        "User clicks",
        "The link (or code) comes back to your app.",
        Outside,
      ),
      Step(
        1,
        "Verify",
        "Returns opaque verification evidence, or a typed reason it failed.",
        Library,
      ),
      Step(
        0,
        "Unlock something",
        "You decide what the evidence means: a session, a confirmed address, a step-up.",
        YourApp,
      ),
    ],
    intro: "Passwordless verification is a separate service from delivery. Your app connects the two explicitly, so you control what is sent, when, and what a successful check unlocks.",
    takeaway: "Verification and delivery never call each other. That’s what lets you test each one alone and swap either side.",
  )
}

// WALKING A FLOW --------------------------------------------------------------

/// The reader's walk through one flow. `step` is the last step reached,
/// counting from 1. It is kept as the reader left it when an option shortens
/// the flow, and read through `current`, which clamps it to the flow.
pub type Walk {
  Walk(flow: Flow, step: Int, choices: Choices)
}

pub const start = Walk(flow: LlmWireFlow, step: 1, choices: default_choices)

pub fn steps(walk: Walk) -> List(Step) {
  script(walk.flow, walk.choices).steps
}

pub fn total(walk: Walk) -> Int {
  list.length(steps(walk))
}

/// The step on screen, counting from 1.
pub fn current(walk: Walk) -> Int {
  int.min(walk.step, total(walk))
}

/// Switching flows starts the new flow at its first step.
pub fn pick_flow(walk: Walk, flow: Flow) -> Walk {
  Walk(..walk, flow:, step: 1)
}

pub fn flip(walk: Walk, choice: Choice) -> Walk {
  Walk(..walk, choices: choose(walk.choices, choice))
}

pub fn back(walk: Walk) -> Walk {
  Walk(..walk, step: int.max(1, current(walk) - 1))
}

pub fn forward(walk: Walk) -> Walk {
  Walk(..walk, step: int.min(total(walk), current(walk) + 1))
}

pub fn show_all(walk: Walk) -> Walk {
  Walk(..walk, step: total(walk))
}

/// The step on screen.
pub fn current_step(walk: Walk) -> Result(Step, Nil) {
  steps(walk) |> list.drop(current(walk) - 1) |> list.first
}

// CHART -----------------------------------------------------------------------

/// A step on the lane of the previous step is a note; otherwise it is a
/// message from the previous step's lane to its own.
pub fn events(steps: List(Step)) -> List(msc.Event) {
  let #(_, events) =
    list.fold(steps, #(-1, []), fn(acc, step) {
      let #(previous, events) = acc
      let colour = look(step.owner).colour
      let event = case previous == step.lane || previous < 0 {
        True -> msc.Note(at: step.lane, label: step.title, colour:)
        False -> msc.send(previous, step.lane, step.title, colour)
      }
      #(step.lane, [event, ..events])
    })
  list.reverse(events)
}

pub fn chart(walk: Walk) -> msc.Chart {
  let script = script(walk.flow, walk.choices)
  let current = current(walk)
  let total = list.length(script.steps)
  let base = msc.chart("f7", script.actors, events(script.steps))
  msc.Chart(
    ..base,
    upto: Some(current),
    lane_gap: 190,
    row: 30,
    numbers: True,
    active: case current_step(walk) {
      Ok(step) -> Some(step.lane)
      Error(Nil) -> option.None
    },
    aria: "Sequence chart of the selected flow, step "
      <> int.to_string(current)
      <> " of "
      <> int.to_string(total),
  )
}
