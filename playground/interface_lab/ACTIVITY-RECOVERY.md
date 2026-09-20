# Typed activity recovery

## Question

- Can one canonical activity express retry, replacement, rollback permission, and unresolved effects without hiding scheduling or compensation ownership?
- This experiment extends the serial local interpreter. It does not introduce another workflow builder.

## Recovery decisions

- Recovery receives the failed activity's native input, business cause, and remaining attempt budget. It runs as explicitly issued callback work.
- A positive attempt limit includes the initial attempt. Recovery still runs after the last allowed attempt because failed-step cleanup may be necessary.
- A retry decision authorizes another attempt and separately declares cancellation permission. The application owns the idempotency or reconciliation basis for retry; that basis does not automatically authorize rollback.
- Replacement output supplies its own compensator, including any residual effects of recovery. The interpreter retains that compensator before output encoding.
- An abort decision explicitly authorizes compensation of prior completed activities and retains located cleanup failures. A cleanup error alone grants no rollback permission.
- An unresolved decision carries application-typed evidence and cleanup failures. It authorizes neither retry nor rollback.

## Execution ownership

- Delayed retry returns a relative duration and correlated wake token. The host owns timer creation and delivery; the reducer does not sleep or establish elapsed time.
- A fresh attempt receives fresh work correlation and retains the already-decoded native input. Old completions and wake deliveries cannot settle the current attempt.
- A retry decision after budget exhaustion retains a blocked execution instead of inferring rollback permission. Cancellation in either a delayed or blocked retry follows its explicit policy: compensate known effects or hold typed unresolved evidence.
- An unresolved execution retains its failed node, original cause, recovery continuation, and completed journal. Ordinary continuation or cancellation cannot clear uncertainty.
- Opaque values remain copyable. Correlation checks do not prevent replay of copied state or repeated external effects.

## Consumer evidence

- A business workflow suspends on uncertain payment outcome without retrying payment or undoing its reservation.
- A known temporary tool failure requests delayed retry, preserves earlier work, and rejects stale or duplicate wakes. An idempotent payment retry separately exercises cancellation that holds its unresolved outcome.
- An ETL recovery supplies replacement output; later failure invokes the replacement compensator and continues after an undo failure.
- Known cleanup failure with explicit rollback permission remains distinct from uncertain cleanup that suspends.
- Compiler negatives reject the wrong replacement type and an absolute queue schedule used as a relative retry delay.
- A native input sentinel rejects a second decode. Two activity attempts execute while input decoding occurs once. This counter uses the existing process-local Erlang test helper with private integer keys; it is not a pure probe or a concurrency claim.
- The coherent snapshot gate passes 56 isolated consumers, 82 intended compiler failures, 45 executable probe groups, and the existing independent schema, generation, and Relay checks.

## Remaining scope

- Reconciliation and resumption authority, in-flight timeout settlement, parallel attempts, durable timers, process loss, callback exceptions, and Reactor behavioral parity remain separate work.
- This evidence applies to the serial local interpreter. It does not establish Reactor parity or durable recovery.
