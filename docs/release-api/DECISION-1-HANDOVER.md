# Decision 1 handover: durability ownership

Status on 4 October 2026: **open**. This is the only release decision the owner has not taken. It is a recommendation to the owner, not a change to make unasked.

## The question

Three packages run durable work, each with its own lease, recovery and cancel model:

| Package | Durable unit                                                       | Ownership model                                                                |
| ------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------------ |
| grind   | a job, delivered at least once                                     | PostgreSQL queue claim (`SKIP LOCKED`), retries, snooze                        |
| saga    | a workflow execution with compensation                             | an exclusive claim on one execution through a `Storage` port (`saga_postgres`) |
| fabric  | an agent run, and a graph run (signals, forks, job polling, waits) | compare-and-set records, leases, and a sweeper that recovers abandoned runs    |

When one request crosses all three, as in `apps/research_agent` (a grind job drives a fabric run whose tool runs a saga), it runs under three leases, three recoveries and three cancel paths. Which package owns what, and how they hand work to each other?

## Already settled (don't reopen)

- **Decision 2 (owner):** the graph runtime stays in fabric and ships in fabric 1.0. This rules out decision 1's former option B (moving the graph runtime to `fabric_graph`).
- **The connecting points that cut most of research_agent's glue are built:**
  - caller-supplied run ids (`fabric.start(id:)`, `run.id_from_parts`; a job derives its run id);
  - one correlation through every package (`sinal/correlation`);
  - `tool.with_replay`;
  - `fabric.cancel_when_down`;
  - grind's `JobContext` (cancellation, attempt, correlation);
  - saga steps reading the run's correlation;
  - the durable correlation saved by saga.

## What is still open

1. **Who recovers a grind-driven fabric run?** Today both grind (job lease expiry, retry) and fabric's sweeper (abandoned-run recovery) can act on it. The previous recommendation was: the job is the driver, and fabric's sweeper stays off for that run.
   - Is there an API to mark a run as externally driven? Today it is "don't register it with the sweeper".
   - Who then enforces fabric's 7-day approval and graph-wait expiry? Today an expired approval on such a run is noticed only when something reads or commands it.
2. **Two durable graph-ish runtimes.** Both saga's runner and fabric's graph runtime run multi-step durable work with recovery. Is that overlap acceptable for 1.0 (record it in both designs and say when to use which), or should one build on the other later?
3. **A shared durability layer** (store, lease, sweeper, ids) under all three. The earlier analysis said no for 1.0: the three leases have different invariants, and the public API guidelines forbid sharing an abstraction whose invariants differ. Revisit only with evidence.
4. **A `fabric_grind` integration**, so a grind worker drives a fabric run with the job id as run id, cancellation from the job context and the sweeper off. Ship it in 1.0, or leave it as app code (research_agent's `jobs.gleam` is the reference)?

## Options to present to the owner

- **A. Keep today's split and make the hand-offs explicit.** Record ownership in each design: grind delivers, saga runs compensating workflows, fabric runs agents and agent graphs. Add the "externally driven run" contract (item 1), and either ship `fabric_grind` or document the recipe. Least work; it fits decision 2.
- **A with saga convergence later.** Same as A, plus a written note on when fabric graphs and saga workflows might converge after 1.0, with no 1.0 work.
- **C. A shared durability layer.** The largest change; it delays every release. Only if a fresh look finds the invariants really match.

A previous agent leaned towards A. Check that independently.

## Evidence to read first

- [DECISIONS.md §1](DECISIONS.md) (stale: its option B is ruled out), and §2 for the owner's outcome.
- [fabric.md §7 Q1](fabric.md); [PLAN.md](PLAN.md): the wave 5 and round 7 results, and the follow-ups that mention decision 1.
- `apps/research_agent` (src/research_agent/jobs.gleam, researcher.gleam, FEEDBACK.md): the real three-package composition, with OTP-peer crash-recovery tests.
- The fabric repo: `docs/migration-wave-5.md` (slices F1, F2, F5), `docs/OPERATIONS.md` and `src/fabric/sweeper.gleam`. grind's `worker.Context` and abandonment policy; saga's `durable` module and `DURABILITY.md`.
- [/code/gleam-dream/oversight/fabric-design.md](../../fabric-design.md) and [saga-design.md](../../saga-design.md): the original ownership statements; fabric-design.md carries the 3 October release-decision note.

## Working rules

- The deliverable is a recommendation: options, trade-offs and one recommendation, as in DECISIONS.md. Don't implement before the owner decides.
- Prototypes may go in this repo (`oversight`), never in the package repos.
- After the owner decides, any implementation follows the release rules in `README.md` (conventions 1–10). Each package's full gate must pass, then all eight apps (`apps/scripts/with-postgres.sh`) on the final heads, before anything is pushed. Push in dependency order. Hex publication, upstream contact and provider credentials need the owner's explicit approval.
