# Relay Wave 2 work order: complete modern server, HTTP and client basics

## Assignment

Work only in `/code/gleam-dream/relay`. Use a fresh external `agy` conversation
with `--sandbox --dangerously-skip-permissions`, the configured default model,
no model override, and the absolute agent-lsp path
`/etc/profiles/per-user/edgar/bin/agent-lsp`. Read `relay-design.md`,
`PUBLIC-API.md`, the Relay rows in `API-COVERAGE.md`, Wave 1's order/report, and
`COMPLETION-PLAN.md`. Do not edit sibling repositories or use GitHub, remotes,
publishing, credentials, or live network services.

Start from checkpoint `ce718db` and read the repository's `REVIEW-STATUS.md` and
oversight's `docs/implementation/relay-llm-wire/relay-review.md`. Turn every
finding into a failing regression test, fix it, rerun the Wave 1 gate, and
record each finding as resolved. Reviewer cure labels are suggestions; choose
the smallest sound repair inside the authorized design without pausing for a
routine implementation or dependency choice. Do not continue with new scope
while a correctness, security, ownership or claim finding remains.

## Mandatory Wave 1 repairs

- Add Git to the reproducible dev shell and make the two sibling provenance
  tests pass inside it. Preserve exact Blueprint and Sinal revisions.
- Preserve exact Blueprint JSON numbers end to end. Do not round them through a
  Gleam `Float`, stringify them, or parse/re-encode through a lossy `Dynamic`.
- Replace the stdio FFI's `io:get_line` path with bounded chunk reads. Enforce
  `max_chunk_bytes` before allocating/appending the violating chunk; retain
  split UTF-8, LF/CRLF, EOF, and frame bounds. Add real pipe tests proving the
  configured chunk bound, not only the pure framer's bound.
- Reject a tool during registry construction when its output schema is
  unavailable or outside the modern MCP profile. Listing and successful output
  must derive from the exact retained admitted schema. Add a regression proving
  the handler cannot run after failed admission.
- Wire request-admitted Sinal observations into the accepted runtime path;
  redact crash reasons; propagate broken-stdout and startup failures as typed
  terminal outcomes rather than discarding them or asserting.
- Validate present client-info and progress-token metadata fully. Add real
  process tests for partial reads/UTF-8, multi-frame chunks, frame limit, EOF,
  broken owner/child/stdout, crash and timeout, with repeated race runs and
  process/mailbox cleanup assertions.
- Correct every discrepancy between implementation claims, tests, README and
  actual behavior found by review.

## Capability delivery

Complete the retained MCP `2026-07-28` server surface in coherent vertical
slices: rich text/image/audio content, resource links and embedded resources;
resources and templates list/read; prompts list/get; completion; progress and
cancellation; logging; opaque pagination and invalid cursor outcomes; cache
fields; subscriptions/listen and change/update notifications; dynamic registry
changes; and multi-round input. Each family retains its own typed codecs,
capability requirements and errors through heterogeneous registration. Do not
route unrelated methods through one untyped handler.

Implement Streamable HTTP through a thin Mist 6.x runtime adapter around the
framework-neutral protocol boundary; do not build another HTTP server or make
Mist the protocol owner. Pin its exact version, checksum and license. Use
`mist.stream`/`read_body` for bounded request consumption and Mist chunked/SSE
primitives for bounded response delivery, while Relay owns admission, MCP
headers, cancellation and semantic backpressure. Enforce body limits before parsing,
media negotiation, case-insensitive and encoded headers, final
`MCP-Protocol-Version`/`Mcp-Method`/`Mcp-Name` agreement, Origin and Host
allow-lists, DNS-rebinding defenses, request-scoped SSE, disconnect
cancellation, bounded response streaming and backpressure. Modern HTTP is
POST-only and has no initialize, GET stream, DELETE session, or
`Mcp-Session-Id`. Use local loopback peers only.

Primary dependency evidence: [Mist 6.0.3](https://mist.hexdocs.pm/mist.html)
publishes bounded `read_body`, pull-style `stream`, `send_chunk`, SSE, supervised
startup and TLS APIs. These APIs justify the thin server adapter; the local
fault and backpressure tests remain the acceptance authority.

Replace the typed-client TODO with usable modern basics. Reuse a maintained
HTTP client rather than a raw TCP parser; prefer a thin Gun 2.x adapter because
its stream references, request `flow`, `update_flow`, `cancel`, `reply_to`, TLS
and connection ownership map directly to Relay's bounds and cancellation. A
narrow Erlang FFI may translate Gun messages and calls into typed Gleam values;
it must not parse MCP JSON or leak Gun terms into the public API. If a different
published dependency is chosen, prove the same pull/credit, cancellation, TLS,
reuse and owner-death behavior with local tests and record why it is better.
Deliver revision discovery,
typed method/result pairs, typed tool references, explicit raw checked-JSON
calls, list traversal, tools call outcomes, correlation, response bounds,
timeouts, cancellation, close, and server-era pinning over both HTTP and stdio.
Structured success, content-only success, tool failure, protocol failure,
transport failure and cancellation remain distinct. Do not add provider or LLM
concepts.

[Gun 2.2](https://ninenines.eu/docs/en/gun/2.2/manual/) is the verified client
candidate: its official API is asynchronous and exposes per-stream identity,
request flow control, `update_flow`, `cancel`, `reply_to`, TLS and reusable
connections. It requires a thin typed Erlang FFI because no retained Gleam
binding proves all of those ownership properties.

Keep authorization honest. This wave may expose an explicitly local/unprotected
server and an injected verifier seam, but it must not claim production resource
authorization, issue grants from raw claims, or bypass the protected-registry
path. Production resource and client authorization remain Wave 3.

## Tests and acceptance

- Continue red-green-refactor. Owned modules run together; use real OTP actors,
  sockets, pipes, monitors and timers rather than mocks.
- Preserve standard JSON envelopes and revision-specific codecs. Blueprint is
  confined to schema-bearing tool values. Sinal events follow committed state
  and never control it.
- Add official-schema positives and single-mutation negatives for every modern
  message family, plus property tests for codec round trips, cursor isolation,
  response correlation and terminal suppression.
- Add races for disconnect/completion/cancel, simultaneous calls, list mutation,
  subscription close, timeout and owner death. Assert cleanup and bounded
  mailbox/process counts.
- Run the pinned official `2026-07-28` server requirements against the real HTTP
  endpoint. Required failures are blockers; no expected-failures baseline or
  selected scenario may support a conformance claim. Record requirements not
  covered by the harness and their local tests.
- Exercise the typed client against local Relay, pinned TypeScript and pinned
  Python fixtures where practical without credentials. Record interoperability
  pins and licenses.

The gate is:

```text
nix develop --command gleam format --check src test
nix develop --command gleam check --target erlang
nix develop --command gleam test --target erlang
nix flake check
git diff --check
```

Also run Relay's negative fixture, provenance/checksum, official schema and
frozen conformance commands. Return `WAVE-2-REPORT.md` with exact results,
review-finding closure, API map and the complete capability ledger. Every
retained design row must point to implementation evidence, its exact Wave 3–5
owner, or a genuine contract collision requiring a user scope decision. Report
implementer friction and distinguish improvements actually applied from those
only proposed. Stop only for a genuine design-contract collision; make routine
dependency, framework, module and test-fixture choices within this order.
