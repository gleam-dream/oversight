# HTTP Gun implementation prompt

Use this document as the assignment for a coding agent with no prior conversation context.

## Assignment

Build an independent, production-quality Gleam package named http_gun on Erlang/OTP, backed by Gun. It must serve ordinary HTTP applications, bounded buffered requests, response streaming, HTTP/2 multiplexing, strict disk cassette playback, and bounded live recording through one composable client contract.

The package must be useful without LLM Wire, Fabric, Relay, Blueprint or any other Gleam Dream runtime package. LLM Wire is a future consumer and a source donor. Do not create a renamed LLM transport that still assumes POST, successful status 200, UTF-8, JSON or SSE.

Own /code/gleam-dream/http_gun. Inspect the directory and its repository instructions/Git state before editing. Create it if absent; preserve existing work if present. Read /code/gleam-dream/oversight as the design source. Do not modify sibling production packages, publish, push, contact upstream maintainers or use live provider credentials for this assignment.

## Required context

Read these files in /code/gleam-dream/oversight:

1. AGENTS.md and PUBLIC-API-GUIDELINES.md.
2. http-gun-design.md, which owns behavior, scope, lifecycle and required guarantees.
3. research/http-gun-oracles.md, which pins references and records differences.
4. The HTTP Gun entries in ECOSYSTEM-PLAN.md, PUBLIC-API.md and API-COVERAGE.md.
5. research/http-gun-interface-probe.md for the limits of any facade compiler evidence.

Inspect /code/gleam-dream/llm_wire, especially its Gun bridge/pool, client/transport/owner, scripts/cassettes and corresponding tests. The inspected donor is HEAD cc79a69 plus uncommitted caller-owned-conversation and cassette changes. Record current revision and file hashes before reusing source; HEAD alone is not that snapshot. Do not overwrite, reset or commit another task's work.

Use the Gleam, library API, TDD, data/state modeling and implementation skills available in the environment. Use the repository's reproducible toolchain. Keep pure configuration separate from runtime startup, and use standard Gleam HTTP types.

## Required independent release

Complete the required-release rows of http-gun-design.md. They include:

- General HTTP/1.1 methods and binary request/response values, final status/headers, duplicate headers, empty-body semantics, informational-response handling and trailers.
- Buffered send implemented by bounded collection of the same streaming body path.
- Owned pull streaming with shared copied-handle state, typed read conflicts, deadline/read-timeout arbitration, scoped cleanup, cancellation and caller/owner death handling.
- Explicit client/supervision lifecycle, verified TLS, custom trust, bounded origins/connections/streams/waiters and policy-isolated pools.
- Real HTTP/2 negotiation, stream multiplexing, peer capacity changes, draining/GOAWAY and sibling-safe cancellation.
- Typed errors and live/playback-tagged delivery evidence. Ordinary HTTP statuses remain response data. No automatic replay of an ambiguous request.
- Generic scripted HTTP, a binary-capable versioned cassette, strict ordered matching, explicit errors and no network fallback.
- Actual bounded live recording with redaction policy, status/headers/body/trailers, Complete/Failed/LocallyCancelled outcomes, storage errors and atomic finalization.
- Independent public consumers, documentation, executable gates, truthful coverage and oracle provenance.

The first H1 milestone is not completion. Playback without recording is not completion. An H2 option without same-connection tests is not completion.

Retain follow-on scope (uploads, redirect policy, decompression, proxies/mTLS, cookie/cache adapters and optional generic SSE) in CAPABILITIES.md. These do not have to ship in this assignment unless required by a concrete accepted consumer. Do not quietly claim that Gun support implements them.

## Implementation constraints

- Keep Gun/Cowlib as the transport baseline; start from the inspected 2.6.0/2.20.0 combination and recheck patched compatible versions. Record the selected versions and OTP matrix.
- Use one ordinary client contract for live, playback and recording. Select it at application startup. No global cassette, hidden mode environment variable or process-dictionary lookup.
- Keep provider reducers, schema validation, tool calls, token usage, semantic retry assessment and agent continuation outside http_gun.
- Reuse HTTP request/response records rather than inventing equivalents. Opaque client/body/session handles enforce lifetime invariants. Errors must contain useful structured context without exposing secrets.
- Keep no unbounded eager reader between Gun and the consumer. Demand flows from the consumer to the HTTP body owner to Gun. Writer demand participates in that same resource contract during recording.
- Separate H1 connection leases from H2 stream leases. Do not close a healthy H2 connection merely because one stream is cancelled.
- Preserve meaningful selected request headers in matching. Do not serialize credentials by default. Document that request/response bodies and URL queries can contain sensitive data.
- Do not invent success status, EOF, timestamps, provider cancellation acknowledgement or server execution evidence.
- Do not silently turn malformed fixtures into empty responses, follow redirects, decompress, resend a POST, or switch from playback to network.
- Keep the public configuration smaller than Gun's option map. Add an advanced knob only when a named test or consumer needs it.
- Preserve relevant copyright/license notices for reused production code and adapted tests.

## TDD stages

### 1. Independent contract and ordinary HTTP

