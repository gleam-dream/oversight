# Relay and LLM Wire implementation dispatch

## Fourth-wave acceptance checkpoint

- Relay delivered subset accepted by independent review and committed as `6574f38`; 107 tests and 109 conformance checks passed. Full production authorization and other recorded scope remain deferred.
- LLM Wire delivered corrections accepted and committed as `cdfb38a`. The final oracle comparison caught and corrected assistant `input_text` versus required `output_text`; the independent reviewer verified the exact upstream assertions and all 133 tests passed.
- Both fourth-wave delivered subsets are committed. Full package scope remains incomplete as recorded in the reports. No implementation agents are running; the next recommended step is a small cross-package integration pilot.
- Prior test count of 133 did not establish oracle fidelity. Do not treat a related passing local test as an upstream port.

## Active gap-closing wave

- User authorized the next gap-closing wave with an explicit simplicity constraint and executable external-oracle test reuse.
- Work order: `wave4-work-order.md`. Baselines: Relay `c293b53`, LLM Wire `188c70b`.
- Luna XHigh coders `/root/relay_wave3_fixes` and `/root/llm_wave3_recovery` were resumed with the new work order under the established quota fallback. Sol Medium review follows.
- Both must produce WAVE-4-PROGRESS.md and WAVE-4-REPORT.md, including exact coverage, upstream test provenance and a concise register of capabilities requiring substantial additional machinery.
- Standard Gleam JSON remains the wire policy. No separate HTTP client package, strict JSON layer or speculative framework is authorized.

## Latest accepted delivery

- Both final focused reviews pass for the delivered subsets; full package scope remains incomplete.
- Relay committed at `c293b53`: 99 tests and 109 conformance checks pass, with the documented zero-check scenario caveat.
- LLM Wire committed at `188c70b`: 122 tests and external-package boundary verification pass. Provider wire JSON uses ordinary Gleam JSON; the separate strict parser and FFI are removed.
- Final reviews are `relay-wave3-final-review.md` and `llm-wire-wave3-final-review.md`. Each package includes its final review in REVIEW-STATUS.md.
- Both package working trees are clean. No push or publication occurred. No implementation or review jobs remain active.
- Remaining scope is recorded in package WAVE-3-REPORT.md, LLM Wire DESIGN-COVERAGE.md and the completion plan. Earlier status sections below are historical.

## Current checkpoint

- Next wave launched after the user restored external quota: two fresh `agy --sandbox --dangerously-skip-permissions` runs, configured default model, work order `wave3-work-order.md`.
- Execution session `78419`; Relay wrapper/agent PIDs `44261`/`44265`; LLM Wire wrapper/agent PIDs `44262`/`44266`. Both agents verified alive with empty startup stderr.
- Logs/status: `/private/tmp/gleam-dream-relay-wave3` and `/private/tmp/gleam-dream-llm_wire-wave3`, suffixes `.log`, `.stderr`, `.pid`, `.started`, `.exit`, `.finished`. Runner maps quota-error output to exit 75 rather than accepting a misleading exit 0.
- Both agents must maintain package-local `WAVE-3-PROGRESS.md` and deliver `WAVE-3-REPORT.md`. Independent Sol Medium review follows; no automatic acceptance on process completion.

- Final focused reviews accept the delivered correction subsets, not full Wave 2 or package completion.
- Relay committed at `20ad8af`: 88 tests and 106 pinned conformance checks pass, with one scenario emitting no checks. Final review: `relay-wave2-final-review.md`.
- LLM Wire committed at `e643755`: 92 tests and external-package boundary verification pass. Final review: `llm-wire-wave2-final-review.md`.
- Both package working trees were clean at dispatch. No push or publication occurred. The third-wave external agents are now running.
- Next implementation priority is the unfinished current scope: Relay subscription/listen and dynamic notifications, cache semantics, typed stdio client and lifecycle/TLS/interop evidence; LLM Wire connection reuse, header-bound guarantees, Google and expanded race/fragmentation/oracle coverage.
- Broader authorization, compatibility, extensions and release hardening remain in `COMPLETION-PLAN.md`; accepted corrections do not remove those capabilities.
- Earlier dispatch statuses below are historical.

- Dispatch date: 2026-09-20.
- Status: both external second-wave agents exhausted quota and stopped. User-authorized Luna XHigh replacement coders are continuing the existing trees directly. First-wave checkpoints remain unaccepted.
- Implementer: external `agy --sandbox --dangerously-skip-permissions`, configured default model, fresh conversation per repository.
- Planning and research: Sol XHigh. Independent implementation review: Sol Medium after delivery.
- Sibling dependencies are read-only. No commits, remotes, pushes, publishing, credentials, or live provider calls are authorized within these implementation runs.

