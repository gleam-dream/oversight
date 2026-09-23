# Grind implementation handoff

## Assignment and ownership

- Implement the first usable PostgreSQL-backed Grind release in `/code/gleam-dream/grind`. Inspect existing files, Git state, and repository instructions before editing; preserve unrelated changes. Create the package directory if absent, but do not replace an existing repository.
- Own Grind only. Read `/code/gleam-dream/oversight` as the design source; do not modify sibling packages. Saga is assigned independently, so Grind must run without Saga or Fabric.
- Deliver working behavior through TDD, not only scaffolding or a signature prototype. Aim for three substantial reviewable increments, adjusting their boundaries when evidence requires it.

## Required context

- Read `PUBLIC-API-GUIDELINES.md`, `grind-design.md`, `ECOSYSTEM-PLAN.md`, and the Grind section of `API-COVERAGE.md` in Oversight.
- Read `research/grind-execution-contract.md`, `research/grind-uniqueness-contract.md`, and `research/composition-contracts.md`. Inspect relevant interface-laboratory evidence, especially `WORKER-OUTCOMES.md`, `CLAIM-OWNERSHIP.md`, and `UNIQUE-JOBS.md`.
- Load the applicable Gleam, TDD, environment, and Git skills. Use the configured LSP and reproducible development shell. Older laboratory signatures establish experiments, not a requirement to reproduce their incidental complexity.

## First-release scope

- Provide typed worker definitions, heterogeneous registration, persisted argument admission, scheduled execution, and typed job handles where results are available. Derive worker identity and serialization details from definitions rather than repeating them at each call.
- Implement PostgreSQL storage and supervised Erlang/OTP queue execution with validated configuration and bounded concurrency. Use established database and OTP libraries; avoid speculative storage or actor frameworks.
- Implement the designed attempt outcomes (success, business failure, snooze, discard, cancellation, uncertainty), retry/backoff policy, ownership claims, renewal, takeover, and acknowledgement. Keep returned worker outcomes distinct from committed job outcomes.
- Implement the conservative typed uniqueness profile and its explicit conflict outcomes. Preserve submission reconciliation across uncertain commits. Admission uniqueness must not be described as exactly-once execution.
- Include scheduling, shutdown, recovery, and package-owned Sinal lifecycle observations for committed transitions. Keep diagnostic content separate from policy decisions.
- Preserve the complete capability inventory as backlog. SQLite, raw job workflows, Saga integration, cron/plugins, broader replacement and uniqueness policies, batches, chunking, recorder extensions, and Pro-equivalent capabilities are not silently removed by this PostgreSQL slice.

## Public API constraints

- Keep configuration pure, composable, and validatable before starting actors or opening connections. Use ordinary settings records where appropriate and opaque admitted values where an invariant requires them.
- Accept caller-owned records and errors. Bind typed operations before hiding heterogeneous implementation state; do not require ordinary callers to manage Dynamic or private state type parameters.
- Use ordinary JSON codecs for persistence. Require version information where stored-format compatibility needs it, and derive facts already owned by definitions. Blueprint is optional only when JSON Schema belongs to the actual domain.
- Do not require an error codec for a generic discarded error. If an error must survive persistence or typed retrieval, its serialization is a real contract and must be explicit. Distinguish stored operational information from details intentionally exposed to callers.
- Keep one obvious common path and advanced entry points only for distinct capabilities. State resource ownership, cleanup, cancellation behavior, and the exact enforcement point for every claimed limit.

## Oracle preparation

- Use Oban OSS `v2.24.1` as the pinned behavioral oracle. Inspect the actual tagged source and tests, resolve and record its commit, and retain applicable licenses and notices when adapting material.
- Build a small runnable Elixir/Oban reference harness alongside the Gleam tests. Run both against isolated local PostgreSQL databases or schemas with equivalent initial conditions; never use a user's application database. Record the exact commands, versions, configuration, and normalization rules.
- Before implementing each behavior, identify the upstream test or source contract that motivates it. Maintain an oracle ledger with source path/test name, trigger, expected observations, local test, evidence category, and deliberate differences.
- Distinguish tests ported from upstream, differential executions against upstream, tests inspired by upstream, and original Grind contracts. Never count a related happy-path test as a faithful port. An unavailable oracle run remains unverified, not passing.
- Preserve documented differences: typed key equality differs from Oban's selected-field containment; Grind exposes explicit stale/unknown outcomes and conservative replacement. Test each system against its intended contract rather than forcing equality where the designs differ.
- Do not claim Oban Pro parity from public descriptions. Pro-equivalent work requires an original observable contract or legitimately available licensed oracle; it remains deferred from this delivery.

