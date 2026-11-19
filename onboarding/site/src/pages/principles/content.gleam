//// The module's content as typed data: the seven habits, the twelve jobs of
//// the ownership sorter and the five "define once" definitions.

// THE SEVEN HABITS ------------------------------------------------------------

pub type Habit {
  LibrariesNotAFramework
  AppOwnsDecisions
  TypedAtEveryBoundary
  BoundedByDefault
  HonestAboutUncertainty
  RecordsAreTheTruth
  PureCoreThinShell
}

pub const habits = [
  LibrariesNotAFramework,
  AppOwnsDecisions,
  TypedAtEveryBoundary,
  BoundedByDefault,
  HonestAboutUncertainty,
  RecordsAreTheTruth,
  PureCoreThinShell,
]

pub type HabitInfo {
  HabitInfo(
    n: Int,
    title: String,
    short: String,
    long: String,
    seen: List(String),
  )
}

pub fn habit(habit: Habit) -> HabitInfo {
  case habit {
    LibrariesNotAFramework ->
      HabitInfo(
        n: 1,
        title: "Libraries, not a framework",
        short: "Pick only what you need; compose in plain code.",
        long: "Each package is independent, with its own API and runtime. There is no shared base, no global registry, no \"gleam-dream app\". Your application imports a few libraries and connects them with ordinary functions. The Oversight repository shows compositions to read and adapt, not a framework to inherit.",
        seen: ["every package", "Oversight example apps"],
      )
    AppOwnsDecisions ->
      HabitInfo(
        n: 2,
        title: "Your app owns decisions",
        short: "Libraries own one mechanism. You own policy and lifetimes.",
        long: "Libraries do the fiddly mechanical work: pooling, leasing, encoding, refreshing, recording. Your application keeps every decision: who may do what, when to retry, which database pool to use, when things start and stop. Accounts, credential policy and context stay with your app. A library keeps only the state its mechanism needs, such as the tokens Hellhound refreshes.",
        seen: [
          "Fabric policy", "LLM Wire history", "Hellhound accounts",
          "Grind pools",
        ],
      )
    TypedAtEveryBoundary ->
      HabitInfo(
        n: 3,
        title: "Typed at every boundary",
        short: "Define a shape once; derive every use from it.",
        long: "JSON goes through codecs. Telemetry events have typed fields. Tools, jobs and decision points are typed definitions shared by both sides. When data crosses into or out of your program, a type checks it at the door.",
        seen: [
          "JSON Blueprint codecs", "Sinal events", "Relay tools",
          "Grind workers",
        ],
      )
    BoundedByDefault ->
      HabitInfo(
        n: 4,
        title: "Bounded by default",
        short: "Every queue, body and wait has a limit.",
        long: "Unbounded things are how healthy services fall over: a queue that grows forever, a response body that never ends, a call that never returns. gleam-dream gives every one of them an explicit limit, a typed failure when it trips, and a way for you to configure it.",
        seen: [
          "LLM Wire timeouts", "HTTP Gun limits", "Sinal forwarder capacity",
          "Fabric budgets",
        ],
      )
    HonestAboutUncertainty ->
      HabitInfo(
        n: 5,
        title: "Honest about uncertainty",
        short: "NotSent, MaybeSent, Unknown: never a guess.",
        long: "When a call to the outside world breaks, packages report what they can prove: definitely not sent, maybe sent, or a real answer. They never retry an effect behind your back. Pair that evidence with idempotency keys and reconciliation, and money moves once.",
        seen: ["HTTP Gun", "Correio", "Saga", "Grind", "Fabric", "Decisions"],
      )
    RecordsAreTheTruth ->
      HabitInfo(
        n: 6,
        title: "Records are the truth",
        short: "Durable rows decide; telemetry only informs.",
        long: "Where something must be remembered, it’s written as a durable record you can query and recover from: job rows, workflow checkpoints, run records, append-only decision entries. Telemetry is best effort and may drop under load.",
        seen: [
          "Grind rows", "Saga checkpoints", "Fabric store", "Decisions entries",
        ],
      )
    PureCoreThinShell ->
      HabitInfo(
        n: 7,
        title: "Pure core, thin shell",
        short: "Logic as pure functions; processes just perform effects.",
        long: "The interesting logic is a pure function from state and event to new state and effects. A thin OTP process around it does the I/O. That makes the core easy to test, replay and run over different storage, in memory for tests, PostgreSQL in production.",
        seen: ["Relay reducer", "Fabric controller", "Decisions core"],
      )
  }
}

// THE OWNERSHIP SORTER --------------------------------------------------------

pub type Owner {
  Library
  YourApp
}

pub type Job {
  Job(task: String, owner: Owner, why: String)
}

