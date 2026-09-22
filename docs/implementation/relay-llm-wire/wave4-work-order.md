# Gap-closing implementation wave

## User direction

- Close retained capability gaps with the simplest implementation that meets an actual contract. Do not add defensive requirements, general frameworks, alternative standard libraries or speculative extension points merely because they could be useful.
- Ordinary Gleam JSON handles provider wire data. Blueprint handles JSON Schema domain values and validation. Do not restore duplicate-key hardening or the removed strict JSON abstraction.
- Prefer supported APIs of established dependencies. Keep sans-I/O logic separate from thin runtime adapters. No new general-purpose HTTP client package in this wave.
- If a capability requires substantial complexity, custom infrastructure, dependency forks, or divergent implementations, record the concrete requirement, minimal alternatives, cost and recommendation for end-of-wave review. Continue independent simple work. Do not silently remove capabilities or claim unfinished work complete.

## Baselines and workflow

- Relay baseline: `c293b53`; LLM Wire baseline: `188c70b`. Read each repository's instructions, latest report, final review and coverage ledger. Preserve any newer user changes.
- Main orchestrates; Luna XHigh coders implement under the user's quota fallback. Independent Sol Medium review follows. No commits, push, publication, remote changes, real credentials or live provider calls by coders.
- Edit only the assigned package. Oversight and sibling dependencies are read-only. Use the current pinned Blueprint/Sinal APIs and compatible Mist/Gun dependencies.
- Write WAVE-4-PROGRESS.md immediately and update at meaningful milestones. Use TDD for behavior, await checks synchronously, and send milestones/blockers to the coordinator.

## Relay priorities

- Finish typed stdio subscription/notification handling and replace checked-JSON declaration results with useful typed tool/resource/prompt declaration models where required by the retained API.
- Close remaining modern feature admission and cache behavior against the pinned protocol, with real client/server examples.
- Implement resource-server and client authorization using established BEAM dependencies where appropriate, plus explicit `2025-11-25` revision compatibility. Do not force legacy behavior into the modern codec. Keep protected/unprotected capability claims honest.
- Complete practical public test helpers, official-peer client interoperability and missing owner-death/process cleanup evidence.
- Assess retained Tasks/Apps and other extension requirements using their pinned contracts; implement coherent supported portions and identify any substantial independent subsystem needed. Optional specification features are not automatically removed from our retained scope.
- Modern `ping` must follow the actual frozen schema, not a stale work-order sentence. Document that reconciliation rather than inventing a wire method.
- The prior arbitrary handler-JSON logging emitter was rejected by automatic approval review. Do not recreate it or circumvent the rejection. Keep this exact blocked capability visible and continue independent work.

## LLM Wire priorities

- Add typed multimodal content, embeddings, prompt caching, and the required provider-specific option/usage/reasoning/stop matrix across the supported adapters. Unsupported combinations fail explicitly before transport.
- Preserve Google thought signatures and other required opaque provider continuation state without exposing mutable credentials or conflating provider IDs with application IDs.
- Add durable/versioned continuation representation, bounded retry policy only where replay safety is established, and complete relevant lifecycle observations.
- Assess and implement retained batch/background, remote cancellation and realtime capabilities where existing dependencies make a small coherent implementation possible. Flag a separate complex transport/state machine for review instead of building a speculative framework.
- The strict response-header pre-allocation requirement is unresolved. Establish whether a concrete protocol/security requirement and upstream precedent justify it. Report the actual dependency bound, feasible alternatives and cost; do not fork Gun or add a second parser solely to satisfy an internally invented number without coordinator/user decision.
- Expand race/fragmentation/lease cleanup coverage through real local peers and targeted oracle cases. Do not invent strictness beyond actual contracts.

## Oracle and conformance obligations

- Reuse existing pinned official MCP conformance and schema suites in Relay, without filtering failures to obtain a pass. Add pinned TypeScript/Python SDK client interoperability cases where relevant.
- For LLM Wire, select matching test groups from Jido/ReqLLM, LangChain provider integrations, official SDKs or another established relevant implementation. Prefer primary sources and tests that cover the actual provider features being implemented; popularity does not override provider semantics or our typed contract.
- Record exact repository/revision, test path/case, license and attribution for copied or ported cases. Preserve fixtures where licensing permits. Distinguish directly run upstream tests, ported behavioral cases, locally authored regressions, and reference-only material.
- Integrate useful cases into normal executable gates. A link or inventory alone is not test reuse. Adapt assertion plumbing to Gleam while retaining the behavior under test. Avoid copying an entire irrelevant suite or expanding production APIs to satisfy implementation-specific tests.
- Include meaningful malformed inputs, cancellation, resource cleanup, provider differences and concurrency boundaries. Do not replace actual upstream assertions with substring checks or passing placeholders.

## Delivery

- Run applicable formatting, compiler, tests, external-package boundary probes, provenance, schema/negative fixtures, pinned conformance and flake gates. Report exact commands/results and scope limits.
- WAVE-4-REPORT.md must distinguish implemented/tested capabilities, concrete blockers, remaining planned scope and complexity candidates for user review. Include public consumer examples and the oracle mapping with executable local case names.
- Include a short complexity register: requirement/source; proposed machinery; standard alternative; why the simple option does or does not work; estimated maintenance burden; implement/defer recommendation. Do not turn this into a generic architecture exercise.
- Full package completion requires evidence for retained capabilities. A green gate alone is not full completion. Do not self-accept or ask the user to approve vague unfinished alternatives.