## TDD execution

- Work behavior by behavior: write a failing public test, run it to confirm the intended failure, implement the smallest coherent solution, then refactor while preserving the result. Establish a compiling API sketch first if needed, but do not write the whole implementation before its tests.
- Record representative red-to-green evidence for each delivered behavior family. A compilation error in a draft test is not evidence that the intended behavior failed.
- Use pure tests for transition rules and real PostgreSQL tests for transactional claims, uniqueness, receipts, and recovery. Mocks cannot prove database atomicity or crash recovery.
- Use explicit synchronization and controlled clocks where supported. Exercise database-authoritative time at its real boundary; do not replace all timer and database behavior with a simulated clock. Avoid timing assertions that depend on arbitrary sleeps.
- Verify competing claims and one live owner, renewal followed by acknowledgement, takeover fencing, exact expiry, cancellation before and after completion, retry exhaustion, snooze accounting, shutdown with active work, worker death, and queue-owner restart.
- Verify concurrent unique admission, period boundaries, state eligibility, queue scope, retained conflict identity, rescheduling eligibility, lock contention, and uncertain admission followed by reconciliation. Reuse the pinned research's decisive cases.
- Inject failures around commit boundaries. Unknown acknowledgement must not authorize blindly rerunning an external effect; expose reconciliation evidence. Document the unavoidable crash window between an effect and its acknowledgement.
- Verify codec/version rejection, invalid configuration before resource acquisition, capacity release, and cleanup after test failures. Exercise independent queue consumers against the same database where distributed ownership is claimed.

## Suggested increments

- First: establish the reference harness and typed admission-to-execution path against real PostgreSQL. Demonstrate one worker end to end, including a structured failure, and keep the oracle ledger current.
- Second: implement attempt ownership, retry/recovery, cancellation, bounded concurrency, and fault scenarios. Verify committed state rather than only returned values.
- Third: implement conservative uniqueness and reconciliation, complete scheduling and shutdown coverage, add Sinal observations, and verify the external consumer. Revisit earlier increments when a failing integration exposes a contract error.
- Start the external consumer in the first increment and grow it with each capability. Do not defer all composition evidence until the package is otherwise complete.

## External-consumer acceptance

- Create a separate package using only Grind's public imports. Register two differently typed workers, enqueue and observe a job, configure an advanced queue policy, handle application and storage failures, and exercise retry or cancellation.
- Include a deterministic synthetic effect with an application-owned deduplication key to demonstrate recovery without claiming the queue itself guarantees exactly-once effects. Verify no internal imports, repeated worker metadata, or mandatory Saga/Blueprint dependency.
- Make test infrastructure disposable and scoped. Use local synthetic data; do not contact paid services or publish packages.

## Review and delivery

- Report progress at each implementation milestone, including concrete friction, unexpected complexity, and remaining uncertainty. If a requirement needs substantial machinery, explain the mechanism and alternatives before broadening scope; continue independent work rather than silently weakening the contract.
- If using subagents, use GPT-6 Luna Max for implementation and GPT-6 Sol XHigh for planning or independent review. Do not use Astra subagents.
- Run formatting, compiler, tests, database integration, the external consumer, and applicable repository gates. Have an independent reviewer examine ownership races, oracle fidelity, public ergonomics, and misleading guarantees; address blocking findings.
- Commit accepted increments locally with semantic messages. Do not push, tag, or publish. Finish with commit hashes, reproducible commands, passing and unrun checks, oracle coverage, deliberate differences, deferred capabilities, and any unresolved acceptance decision.