pub const jobs = [
  Job(
    "Pooling and reusing HTTP connections",
    Library,
    "HTTP Gun’s pool process does this, with limits you configure.",
  ),
  Job(
    "Deciding whether to retry a failed payment call",
    YourApp,
    "HTTP Gun never retries on its own. It gives you evidence; you decide.",
  ),
  Job(
    "Keeping the conversation history with a model",
    YourApp,
    "LLM Wire is a wire library. The caller owns history, storage and the loop.",
  ),
  Job(
    "Encoding a provider request and enforcing size limits",
    Library,
    "LLM Wire’s prepare step validates and encodes before any network call.",
  ),
  Job(
    "Starting and stopping the PostgreSQL pool",
    YourApp,
    "Grind, Saga and Decisions adapters borrow your pool; they never own it.",
  ),
  Job(
    "Leasing a job so one node holds it at a time",
    Library,
    "Grind claims work with database leases and renews them on a reserved connection.",
  ),
  Job(
    "User accounts and session cookies",
    YourApp,
    "Hellhound checks identity and keeps tokens. Accounts and cookies stay yours.",
  ),
  Job(
    "Refreshing an expiring token shared by many callers",
    Library,
    "Hellhound refreshes near expiry and shares one refresh across concurrent callers.",
  ),
  Job(
    "Who may approve a refund over €500",
    YourApp,
    "Policy is application data, handed to Fabric or Decisions. The library enforces it.",
  ),
  Job(
    "Recording every verdict as an append-only entry",
    Library,
    "Decisions keeps the record; an occurrence’s status is a fold over its entries.",
  ),
  Job(
    "Exporting metrics to a dashboard",
    YourApp,
    "Sinal has no exporter or aggregation. Adapters and your app own those.",
  ),
  Job(
    "Email templates and wording",
    YourApp,
    "Correio validates, renders MIME and sends. What the email says is yours.",
  ),
]

// DEFINE ONCE, USE EVERYWHERE -------------------------------------------------

pub type Definition {
  JsonCodec
  TelemetryEvent
  McpTool
  JobWorker
  DecisionPoint
}

pub const definitions = [
  JsonCodec,
  TelemetryEvent,
  McpTool,
  JobWorker,
  DecisionPoint,
]

pub type DefinitionInfo {
  DefinitionInfo(
    label: String,
    package: String,
    name: String,
    tint: String,
    ink: String,
    what: String,
    uses: List(#(String, String)),
  )
}

pub fn definition(definition: Definition) -> DefinitionInfo {
  case definition {
    JsonCodec ->
      DefinitionInfo(
        label: "JSON codec",
        package: "JSON Blueprint",
        name: "Codec(User)",
        tint: "#DDF3F0",
        ink: "#0B4A45",
        what: "One description of a data shape: its fields, which are optional, which numbers are allowed.",
        uses: [
          #("encode", "turns a Gleam value into JSON"),
          #("decode", "admits JSON strictly, with a path to every error"),
          #("schema", "publishes a JSON Schema for the same shape"),
          #(
            "others",
            "LLM Wire, Relay and Fabric reuse codecs for structured answers and tool arguments",
          ),
        ],
      )
    TelemetryEvent ->
      DefinitionInfo(
        label: "Telemetry event",
        package: "Sinal",
        name: "Event(measurements, metadata)",
        tint: "#DDF3F0",
        ink: "#0B4A45",
        what: "A named event with typed fields, shared between the code that emits it and the code that observes it.",
        uses: [
          #("producer", "emits typed values"),
          #("observer", "receives the same typed values"),
          #(
            "Erlang/Elixir",
            "native :telemetry handlers see ordinary names and maps",
          ),
          #("spans", "start, stop and exception events around a piece of work"),
        ],
      )
    McpTool ->
      DefinitionInfo(
        label: "MCP tool",
        package: "Relay",
        name: "tool.Definition(input, output)",
        tint: "#EEE7FD",
        ink: "#3B1785",
        what: "A tool’s name, description and input and output codecs.",
        uses: [
          #("server", "declares the tool and runs your handler"),
          #("client", "calls it and gets a typed result back"),
          #("discovery", "peers see the generated schema"),
          #("agents", "a Fabric agent can mount it as a tool"),
        ],
      )
    JobWorker ->
      DefinitionInfo(
        label: "Job worker",
        package: "Grind",
        name: "Worker(input, output, error)",
        tint: "#FDF0DC",
        ink: "#6B3404",
        what: "A named job type with codecs for its input, output and error.",
        uses: [
          #("submit", "enqueue a typed input, now or later"),
          #("perform", "your handler receives the decoded input"),
          #(
            "storage",
            "a versioned contract; changed codecs show up as ContractMismatch",
          ),
          #("await", "read a typed outcome back"),
        ],
      )
    DecisionPoint ->
      DefinitionInfo(
        label: "Decision point",
        package: "Decisions",
        name: "Point(output)",
        tint: "#FCE7F3",
        ink: "#5E0B3A",
        what: "Where a recommendation becomes a released output: the output’s codec and the facts a policy may read.",
        uses: [
          #("policy", "versioned rules read only the declared facts"),
          #("card", "a person sees what the model saw"),
          #("gated tool", "accepts nothing but a released output"),
          #("learning", "tallies agreement per recommender version"),
        ],
      )
  }
}
