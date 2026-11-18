//// Every term from the course, filterable by text and by group, and the
//// cheat sheet of when to reach for each library.

import gleam/list
import gleam/string

/// Where a term comes from: the runtime, a principle or a library.
pub type Tag {
  Beam
  Otp
  GleamLanguage
  Principle
  JsonBlueprint
  Sinal
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
}

pub fn tag_label(tag: Tag) -> String {
  case tag {
    Beam -> "BEAM"
    Otp -> "OTP"
    GleamLanguage -> "Gleam"
    Principle -> "principle"
    JsonBlueprint -> "JSON Blueprint"
    Sinal -> "Sinal"
    HttpGun -> "HTTP Gun"
    LlmWire -> "LLM Wire"
    Relay -> "Relay"
    Hellhound -> "Hellhound"
    Correio -> "Correio"
    Grind -> "Grind"
    Saga -> "Saga"
    Fabric -> "Fabric"
    Decisions -> "Decisions"
    Retrace -> "Retrace"
  }
}

/// Background and ink of a tag, by the layer it belongs to.
pub fn tag_colours(tag: Tag) -> #(String, String) {
  case tag {
    Beam -> #("#EBEAFD", "#2B2862")
    Otp -> #("#DCD9FF", "#241F6B")
    GleamLanguage -> #("#F9D7F0", "#4A1340")
    Principle -> #("#17162B", "#FFFFFF")
    JsonBlueprint | Sinal -> #("#DDF3F0", "#0B4A45")
    HttpGun -> #("#E0E9FD", "#163A8A")
    LlmWire | Relay | Hellhound | Correio -> #("#EEE7FD", "#3B1785")
    Grind | Saga -> #("#FDF0DC", "#6B3404")
    Fabric | Decisions -> #("#FCE7F3", "#5E0B3A")
    Retrace -> #("#E2F4E7", "#0E4D25")
  }
}

pub type Group {
  AllTerms
  Runtime
  Principles
  Libraries
}

pub const groups = [AllTerms, Runtime, Principles, Libraries]

pub fn group_label(group: Group) -> String {
  case group {
    AllTerms -> "All"
    Runtime -> "BEAM · OTP · Gleam"
    Principles -> "Principles"
    Libraries -> "Libraries"
  }
}

fn in_group(tag: Tag, group: Group) -> Bool {
  let runtime = tag == Beam || tag == Otp || tag == GleamLanguage
  case group {
    AllTerms -> True
    Runtime -> runtime
    Principles -> tag == Principle
    Libraries -> !runtime && tag != Principle
  }
}

pub type Term {
  Term(term: String, tag: Tag, definition: String)
}

