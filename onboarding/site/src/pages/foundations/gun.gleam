//// HTTP Gun: the five parts of a request, and the destination policy that
//// decides where a client may connect.

// ANATOMY ---------------------------------------------------------------------

pub type Part {
  YourProcess
  ClientPool
  BodyOwner
  GunConnections
  RecorderAndSinal
}

pub const parts = [
  YourProcess,
  ClientPool,
  BodyOwner,
  GunConnections,
  RecorderAndSinal,
]

pub type PartInfo {
  PartInfo(name: String, tiny: String, long: String)
}

pub fn part_info(part: Part) -> PartInfo {
  case part {
    YourProcess ->
      PartInfo(
        name: "Your process",
        tiny: "calls send, opens streams",
        long: "The caller. It sends a request and gets back either a collected response or a stream. Only the process that opened a streamed body may read it, which makes ownership of the bytes unambiguous.",
      )
    ClientPool ->
      PartInfo(
        name: "Client pool",
        tiny: "admits & leases",
        long: "One process per client. It admits each request against your limits and leases connection capacity. You start it linked to a caller or under your supervisor; many callers share it.",
      )
    BodyOwner ->
      PartInfo(
        name: "Body owner",
        tiny: "one per response",
        long: "A short-lived process per response that coordinates the exchange: buffering limits, deadlines, cancellation, trailers and closing. If a limit trips, you get a typed failure, not a stuck process.",
      )
    GunConnections ->
      PartInfo(
        name: "Gun connections",
        tiny: "the wire",
        long: "Gun, a mature Erlang client, speaks HTTP/1.1 and HTTP/2 with verified TLS and optional client certificates. HTTP Gun keeps Gun’s untyped messages away from your code.",
      )
    RecorderAndSinal ->
      PartInfo(
        name: "Recorder & Sinal",
        tiny: "optional",
        long: "A recorder can capture exchanges into cassettes (with common secrets redacted) for offline tests. Lifecycle events with request ids flow to Sinal observers.",
      )
  }
}

// DESTINATION POLICY ----------------------------------------------------------

pub type Policy {
  DefaultPolicy
  RequireTls
  LocalTests
}

pub const policies = [DefaultPolicy, RequireTls, LocalTests]

pub fn policy_label(policy: Policy) -> String {
  case policy {
    DefaultPolicy -> "Default"
    RequireTls -> "RequireTls"
    LocalTests -> "Local tests"
  }
}

/// Where an address really resolves.
pub type Reach {
  Public
  Loopback
  Private
}

pub type Transport {
  Encrypted
  Plaintext
}

pub type Destination {
  Destination(url: String, resolves: String, reach: Reach, transport: Transport)
}

pub const destinations = [
  Destination(
    url: "https://api.payments.example",
    resolves: "public address",
    reach: Public,
    transport: Encrypted,
  ),
  Destination(
    url: "http://api.payments.example",
    resolves: "public address, plaintext",
    reach: Public,
    transport: Plaintext,
  ),
  Destination(
    url: "http://127.0.0.1:4000",
    resolves: "loopback",
    reach: Loopback,
    transport: Plaintext,
  ),
  Destination(
    url: "https://reports.internal",
    resolves: "10.0.4.7 (private network)",
    reach: Private,
    transport: Encrypted,
  ),
  Destination(
    url: "https://cdn.example",
    resolves: "169.254.169.254 (cloud metadata)",
    reach: Private,
    transport: Encrypted,
  ),
]

pub type Verdict {
  Admitted(why: String)
  Refused(why: String)
}

/// The policy's verdict on one destination.
pub fn admit(policy: Policy, destination: Destination) -> Verdict {
  case destination.reach, destination.transport, policy {
    Public, Plaintext, RequireTls -> Refused("plaintext refused by RequireTls")
    Public, Encrypted, _ -> Admitted("public and encrypted")
    Public, Plaintext, _ -> Admitted("public; the default permits plaintext")
    Loopback, _, LocalTests -> Admitted("the test policy opted into loopback")
    Loopback, _, _ -> Refused("loopback must be opted into explicitly")
    Private, _, _ -> Refused("resolves outside the public internet")
  }
}
