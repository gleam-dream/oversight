# Relay and LLM Wire: complete the remaining core scope

## Dispatch

- Use external `agy --sandbox --dangerously-skip-permissions`, configured default model, with a fresh conversation in each repository.
- Relay starts at `20ad8af`; LLM Wire starts at `e643755`. Preserve any newer changes and report them rather than resetting.
- Read the target repository's AGENTS.md, WAVE-2-REPORT.md, REVIEW-STATUS.md, and relevant design, PUBLIC-API.md, API-COVERAGE.md and COMPLETION-PLAN.md in Oversight. Read the final independent review and the preceding findings. Prior acceptance covers delivered subsets only.
- Work only in your target repository. Oversight, Blueprint and Sinal are read-only. Use their existing pinned dependency revisions.
- Use Gleam guidance and TDD. Use `/etc/profiles/per-user/edgar/bin/agent-lsp` when working; compiler and tests remain authoritative. Do not reinstall tooling or change sibling constraints to make a dependency fit.
- Keep the established sans-I/O cores and thin Mist/Gun adapters. Ordinary JSON uses standard Gleam JSON; Blueprint is reserved for schema-bearing contracts. Do not build a new HTTP client package in this wave.
- No commits, pushes, publication, remote changes, live provider calls, or real credentials. Public upstream research/dependency retrieval and local test peers are allowed. Independent Sol Medium review follows delivery.

## Relay scope

- Finish modern subscription/listen routing and lifetime, resource and list-change notifications, dynamic registry updates, and typed client methods for those capabilities. Wire actual sources and transport lifetimes; a standalone store is insufficient.
- Complete modern feature admission, annotation declarations, remaining request families, and cache semantics against the pinned specification. Preserve revision-specific behavior; do not transplant legacy methods into the modern codec.
- Complete the typed stdio client alongside HTTP, including correlation, cancellation, deadlines, rich results, bounded reads, process ownership and cleanup.
- Add local TLS, hostile/malformed peer, owner/child-death and concurrent close tests. Add pinned official-peer interoperability fixtures for the implemented client surface. Keep dependencies/version/license provenance explicit.
- Extend the official-schema corpus to every newly delivered wire family. Run the entire existing pinned server conformance suite without filtering or expected-failure baselines; explicitly retain its zero-check scenario caveat.
- Preserve synchronous producer-to-socket backpressure and prompt disconnect cancellation. Do not regress the held-writer/burst-disconnect tests or idle-stdin/broken-stdout behavior.
- The arbitrary handler-JSON logging emitter was rejected by automatic approval review and reverted. Do not recreate it or take an indirect route. Keep it unadvertised and report the precise blocked capability while completing independent scope.
- Authorization and legacy compatibility remain subsequent planned scope. Do not advertise protected deployment before those contracts are implemented and tested.

## LLM Wire scope

- Implement Google buffered/streaming calls through the same prepared interaction, schema-admission, terminal outcomes, continuation and transport contracts. Research primary provider documentation and use deterministic local fixtures; preserve provider-specific semantics rather than hiding mismatches.
- Add explicit connection reuse/lease ownership for Gun. Prove that closing/cancelling one stream cannot cancel another; bound pool resources, verify owner death and shutdown, and retain absolute deadlines. Keep runtime optional to the pure core.
- Resolve the strict response-header allocation requirement through the actual dependency capabilities. Research and reproduce the complete-header-in-one-read case. Do not claim a post-parse check is a pre-allocation bound and do not write a second HTTP parser. If the dependency cannot meet the contract without modification, record a concrete blocked decision with evidence and continue independent work.
- Expand adversarial provider and transport tests: every split point for representative complete provider interactions, interleaved calls, duplicate JSON members, argument disconnects, hosted-effect ambiguity, close/death/deadline races, slow consumers, concurrent leases and no leaked processes/mailboxes.
- Finish the selected oracle-file case inventory with actual upstream pins, cases, license provenance and local coverage mappings. Do not pad test counts with implementation-mirroring assertions.
- Preserve exact schema projection, terminal-only executable tool batches, opaque originating continuation, PreparedCall-only transport access and external dependent-package negative probes.
- Cover admitted provider options and usage/stop/refusal/reasoning behavior consistently across the supported adapters. Explicitly retain broader multimodal, embeddings, realtime/background and release-hardening scope in the completion ledger rather than silently dropping it.

## Delivery and evidence

- Start by writing WAVE-3-PROGRESS.md and update it after every meaningful milestone or blocker. Do not stop after planning, one fix, or a scaffold; complete the substantial scope above as far as the authorized contracts allow.
- Make routine implementation choices autonomously. Stop dependent work only for a genuine contract collision or permission rejection; continue independent tasks.
- Run all applicable package gates synchronously: Gleam formatting, Erlang compile and tests, flake check, diff check, and package-specific external boundary, schema, negative fixture, provenance and conformance checks. Await all child jobs before ending the run.
- Write WAVE-3-REPORT.md containing actual outcomes and commands, delivered public API examples, each previous gap's disposition, exact remaining capability rows and owner/wave, upstream provenance, friction, improvements applied versus proposed, and any approval/tool limitation.
- Report partial completion plainly. An exit code, green unit suite or passing conformance subset alone does not establish full package completion.