Establish the package, a reproducible development environment and a separate consumer package using public imports only. Prove the common task, advanced configuration, caller-owned records/errors and explicit failure handling.

Implement real local-server GET/POST/HEAD, binary payloads, empty-body responses, ordinary non-200 statuses, duplicate headers and trailers. Use failing observable tests before implementation. Keep the facade compiler experiment separate from production code.

### 2. Streaming, lifecycle and bounds

Implement the authoritative body owner, bounded collection, read conflicts, copy semantics, close/deadline races and cleanup. Port relevant donor tests to the generic boundary.

Add real regressions for complete/fragmented oversized headers and trailers, initial-credit accounting, stalled consumers, partial disconnect and client/owner death. Measure actual Gun/bridge/consumer mailboxes and memory where a memory guarantee is claimed.

Gun flow=1 is not a one-chunk/byte guarantee under H2. Do not rely solely on fake transport callbacks. Audit parser/window limits and write each guarantee with its enforcement point and bounded overshoot allowance.

If Gun/Cowlib needs a parser fix, produce a minimal reproducer and a narrow attributable patch or dependency proposal. Do not silently weaken the requirement, change backend or call the release ready. Continue unrelated work and report the precise unresolved gate if external approval or upstream change is required.

### 3. Generic scripts and strict playback

Use the same response head/body/trailer admission and body lifecycle as live HTTP. Validate binary encodings, versions, lengths, limits and terminal tags.

Prove identical requests receive distinct sequential responses; mismatches do not consume; missing/corrupt/exhausted fixtures never open a socket; header matching and redaction are consistent. Scope concurrent flows explicitly and bound diagnostic history. Document any legacy LLM fixture converter separately.

### 4. Real recording and persistence

Record exchanges against a local test server, save them, and replay through an unchanged consumer. Preserve success, HTTP error status, partial transport failure and local cancellation.

Test early LLM-style termination before HTTP EOF without secretly draining. Test slow disk, writer failure after request submission, recording limits, finalization while busy, crash before commit, replacement policy, redaction across chunk boundaries and invalid output after transformation. Report HTTP outcome separately from capture persistence.

### 5. HTTP/2 and concurrency

Use a controlled H2 server. Verify negotiated protocol and shared connection identity, then prove sibling cancellation, changed peer capacity, draining/GOAWAY, reset and connection loss.

Exercise slow and fast consumers together. Account for receive windows and in-flight bytes, not just callbacks. Test failure around submission and ensure no hidden POST replay.

Run a reproducible concurrency experiment at 1/10/100/1000 streams where feasible. Record socket count, BEAM memory, mailbox lengths and p95/p99 latency with machine/runtime/server configuration. State practical test limits; a benchmark is not an absolute performance promise.

### 6. Integration and release acceptance

Keep the independent ordinary HTTP consumer. Add a public LLM integration consumer or disposable checkout that maps HTTP observations to LLM Wire without moving provider semantics into http_gun. Do not mutate the user's llm_wire working tree.

Document construction, supervision, buffered/streamed use, cleanup, limits, failures and one startup-time live/record/playback switch. Provide a separate LLM Wire migration guide identifying moved code and retained tests.

Finish the required scope, resolve gate failures, and remove temporary scaffolding or duplicate networking paths. Do not stop at a passing unit suite when real transport obligations remain open.

## Oracle work

Use the pinned Dream client and ReqCassette sources, plus Gleam HTTPc, Mint and Finch as scoped references. The donor llm_wire suite supplies local contracts. None is a mandate for blanket parity.

Before each behavior family, identify upstream cases, the intended observations and differences. Maintain a ledger distinguishing source inspection, inspired tests, faithful adapted tests and executed differential comparisons. Run selected upstream/local-server cases when useful; record exact versions and commands. An unrun comparison remains unverified.

In particular, reject Dream's uncredited push buffering and creation-first H2 pooling; reject ReqCassette's default first-match reuse and malformed-data-to-empty fallback for this design. Preserve their useful scenarios in stronger local tests.

## Validation and definition of done

Provide one documented command for fast checks and one full release gate. The full gate includes:

- Formatting, Gleam check/build/tests and FFI compilation with meaningful warnings handled.
- Real H1/TLS/H2 transport and lifecycle tests.
- Recording/playback round trips and failure/persistence tests.
- Separate external-consumer builds and compile-negative opacity/type fixtures.
- Dependency/public-module checks proving no forbidden sibling imports or local-path production dependencies.
- Oracle ledger checks, selected executed comparisons and explicit unverified cases.
- Resource-bound evidence and reproducible concurrency measurements.
- Package metadata, license/notices, supported runtime policy and CI reproducing the gates.

Use isolated local servers and temporary fixtures. Normal gates must need neither provider credentials nor live Internet endpoints. Avoid arbitrary sleeps when synchronization or controlled faults can establish ordering.

Deliver working source, tests, examples, README, CAPABILITIES.md, provenance/oracle ledger, migration notes and gate commands. In the final report state what works, what remains deferred, exact validation outcomes and any blocker. No production-readiness claim while a required release guarantee remains unverified.
