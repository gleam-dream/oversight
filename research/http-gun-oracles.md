# HTTP Gun reference and oracle ledger

## Evidence status

- Inspected on 29 September 2026 for the [HTTP Gun design](../http-gun-design.md). This is a reference-selection ledger, not an upstream parity report.
- The owner referred to "Rack cassette"; the repository previously selected in this work is [ReqCassette](https://github.com/lostbean/req_cassette).
- The listed source/README/test inspections were performed. No upstream suite, differential harness, new HTTP runtime experiment or benchmark was executed for this design-writing task.
- Production builders must record their exact selected tests and outcomes. A named file below is a candidate for comparison, not a claim that every test in it applies or passes.

## Pinned sources

| Reference            | Inspected revision                                                                                                                                | License                                                  | Role                                                                         |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Dream client, PR #68 | [c3ae1d341b0782aa89279151cf9afd6b7731b46e](https://github.com/TrustBound/dream/tree/c3ae1d341b0782aa89279151cf9afd6b7731b46e/modules/http_client) | MIT, LICENSE.md                                          | Buffered/streamed HTTP and recording scenarios; implementation pitfalls      |
| ReqCassette          | [cb0251ca394952de46007bb32f5051feb66e896e](https://github.com/lostbean/req_cassette/tree/cb0251ca394952de46007bb32f5051feb66e896e)                | MIT, LICENSE                                             | Sequential playback, matching, versions, binary fixture and mode behavior    |
| Gleam HTTPc          | [0f5f2fdc88d58740e8790991e7b18529ead7d85a](https://github.com/gleam-lang/httpc/tree/0f5f2fdc88d58740e8790991e7b18529ead7d85a)                     | Apache-2.0, LICENSE                                      | Small Gleam request/response surface using shared HTTP types                 |
| Mint                 | [fb850d3714e4d79b9112d8056fe87cfd96b84f21](https://github.com/elixir-mint/mint/tree/fb850d3714e4d79b9112d8056fe87cfd96b84f21)                     | Apache-2.0, LICENSE.txt                                  | Explicit connection state and status/headers/data/done observations          |
| Finch                | [3387d4be15d2d56ad18e878e62bea0e354385f15](https://github.com/sneako/finch/tree/3387d4be15d2d56ad18e878e62bea0e354385f15)                         | MIT, LICENSE.md                                          | Explicit startup, origin/policy pool isolation and protocol-specific pooling |
| Gun / Cowlib         | [Gun 2.6.0](https://github.com/ninenines/gun/tree/2.6.0), [Cowlib 2.20.0](https://github.com/ninenines/cowlib/tree/2.20.0)                        | Verify upstream copyright/license notices before copying | Selected transport implementation; protocol and resource behavior            |
| LLM Wire             | /code/gleam-dream/llm_wire, HEAD cc79a69 plus the local caller-owned-conversation/cassette working changes                                        | Apache-2.0 declared by gleam.toml; preserve file notices | Source donor and local regression behavior; not a production dependency      |

The LLM Wire working changes are not represented by its HEAD alone. Before porting, capture donor file hashes and the relevant diff or a committed source revision. A fresh clone at cc79a69 does not contain the same cassette/continuation-removal work. Inspect current Git state and preserve unrelated edits.

## Dream selection

- PR #68 was open at the inspected head. Use its pinned files rather than assuming the PR description or branch stays unchanged.
- Candidate cases: modules/http_client/test/recorder_client_test.gleam, empty_body_test.gleam, stream_non_streaming_response_test.gleam, stream_yielder_completion_test.gleam, start_stream_test.gleam, error_handling_test.gleam and redirect_test.gleam. File inventory was inspected; select individual contracts before adapting cases.
- Its [shim](https://github.com/TrustBound/dream/blob/c3ae1d341b0782aa89279151cf9afd6b7731b46e/modules/http_client/src/dream_http_client/dream_http_shim.erl#L202) appends received chunks to a list and sends requests without Gun flow options. Adopt useful observable HTTP scenarios, not that buffering strategy.
- Its [connection manager](https://github.com/TrustBound/dream/blob/c3ae1d341b0782aa89279151cf9afd6b7731b46e/modules/http_client/src/dream_http_client/dream_http_conn_manager.erl#L93) opens connections until the cap before reusing them. HTTP Gun instead reuses eligible capacity first.
- Its inspected lock resolves Gun 2.2.0/Cowlib 2.16.0. Do not copy that baseline.
- Method-insensitive stale retry and forwarding original headers through redirects require separate contracts. HTTP Gun initially follows no redirect and performs no automatic replay.
- The older [deferred Dream adoption note](../docs/implementation/api-control/dream-http-refinement.md) concerns a different local fork/profile. It is historical evidence, not authorization to adopt that fork or reopen upstream work.

## ReqCassette selection and deliberate differences

| Source and named case                                                                                                        | Observable law to consider                             | HTTP Gun disposition                                                                               |
| ---------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ | -------------------------------------------------------------------------------------------------- |
| test/req_cassette/sequential_matching_test.exs — identical requests return different responses in order                      | Preserve per-position responses for identical requests | Adopt ordered playback as the default, not ReqCassette's first-match default                       |
| Same file — sequential matching past end of cassette raises error                                                            | Exhaustion is explicit                                 | Typed exhaustion error; no live fallback                                                           |
| Same file — sequential matching with wrong request type at index fails                                                       | Match before advancing position                        | Additionally prove mismatch leaves the expected exchange available                                 |
| Same file — shared session with sequential: true works across processes                                                      | Explicit shared-session ownership                      | Scoped sessions; do not claim scheduler-independent assignment among concurrent identical requests |
| test/req_cassette/modes_test.exs — raises error when cassette doesn't exist; raises error when no matching interaction found | Strict replay failure                                  | Adopt; no record-if-missing behavior                                                               |
| Same file — records on first call, replays on subsequent calls                                                               | Mixed record/replay behavior                           | Deliberately exclude; recording and playback are distinct modes                                    |
| test/req_cassette/body_type_test.exs — encodes blob as base64; Blob body round-trip                                          | Binary fixture round trip                              | Adapt using exact HTTP body bytes; no automatic JSON re-encoding                                   |
| Same file — returns empty string for invalid cassette                                                                        | Permissive malformed-data fallback                     | Reject this behavior; malformed/missing/unknown data is a typed fixture error                      |

Inspected test names identify comparisons, not copied text or complete suite adoption. Generic HTTP fidelity requires response headers/trailers and termination states beyond our prior POST/SSE cassette.

## Lean client inspiration

- Gleam HTTPc's inspected README demonstrates direct composition with standard Gleam HTTP request/response records. Use it to challenge unnecessary constructor families and nominal request types. It is not the selected transport backend.
- Mint's inspected README makes connection state and separate status/headers/data/done observations explicit. Preserve those distinctions while HTTP Gun owns OTP process and resource lifetimes. Its stateless connection struct is not a reason to expose raw sockets or force callers to drive a protocol machine.
- Finch's inspected README separates explicit application startup from request construction and describes origin/tag-based pool isolation. Reuse the lifecycle and isolation questions, not its complete configuration surface or runtime.
- Finch candidate test paths verified in the pinned tree include test/finch/alpn_integration_test.exs, http1/pool_test.exs, http2/pool_test.exs and http2/integration_test.exs. Their bodies were not reviewed or executed in this task.
- Inspect and pin precise source/test cases before claiming Mint/Finch behavioral ports. Neither is a runtime dependency of HTTP Gun.

## LLM Wire donor inventory

| Existing area                                                     | Preserve or test                                                | Generalization needed                                               |
| ----------------------------------------------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------- |
| src/llm_wire_gun_ffi.erl                                          | Gun credits, monitored request lifecycle, TLS checks            | Generic methods/head/body/trailers; remove POST/200/SSE assumptions |
| src/llm_wire_gun_pool.erl                                         | Idle-first H1 reuse, bounded waiters and cleanup                | H2 stream leases/capacity, policy isolation and draining            |
| test/llm_wire_owner_test.gleam                                    | Copied handles, conflicting reads, timeout/delivery race        | Byte-body owner contract; real opening-credit test                  |
| test/llm_wire_pool_test.gleam                                     | Reuse, queue caps, shutdown, owner death                        | Existing cancellation isolation uses separate H1 connections        |
| test/llm_wire_integration_test.gleam                              | TLS, headers, fragmentation, disconnect                         | Generic non-SSE statuses/binary/trailer tests                       |
| src/llm_wire/cassette.gleam and test/llm_wire_cassette_test.gleam | Strict sequence, bounds, versions, mismatch without consumption | Generic binary HTTP format and actual recording                     |
| src/llm_wire/testing.gleam                                        | Explicit scripts and controlled interruptions                   | Keep synthetic LLM responses out of HTTP Gun                        |

The preceding task reported 208 passing LLM Wire tests, compiler/build checks, external consumer checks and formatting gates. Those results were not rerun here, and do not establish independent HTTP or H2 behavior.

## Transport facts to reproduce

- Both donor Gun paths select HTTP/1.1 explicitly. Enabling H2 alone does not change the exclusive-connection pool or close-on-cancel behavior.
- [Gun H2 data handling](https://github.com/ninenines/gun/blob/2.6.0/src/gun_http2.erl#L417) delivers data before decrementing credit; exhausted credit withholds stream window replenishment. Already-permitted DATA must fit the memory contract.
- Gun's inspected initial H2 receive-window defaults are 8,000,000 bytes for both connection and stream. Count/window/buffer limits must compose.
- [Gun H1 header/trailer parsing](https://github.com/ninenines/gun/blob/2.6.0/src/gun_http.erl#L252) can take a complete-block path before its buffered-size check. The donor's trailer callback additionally drops trailers without measuring them.
- [Cowlib's HTTP/2 machine](https://github.com/ninenines/cowlib/blob/2.20.0/src/cow_http2_machine.erl#L258) marks total header-list-size enforcement as unfinished. Header count and HPACK table bounds do not prove decoded-header byte bounds.
- These are source findings. Establish runtime regressions and retain exact dependency revisions before treating a repair as verified.

## Required construction ledger

For each claimed oracle case record: repository, immutable revision, license, source path and test name, scenario/setup, expected public observations, local test, normalization, evidence class, run command/result and deliberate difference.

Use distinct classes: inspected source; inspired local test; faithful adapted test; executed differential comparison. Do not substitute one class for another. Preserve attribution for copied or adapted code and tests. Network-dependent upstream suites must not become normal offline gates.

## Primary documentation

- [Gun 2.6 manual](https://ninenines.eu/docs/en/gun/2.6/manual/gun/) and [2.6 migration/security baseline](https://ninenines.eu/docs/en/gun/2.6/guide/migrating_from_2.5/).
- [OTP HTTPc documentation](https://www.erlang.org/doc/apps/inets/httpc.html): HTTP/1.1, persistent sessions and pull streaming already exist; one connection per request is not a valid premise.
- [Gleam conventions](https://gleam.run/documentation/conventions-patterns-and-anti-patterns/): shared core types, explicit results, qualified functions and explicit composition.
- HTTP semantics and framing: [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110), [RFC 9112](https://www.rfc-editor.org/rfc/rfc9112), [RFC 9113](https://www.rfc-editor.org/rfc/rfc9113). Consult their current errata and updates when selecting requirements. The construction agent selects exact requirements and tests; this ledger does not claim a full RFC conformance audit.