| Run      | Work order                                       | Starting state                                           | Execution session | Local logs                                                             |
| -------- | ------------------------------------------------ | -------------------------------------------------------- | ----------------- | ---------------------------------------------------------------------- |
| Relay    | [relay-work-order.md](relay-work-order.md)       | `master`, `75ce50dd1ba180c382c239901ee8e0b8508070a3`     | `78300`           | `/private/tmp/gleam-dream-relay-wave1.log`, corresponding `.stderr`    |
| LLM Wire | [llm-wire-work-order.md](llm-wire-work-order.md) | `/code/gleam-dream/llm_wire`, unborn `master`, no remote | `59917`           | `/private/tmp/gleam-dream-llm-wire-wave1.log`, corresponding `.stderr` |

- Each implementer must write `WAVE-1-REPORT.md` in its own repository and await all validation before returning.
- Poll the existing execution sessions before starting another writer. Empty print logs alone do not prove a stalled run.
- Review the complete resulting tree, including staged and unstaged changes, against the work order before acceptance.
- Blueprint baseline is the user's `d3f0708b61eddb4a4789c0476ab5384267814a51`; Sinal baseline is `dd09933e5466628f7d46fa896c389f31ba7d4cb6`.
- Relay's first wave does not establish official HTTP conformance. LLM Wire's first wave does not establish complete provider parity or production readiness.

## Restart evidence

- Original execution sessions `78300` and `59917` are no longer available. Process inspection confirmed no corresponding implementation agents remained. Original logs and stderr are empty, so the termination cause is unknown.
- Relay retained only dependency changes in `gleam.toml` and `manifest.toml`. LLM Wire still had no package files. The restart explicitly preserves these changes and permits Relay's expected dirty tree.
- Restart command wrapper: `/private/tmp/gleam-dream-wave1-resume.sh`.
- Restart execution session: `33997`. Relay agent PID: `53044`; LLM Wire agent PID: `53045`, both independently verified alive after launch.
- Restart artifacts use `/private/tmp/gleam-dream-relay-wave1-resume` and `/private/tmp/gleam-dream-llm_wire-wave1-resume`, with `.pid`, `.started`, `.log`, `.stderr`, and on completion `.exit` and `.finished` suffixes.
- Each agent must maintain `WAVE-1-PROGRESS.md` in its package so buffered CLI output does not hide milestones.

## Implementation delivery

- Relay exited `0` at `2026-09-21 00:30:45 UTC`, reporting 52 passing tests plus schema, negative compiler, provenance and formatting checks. Delivery: `/code/gleam-dream/relay/WAVE-1-REPORT.md`.
- LLM Wire exited `0` at `2026-09-21 00:17:49 UTC`, reporting 43 passing tests plus compile and formatting checks. Delivery: `/code/gleam-dream/llm_wire/WAVE-1-REPORT.md`.
- Counts above are implementer claims pending independent verification. Both implementation processes are confirmed stopped. Changes remain uncommitted.
- Independent reviewers: `/root/relay_wave1_review` and `/root/llm_wave1_review`, both `gpt-5.6-sol` with medium reasoning as explicitly requested. Review reports will be `relay-review.md` and `llm-wire-review.md` in this directory.

## Second-wave dispatch

- Checkpoints: Relay `ce718db`, LLM Wire `e5b7b0b`. Both contain `REVIEW-STATUS.md` and are explicitly not accepted releases. Oversight handoffs and reviews committed at `dd511f8`.
- Work orders: `relay-wave2-work-order.md` and `llm-wire-wave2-work-order.md`; retained scope and four further waves per package are recorded in `COMPLETION-PLAN.md`.
- Both external agents launched with the configured default model and verified alive. Execution session: `47164`. Relay wrapper PID `76909`, agent PID `76914`; LLM Wire wrapper PID `76910`, agent PID `76913`.
- Runner: `/private/tmp/gleam-dream-wave2.sh`. Logs and completion markers use `/private/tmp/gleam-dream-relay-wave2` and `/private/tmp/gleam-dream-llm_wire-wave2`, with `.pid`, `.started`, `.log`, `.stderr`, `.exit`, `.finished` suffixes.
- Each agent must write `WAVE-2-PROGRESS.md`, resolve review defects with regression proof, continue through the larger capability scope, and report friction and improvements applied versus proposed in `WAVE-2-REPORT.md`.
- LLM Wire keeps a pure sans-I/O core. Relay uses a thin Mist server adapter. Both streaming HTTP clients prefer a maintained Gun dependency through a narrow typed FFI, with contract tests before acceptance. No custom HTTP parser expansion is authorized.

## Quota recovery

- Relay stopped at `2026-09-21 01:15:18 UTC`; LLM Wire stopped at `2026-09-21 01:14:45 UTC`. Both stderr logs explicitly report individual quota exhaustion. Both runners misleadingly returned exit `0`; neither is a completed delivery.
- Process inspection confirmed both external agents stopped before replacement. Partial tracked and untracked changes are retained; no reset or new checkpoint was performed.
- User explicitly requested Luna XHigh replacement coders. `/root/relay_wave2_luna` and `/root/llm_wave2_luna` now implement directly with `gpt-5.6-luna`, reasoning `xhigh`, without invoking the exhausted external service.
- The same substantial work orders remain in force, including review fixes, full wave scope, meaningful regression tests, progress reports, and friction/improvement reporting. Independent acceptance reviews remain Sol Medium.
