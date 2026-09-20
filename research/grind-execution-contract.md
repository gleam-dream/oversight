# Grind worker outcomes and attempt ownership

## Question and status

- The experiment asks how queued execution can preserve typed business results while expressing scheduling decisions and rejecting stale completion.
- Existing ordinary workers and `invoke` remain usable outside queue execution. New scheduling responses adapt ordinary results rather than forcing every business function to know about a scheduler.
- This note proposes a pure resolution experiment followed by an ownership-aware acknowledgement experiment. It does not establish a queue runtime.

## Oracle and deliberate differences

- The reference is [Oban.Worker 2.24.1](https://oban.hexdocs.pm/2.24.1/Oban.Worker.html) and the [Basic engine at v2.24.1](https://github.com/oban-bg/oban/blob/v2.24.1/lib/oban/engines/basic.ex).
- Oban completes on `:ok` or `{:ok, value}`, retries returned errors until the attempt limit, and schedules snoozed work without consuming a retry attempt. Its snooze path tracks a separate snooze count.
- Oban supports worker-directed cancellation. Explicit discard remains accepted but is deprecated in favor of cancellation.
- Grind retains the native success type because typed recorded results are part of its intended interface. Oban does not make the value in `{:ok, value}` a typed queue result.
- Oban Basic guards acknowledgement updates with executing state and the fetched attempt timestamp, but does not expose a distinct stale-update outcome to its caller. Grind's proposed explicit stale and unknown-commit results are stronger interface choices, not claims of exact Oban behavior.

## First constructive boundary

- Add one `WorkerResponse(output, error)` with success, failure, snooze, discard, worker-directed cancellation, and uncertain-outcome variants.
- Add `from_result(Result(output, error))` so an ordinary function or existing worker can enter that response boundary.
- Keep scheduling directives in the response algebra. Separate wrapper types for worker output and directives add no demonstrated capability in this first experiment.
- An `AttemptReport(output, error)` distinguishes a returned response, an observed runtime failure, and an unknown attempt outcome. Runtime failure must not fabricate an application error value.
- A pure resolver accepts named `AttemptAccounting(current, limit, snoozes)`, retry policy, report, and an explicit clock value. It returns a proposed completion, retry, snooze, discard, cancellation, or reconciliation disposition.
- A proposed disposition is not an acknowledged queue result. Only a later successful store transition makes it committed state.

## Attempt accounting

- The supplied attempt number includes the current claim and must be positive. The total limit must also be positive, and the supplied snooze count must be nonnegative.
- A failed attempt may retry only when its current number is below the limit and the configured retry policy allows it. At or above the limit, failure exhausts the budget.
- Snooze removes the current claim from consumed retry accounting and increments a separate snooze count. It does not record an application failure.
- Attempt numbers express retry accounting. They are not unique execution identities: a later execution after snooze may have the same attempt number.
- Each claim therefore needs its own attempt identity or ownership epoch for stale-acknowledgement checks.
- Backoff is an injected, deterministic policy in the pure experiment. Native timers, jitter, scheduling latency, and the exact Oban backoff distribution require later oracle work.

## Uncertainty and cancellation

- An explicit uncertain outcome reaches reconciliation without automatically invoking retry policy. A crash or transport loss does not establish that an external effect did not occur.
- Retry permission is an application policy, not proof of downstream idempotency. Fencing, deduplication, or shared transactions must be established at the actual effect boundary when needed.
- Worker-directed cancellation is a returned scheduling decision. External cancellation intent is a separate store-owned fact.
- Recording cancellation intent does not mean cancellation has won against completion. The atomic acknowledgement boundary must arbitrate using current state.
- Successful output or uncertainty evidence remains observable to the executor even if cancellation wins. A rejected completion must not be relabeled as a successfully committed job result or as proof that its external effect was undone.

## Subsequent acknowledgement boundary

- A claim carries job identity, unique attempt identity, ownership epoch, and the observed lease information.
- Lease renewal preserves the attempt's ownership epoch. A separate record revision may protect renewal updates without making a completion racing its own renewal spuriously stale.
- Takeover or new ownership changes the epoch. Reclaim after snooze cannot rely on the reused attempt number as a fence.
- Acknowledgement checks the current persisted attempt, epoch, executing state, cancellation state, and expiry atomically. It must not compare only against the caller's outdated expiry snapshot.
- Distinct outcomes cover stale ownership, expired lease, cancellation victory, already terminal state, unavailable storage, and an unknown commit outcome.
- A timeout after sending an acknowledgement does not authorize automatic execution of the job again. The executor must reconcile the stored attempt and command outcome.
- Queue ownership data is not authentication, and a queue fence does not automatically fence an external service.

## Decisive consumers

- Invoke an existing typed payment worker and adapt its ordinary result. Separately use a callback that deliberately returns scheduling responses.
- Preserve the typed receipt on success; apply retry policy to a failure with budget remaining; exhaust the same failure at the limit.
- Snooze without consuming retry budget; preserve a separate snooze count; exercise explicit discard and worker cancellation.
- Exercise an observed runtime failure and preserve its runtime reason without manufacturing the worker's application error type.
- Return unknown effect evidence and assert that retry policy is not invoked.
- In the following ownership experiment, accept completion after same-owner renewal, reject completion after takeover, reject a stale execution whose attempt number was reused after snooze, and exercise cancellation-versus-completion in both commit orders.

## Evidence limits

- Pure probes establish response shape, budget arithmetic, policy selection, and scripted ownership transitions.
- Claim atomicity, lease clocks, renewal, rescue, database compare-and-set behavior, process loss, acknowledgement retries, and downstream effects require PostgreSQL and OTP tests.
- Public outcome types do not establish that every application classifies effect uncertainty correctly.
- The complete worker and queue scope remains in [API coverage](../API-COVERAGE.md); this experiment does not replace uniqueness, batches, workflows, scheduling, plugins, or queue administration.
