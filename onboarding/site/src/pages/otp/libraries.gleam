//// The gleam-dream libraries that hand the reader's application a child to
//// place in its supervision tree, and what each brings.

pub type Library {
  HttpGun
  SinalForwarder
  Grind
  Saga
  FabricStore
  Hellhound
  Relay
}

/// In the order the tree lists them.
pub const all = [
  HttpGun,
  SinalForwarder,
  Grind,
  Saga,
  FabricStore,
  Hellhound,
  Relay,
]

pub type Info {
  Info(
    name: String,
    short: String,
    layer: String,
    tint: String,
    ink: String,
    brings: String,
    you: String,
  )
}

pub fn info(library: Library) -> Info {
  case library {
    HttpGun ->
      Info(
        name: "HTTP Gun",
        short: "outbound HTTP",
        layer: "Foundations",
        tint: "#DDF3F0",
        ink: "#0B4A45",
        brings: "A client pool process that admits requests and leases connections, plus one short-lived body-owner process for every open response.",
        you: "the client’s lifetime, its limits and which destinations it may reach.",
      )
    SinalForwarder ->
      Info(
        name: "Sinal forwarder",
        short: "telemetry off the hot path",
        layer: "Foundations",
        tint: "#DDF3F0",
        ink: "#0B4A45",
        brings: "An optional, bounded forwarder process. Observers of the event prefixes you route to it run there instead of inside the code that emitted the event.",
        you: "which event prefixes to route, and whether to use a forwarder at all.",
      )
    Grind ->
      Info(
        name: "Grind",
        short: "background jobs",
        layer: "Durable work",
        tint: "#FDF0DC",
        ink: "#6B3404",
        brings: "A runtime supervisor with one coordinator per queue, a short-lived attempt process per job run, and a lease renewer on its own database connection.",
        you: "the PostgreSQL pool, the queues and their concurrency, and who runs migrations.",
      )
    Saga ->
      Info(
        name: "Saga",
        short: "workflows",
        layer: "Durable work",
        tint: "#FDF0DC",
        ink: "#6B3404",
        brings: "One coordinator process per workflow run with bounded action workers. A local run is tied to its caller: if the caller exits, the run is cancelled.",
        you: "storage for durable runs, and when to drive, resume or cancel them.",
      )
    FabricStore ->
      Info(
        name: "Fabric store",
        short: "agent runs",
        layer: "Agents & oversight",
        tint: "#FCE7F3",
        ink: "#5E0B3A",
        brings: "A store that keeps run records and supervises the runners doing the work. A handle only addresses a run; dropping it does not cancel anything.",
        you: "the backend (memory, directory or PostgreSQL), model clients and policy.",
      )
    Hellhound ->
      Info(
        name: "Hellhound",
        short: "sign-in & tokens",
        layer: "Outside world",
        tint: "#EEE7FD",
        ink: "#3B1785",
        brings: "Supervised caches for identity-provider discovery and signing keys, with client handles that stay valid across restarts.",
        you: "accounts, session cookies and every permission decision.",
      )
    Relay ->
      Info(
        name: "Relay",
        short: "MCP server",
        layer: "Outside world",
        tint: "#EEE7FD",
        ink: "#3B1785",
        brings: "A runtime actor per server that keeps protocol state in order, plus an isolated worker for each tool call so one bad handler can’t take the server down.",
        you: "the HTTP listener or mount point, the token verifier and per-request context.",
      )
  }
}
