# Relay and LLM Wire implementation dispatch

- Dispatch date: 2026-09-20.
- Status: both first-wave reviews failed acceptance. Deliveries are committed as checkpoints; larger second-wave implementation agents are running.
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
