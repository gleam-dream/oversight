# Compose decision points through three applications

<a id="adr-0033"></a>

Recorded on 2026-11-15.

## Decision

- The `decisions` library joins the ecosystem with three packages:
  - `decisions`, a pure core: the decision point, the occurrence record, the desk and its verbs, policy as data, the card document and learning.
  - `decisions_otp`: an in-memory process-safe store, a supervised runtime, isolated model calls, parallel replay and live hints.
  - `decisions_postgres`: the storage port over PostgreSQL, its migrations, and the Grind workers that deliver wake-ups and settlement notices.
- The `decisions` repository owns the detailed design of the three packages. Oversight owns the compositions.
- Oversight retains three applications as consumer evidence for the packages:
  - `clinic_registration` uses PostgreSQL, one LLM Wire call with structured output, Grind jobs and a JSON desk over Wisp.
  - `payout_desk` gates a Fabric agent's tool call. People decide over Relay tools behind Hellhound verification, and a released payout runs as a Saga delivered by Grind.
  - `moderation_desk` runs the `decisions_otp` runtime with no database: a cascade of isolated models, a live desk of processes, and a replay gate on new policy versions.

## What the applications establish

- **No package depends on the joined libraries.** Fabric, LLM Wire and Relay join `decisions` through application recipes. No `decisions` package depends on them.
- **One pool and one transaction.**
  - In the two PostgreSQL applications, Grind owns the one pool. The application tables, `decisions_postgres`, and (in `payout_desk`) Fabric and Saga borrow it.
  - Each desk verb runs in the caller's transaction, together with the application's own writes and the Grind submissions.
- **The record decides time, never delivery.** A wake-up or settlement notice delivered by Grind or the OTP runtime only asks a verb to compare the store clock with the record. The tests move the store clock instead of waiting.
- **The release key bounds an effect outside the database.**
  - A gated tool writes the database effect in the releasing transaction.
  - An effect outside the database runs after settlement under the release key: a message in `clinic_registration`, a payment in `payout_desk`.
  - An uncertain outcome is reported as uncertain. A later lookup by the release key settles it, and the effect is never repeated.
- **A gated tool says whether it refuses or could not tell.** Its guard, release check and executor answer `decisions.Stop`:
  - `Refuse` is a judgment about the release. With a validator present the verdict's transaction rolls back and a separate transaction records the refusal; the occurrence keeps waiting. With nobody waiting, as at the end of a hold, the occurrence ends refused.
  - `Unsure` says the tool could not tell, such as after a failed query. The release rolls back, nothing is recorded as refused, and the verb fails as retryable. `payout_desk` shows a guard that lost its connection at a hold's wake-up: the wake-up is delivered again and the payout is paid once.
- **A runtime acts on the library's classification alone.** A follower or job handler returns `decisions.HandlerFailure`. A contended or unknown commit is delivered again uncounted; a retryable refusal, such as `ToolUnsure`, or an application failure is counted toward setting the job aside; a refusal that needs an operator sets the job aside at once; a final refusal ends the job.
- **Start-up follows the PostgreSQL adapter's order.** Both PostgreSQL applications migrate the tables on a pool of their own before any worker polls, build the store from Grind's name and the desks over its port, register the workers on Grind's configuration, start Grind, and then sweep. The sweep admits a job for every pending wake-up and undelivered settlement notice that has none, so a lost or pruned job does not lose a wake-up. Both applications test this by restarting without the jobs.
- **A policy version is published data.**
  - The application stores its policy versions and the desk reads the newest one.
  - Publication requires the library's publishability check.
  - The application decides when a candidate version is published.
- **A card is opened only by a validator who may decide it.** `open` refuses whoever `decide` would refuse, such as the requester, and the card counts approvals per alternative of its eligibility. `clinic_registration` uses a tally from the record. `moderation_desk` uses a replay of the recorded examples against a threshold.

## Rationale and consequences

- An occurrence record joins the recommendation, the people's verdicts, the release and the reported effect. Each library involved owns one of the processes around those facts: Fabric the run, LLM Wire the provider exchange, Grind the delivery, Saga the workflow. A separately compiled consumer is the place where wrong ownership of a fact becomes visible.
- Three applications cover the three storage and runtime choices: PostgreSQL with one model call, PostgreSQL with an agent and a workflow, and the in-memory runtime.
- The application decisions that a reader would otherwise rediscover are recorded in [ADR 0035](0035-answer-a-gated-agent-call-from-the-decision-point.md#adr-0035) and [ADR 0036](0036-restart-the-in-memory-decision-store-empty.md#adr-0036). The source selection is recorded in [ADR 0034](0034-consume-the-decisions-packages-by-path-until-published.md#adr-0034).