pub const terms = [
  Term(
    "Process",
    Beam,
    "A tiny isolated unit of work with its own memory. Millions can run at once.",
  ),
  Term(
    "Mailbox",
    Beam,
    "The queue of messages a process handles one at a time.",
  ),
  Term(
    "Link",
    Beam,
    "Ties two processes’ fates: when one dies, the other gets an exit signal.",
  ),
  Term(
    "Monitor",
    Beam,
    "A one-way watch: you get a message when the other process goes down.",
  ),
  Term(
    "Preemptive scheduling",
    Beam,
    "Every process gets a small work budget, then must step aside.",
  ),
  Term(
    "Actor",
    Otp,
    "A process with private state that handles messages in a loop (gen_server).",
  ),
  Term(
    "Supervisor",
    Otp,
    "Starts children and restarts them by strategy; escalates if restarts happen too often.",
  ),
  Term(
    "Restart strategy",
    Otp,
    "One for one, one for all, or rest for one: which children restart together.",
  ),
  Term(
    "Subject",
    GleamLanguage,
    "A typed address: it only accepts messages of one type.",
  ),
  Term(
    "Result",
    GleamLanguage,
    "Ok(value) or Error(reason): failure as an ordinary value.",
  ),
  Term(
    "Custom type",
    GleamLanguage,
    "A type with variants, each carrying exactly the data its case needs.",
  ),
  Term(
    "Codec",
    JsonBlueprint,
    "One definition that encodes, strictly decodes and publishes a JSON Schema.",
  ),
  Term(
    "Forwarder",
    Sinal,
    "A bounded process that runs observers off the hot path; drops and counts when full.",
  ),
  Term(
    "Destination policy",
    HttpGun,
    "Rules on where a client may connect, checked against resolved addresses.",
  ),
  Term(
    "Cassette",
    HttpGun,
    "A recorded set of exchanges replayed offline in tests, with secrets redacted.",
  ),
  Term("NotSent", Principle, "Provably never left your machine. Safe to retry."),
  Term(
    "MaybeSent",
    Principle,
    "May have reached the other side. Retry only with an idempotency key, or reconcile.",
  ),
  Term(
    "Idempotency key",
    Principle,
    "A stable id for an effect so a repeat is recognised and not done twice.",
  ),
  Term(
    "Reconcile",
    Principle,
    "Ask an authoritative source what really happened, then record it.",
  ),
  Term(
    "Prepare",
    LlmWire,
    "Validate and encode a request with no network, before spending tokens.",
  ),
  Term(
    "Verifier",
    Relay,
    "Your function that decides whether a bearer token is admitted.",
  ),
  Term(
    "Token custody",
    Hellhound,
    "Keeping a user’s tokens safe and refreshed under an opaque session.",
  ),
  Term(
    "Sender",
    Correio,
    "An injected function that delivers a message: SMTP, Postmark or a test capture.",
  ),
  Term(
    "Lease",
    Grind,
    "A time-limited database claim on a job, so only one node runs it.",
  ),
  Term(
    "Transactional admission",
    Grind,
    "Submitting a job inside your own transaction: both commit or neither.",
  ),
  Term(
    "Uncertain",
    Grind,
    "A job whose effect is unknown; it waits for an audited resolution.",
  ),
  Term(
    "Compensation",
    Saga,
    "Undoing known completed steps, newest first, when a later step fails.",
  ),
  Term(
    "Hold",
    Saga,
    "Pausing a run whose effect can’t be proven, for your app to reconcile.",
  ),
  Term(
    "Checkpoint",
    Saga,
    "Saved progress that lets a durable run resume after a crash.",
  ),
  Term(
    "Policy gate",
    Fabric,
    "Your function deciding Allow, Deny, RequireApproval or HandOver for each action.",
  ),
  Term(
    "HandOver",
    Fabric,
    "The action belongs to another system; the run ends and the tool never runs.",
  ),
  Term(
    "Store",
    Fabric,
    "Keeps run records and supervises runners; memory, directory or PostgreSQL.",
  ),
  Term(
    "Decision point",
    Decisions,
    "Where a recommendation must pass policy, and maybe a person, before release.",
  ),
  Term(
    "Occurrence",
    Decisions,
    "One recommendation about one subject, kept as append-only entries.",
  ),
  Term(
    "Undo window",
    Decisions,
    "A hold before release during which a decider may withdraw.",
  ),
  Term(
    "Release",
    Decisions,
    "Handing the final output to the gated tool, at most once.",
  ),
  Term(
    "Protected observation",
    Retrace,
    "A replay strategy that adopts recorded, validated observations.",
  ),
]

/// The terms in a group whose name, definition or tag contains the query,
/// ignoring case.
pub fn filter(query: String, group: Group) -> List(Term) {
  let query = string.lowercase(query)
  list.filter(terms, fn(term) {
    in_group(term.tag, group)
    && string.contains(
      string.lowercase(
        term.term <> " " <> term.definition <> " " <> tag_label(term.tag),
      ),
      query,
    )
  })
}

// CHEAT SHEET -----------------------------------------------------------------

pub type Entry {
  Entry(package: Tag, when: String, remember: String)
}

pub const cheat_sheet = [
  Entry(
    Sinal,
    "report typed facts and observe them, or keep slow observers off the hot path",
    "best effort; names are atoms; no exporter included",
  ),
  Entry(
    JsonBlueprint,
    "describe a JSON shape once: encode, strict decode, schema",
    "errors carry JSON paths; byte limits for untrusted text",
  ),
  Entry(
    HttpGun,
    "call HTTP APIs with pooling, limits, streaming and test cassettes",
    "never retries; NotSent / MaybeSent; loopback is opt-in",
  ),
  Entry(
    LlmWire,
    "make one typed, bounded model call; structured output; classification",
    "you own history, tool execution and retries",
  ),
  Entry(
    Relay,
    "expose typed tools over MCP, or call an MCP server",
    "outcomes: succeeded, refused, needs input; your verifier",
  ),
  Entry(
    Hellhound,
    "sign users in with OIDC, hold OAuth tokens, validate JWTs",
    "pre-production; accounts and cookies are yours",
  ),
  Entry(
    Correio,
    "send transactional mail; magic links and email codes",
    "four outcomes; no outbox: pair with Grind",
  ),
  Entry(
    Grind,
    "run durable background jobs on PostgreSQL",
    "submit in your transaction; rows are the truth",
  ),
  Entry(
    Saga,
    "run dependent steps with retries, undo and checkpoints",
    "undoes only known successes; holds the unknown",
  ),
  Entry(
    Fabric,
    "run a bounded agent or durable graph behind a policy gate",
    "handles don’t own runs; uncertain effects block",
  ),
  Entry(
    Decisions,
    "gate an output with versioned policy and people, release once",
    "Git-only for now; autonomy grows by data",
  ),
  Entry(
    Retrace,
    "record and replay a Lustre session from typed events",
    "experimental; privacy decided at capture",
  ),
]
