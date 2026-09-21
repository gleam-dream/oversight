# Relay and LLM Wire completion program

Status: continuation plan after the reviewed Wave 1 checkpoints. Relay starts at
`ce718db`; LLM Wire starts at `e5b7b0b`. These commits preserve evidence; they
do not constitute Wave 1 acceptance.

## Shared rules

- The main thread orchestrates. Fresh external `agy` implementers use
  `--sandbox --dangerously-skip-permissions`, their configured default model,
  no model override, and `/etc/profiles/per-user/edgar/bin/agent-lsp`.
- A SolMedium reviewer independently checks every wave. The implementer fixes
  every finding and supplies a regression test before new capability work is
  accepted. Cure-class labels and redesign suggestions in a review are advice,
  not new requirements or reasons to seek approval; repair the finding within
  the authorized contracts unless a real contract collision is proved.
- Keep `/code/gleam-dream/json_blueprint` at
  `d3f0708b61eddb4a4789c0476ab5384267814a51` and `/code/gleam-dream/sinal` at
  `dd09933e5466628f7d46fa896c389f31ba7d4cb6`, via local path dependencies.
  Do not edit either sibling.
- Ordinary JSON envelopes use standard Gleam JSON. Blueprint owns schema-aware
  tool and structured-output contracts. Sinal observes transitions after their
  owner commits them.
- No live provider calls, credentials, push, PR, publish, remote creation, or
  repository URL invention. Local loopback peers and pinned upstream fixtures
  are required.
- Routine choices within the accepted design belong to the implementer. Return
  only genuine contract collisions: changed ownership, public invariant,
  protocol meaning, dependency source, or full-scope exclusion.
- Maintain one capability ledger per repository, initialized from every
  non-superseded capability in its design, public API and API coverage. Every
  row has exactly one state: `implemented` with a public test or conformance
  evidence link; `deferred` with one exact wave and owner; or `decision
required` with the concrete contract collision for the user. A scaffold,
  TODO, syntax-only decoder, selected scenario, green unit suite or
  expected-failure baseline is never implementation evidence. Wave 5 cannot
  claim completion while any row remains deferred or undecided. Optional scope
  may be removed only by an explicit user decision recorded in the ledger.

## Relay: four remaining waves

| Wave | Required outcome                                                                                                                                                                                                  | Acceptance proof                                                                                                                                                                                                                              |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2    | Resolve every Wave 1 review finding; complete the modern server families; add real Streamable HTTP; add typed client basics over HTTP and stdio                                                                   | Frozen-schema corpus, process/race/fault tests, complete modern server requirement run where the official harness applies, typed client round trips against local peers, ledger evidence for each delivered row                               |
| 3    | Resource-server and MCP-client authorization; complete `2025-11-25` handshake/session compatibility                                                                                                               | Frozen auth requirements, malicious metadata/token fixtures, protected-route bypass tests, independent 2025-11-25 server/client requirement runs                                                                                              |
| 4    | Complete remaining supported revisions and retained extensions: resources/prompts/subscriptions/completion edge behavior, Tasks, Apps, DPoP/workload identity where their pinned contracts apply; public test kit | Per-revision codecs and lifecycle tests, extension pins/provenance, paired transport/fake clock/scripted peer consumers                                                                                                                       |
| 5    | Release hardening and packaging                                                                                                                                                                                   | All supported-revision server/client/auth suites clean without baselines; TypeScript/Python interoperability; fuzz/soak/churn/cancellation/backpressure/OTP 27–28; docs/API audit; no executable TODOs, deferred rows or unresolved decisions |

Relay Wave 1 claims do not survive review by assertion. Known defects already
requiring repair are: Git absent from the dev shell causing two provenance tests
to fail; stdio reading through `io:get_line` rather than enforcing the configured
chunk bound before allocation; and tool registration accepting unavailable
output schemas. Wave 2 begins with these repairs and all additional findings in
`relay-review.md`.

## LLM Wire: four remaining waves

| Wave | Required outcome                                                                                                                                                                                                                                                                                                                 | Acceptance proof                                                                                                                                                                                                               |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 2    | Resolve every Wave 1 review finding; correct stream invariants; provide usable preparation, buffered, streaming, continuation, tool and structured-output APIs; production HTTP/TLS adapters for OpenAI and Anthropic; add Google now only if the same transport and semantic contracts can be proved without weakening the wave | Blueprint admission before tool-call completion, exact call/result correlation, local TLS peers, provider fixtures, deadline/backpressure/cleanup/race tests, public consumer examples, ledger evidence for each delivered row |
| 3    | Google if not justified in Wave 2; multimodal content, embeddings, reasoning, prompt caching, usage, provider option admission and retry policy                                                                                                                                                                                  | Provider-specific capability matrices and fixtures; no silently dropped option; no retry after observed output/effect ambiguity                                                                                                |
| 4    | WebSocket/realtime, batch/background operations, remote cancellation, persistable provider continuation and Sinal observations                                                                                                                                                                                                   | Local protocol peers, restore/version incompatibility tests, cancellation ownership and resource cleanup proofs                                                                                                                |
| 5    | Adapter evaluation and release hardening                                                                                                                                                                                                                                                                                         | ReqLLM FFI spike retained or rejected with measurements; differential fixtures; fuzz/soak/leak/OTP 27–28; docs/API audit; no executable TODOs, deferred rows or unresolved decisions                                           |

Google belongs in Wave 2 only if its current API can reuse the completed HTTP/TLS
ownership, request preparation, stream grammar and continuation seams. If it
requires a materially different transport or continuation contract, record that
evidence and deliver it in Wave 3; this is sequencing, not removal from scope.

## Per-wave record

Each repository appends a wave report containing: starting head and dirty state;
review findings and regression proofs; behavior delivered; public API changes;
upstream pins/licenses; exact gates; the complete capability ledger; implementer
friction; improvements actually applied versus merely proposed or rejected; and
the next wave's concrete entry condition. Green tests authorize no production
readiness claim without corresponding conformance, interoperability, security,
resource-ownership and release evidence.
The main thread commits accepted coherent waves; implementers and reviewers do
not commit.
