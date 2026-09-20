# Worker results and proposed queue outcomes

## Question

- Can an ordinary typed worker remain useful outside a queue while a queue adapter expresses retry, snooze, cancellation, and uncertain effects?
- This experiment resolves a supplied attempt report into a proposed disposition. It does not claim, execute, persist, or acknowledge a job.

## Composition

- Existing workers retain ordinary `Result(output, error)` handlers. An adapter converts those results into scheduling responses without changing the business function.
- A callback that needs scheduling control can return a scheduling response directly. Typed success values and business errors remain visible.
- An observed runtime failure has its own representation. The resolver must not manufacture a value of the business error type to describe a runtime failure. Retry policy receives a sum that retains either cause.
- Unknown outcomes and explicitly uncertain effects request reconciliation. They bypass retry policy because uncertainty does not establish that an external effect did not occur.
- Worker-directed cancellation is distinct from an external cancellation request. The eventual store transition must arbitrate races with completion.

## Accounting

- The current attempt includes its claim. Current attempt and total limit must be positive; the snooze count must be nonnegative.
- A failure can retry only below the total limit and with policy permission. Policy refusal and budget exhaustion remain separate terminal reasons. The supplied nonnegative absolute clock and validated relative delay make the proposed time deterministic.
- Snooze refunds the current claim in retry accounting and increments a separate snooze count. A later claim may therefore reuse the same attempt number.
- Attempt numbers are counters, not ownership fences. Acknowledgement will need a distinct attempt identity and ownership epoch.

## Acceptance evidence

- The consumer reuses an existing typed worker, then exercises a separate scheduling callback.
- The probe preserves typed output and errors, distinguishes failure below and at the limit, refunds snooze accounting, retains discard and cancellation reasons, and preserves runtime failure detail.
- Both uncertainty paths and an exhausted failure accept a retry callback that would panic if invoked. Success and snooze remain valid responses at the attempt limit.

- Classifying a runtime failure as retryable is an application decision. It does not prove that the failed attempt performed no external effect.

- Compiler-negative consumers reject a success-type mismatch and substitution of a relative retry delay for an absolute availability time.

## Remaining work

- Add claim and acknowledgement interfaces that distinguish same-owner lease renewal from takeover, expired ownership, cancellation victory, terminal state, and unknown commit outcome.
- Preserve execution evidence when acknowledgement is rejected. An unacknowledged output is not a committed queue result.
- Compare actual retry scheduling, snooze behavior, and worker termination against the pinned oracle in the [Grind execution contract](../../research/grind-execution-contract.md).
- PostgreSQL atomicity, OTP supervision, timers, jitter, shutdown, rescue, effect idempotency, and codec-backed attempt history remain unverified.
