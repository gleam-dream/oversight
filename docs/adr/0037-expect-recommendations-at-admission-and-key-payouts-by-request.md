# Expect a recommendation at admission, and key a payout by its request

<a id="adr-0037"></a>

Recorded on 2026-11-16. Supersedes the occurrence key of `payout_desk` in
[ADR 0035](0035-answer-a-gated-agent-call-from-the-decision-point.md#adr-0035).

## Decision

- Each application records that a recommendation is expected when it admits the trigger (`decisions.expect`), in the transaction that admits the job that will recommend.
  - A declared event about the subject supersedes every occurrence about it that is expected, waiting or held.
  - A later recommendation for a superseded key is refused (`SupersededBefore`) and writes nothing.
- `clinic_registration` admits a message in this order, in one transaction:
  1. `happened`: the newer message supersedes the contact's pending occurrences;
  2. keep the message;
  3. `expect` the message's key;
  4. submit the register job.
- `clinic_registration` therefore has no lock of its own on the contact and no check that a message is still the contact's latest. `happened` takes the library's lock on the subject first, so admissions about one contact run one after the other.
- An admission that waits longer than the store's lock wait ends as contention and keeps nothing. In PostgreSQL that wait is 4 seconds by default. The clinic's webhook then answers `503 try_again`, and the channel delivers the message again.
- The undo window belongs to the policy (`Proceed(sample:, hold:)`):
  - `clinic_registration` version 2 holds what it lets proceed for 10 minutes.
  - `payout_desk` holds a small payout the seller's dispute won, for 5 minutes by default. A new policy version changes the window only for payouts admitted after it.
  - `moderation_desk` version 2 holds a confident spam hide for 5 minutes.
  - During the window, the point's withdrawers may take the output back, and a newer event supersedes it.
- `payout_desk` keys the occurrence by the request: `payout:` followed by the request id, which is at most 64 bytes.
  - The request, its expectation and the agent job are admitted together.
  - A failed agent run is a failed attempt under the request's key. The retried job starts a fresh run.
  - The tool call's run and action are the occurrence's trigger and explanation.
- A seller's suspension (`seller_suspended`) supersedes the seller's pending payouts, whether expected, waiting or held. When the agent proposes a payout that was superseded before it began, the proposal is refused, and the application cancels the parked run.

## Rationale and consequences

- **Why the expectation is recorded at admission.** Without it, a newer event that commits while the model is still answering cannot reach the occurrence the answer would create. Each application then needed its own check under its own lock. With the expectation, the record refuses the late recommendation, and an operator can list the triggers still waiting for a recommendation (`queue.pending`; `GET /pending` in `clinic_registration`).
- **Why the request is the payout's key.** Keying by the tool call's run and action split one payout into separate records:
  - the expectation was recorded before any run existed;
  - a failed run and its retry are two different runs.

  The request is the stable identity across both.

- **What did not change.** A held output still settles only through its hold, a withdrawal or a supersession. Nothing is released early.
