# Place every checkout order durably

<a id="adr-0043"></a>

Recorded on 2026-11-25.

## Decision

Checkout has one placement path. `POST /orders` records the pending order,
admits its checkout job and names the job on the order row in one transaction,
and answers 202. The job drives the saga through `saga/durable` and records the
outcome on the order. The in-request mode, in which the HTTP handler ran the
saga and answered with the outcome, is removed with no compatibility path.

A supervised sweeper looks at orders pending longer than a configured age. It
leaves an order whose job is still running or waiting; for one whose job ended
it records the saga's saved outcome, or `rejected` when no saga execution
exists, or `needs_reconciliation` when the saga did not finish; and it holds an
order with no job, or with an uncertain job, for reconciliation. It never runs
a saga step.

## Need

The in-request mode inserted the pending order and then ran the saga inside the
request. If the node stopped mid-saga, the row stayed pending, a charge might
have happened, and no record said what to resume: re-running the saga is not
safe once a reservation or charge may have been undone under the same key. The
request could also hold a connection for up to two minutes. Separately, a
durable job can end without recording its outcome (an operator cancels it, or
it runs out of snoozes while the store refuses the write), and nothing finished
such an order.

## Consequences

- A placement no longer reports the outcome in its reply; the client reads
  `GET /orders/:id`. The provider-error status codes (402, 409, 502, 504) of the
  in-request reply are gone.
- The order row keeps the receipt email and the checkout job id, so the sweeper
  can record an outcome without the payment token or the address.
- An order placed in-request before this change, and left pending, is held for
  reconciliation, because nothing durable records what its saga did.

## Rejected alternatives

- Keep the in-request mode as an explicit demonstration: the applications are
  copied, and a second path that can strand a charged order is the one copied.
- Make the sweeper re-run the checkout job: the job's input carries the payment
  token, which the order row does not keep, and driving an unfinished saga
  belongs to Grind's delivery and leases, not to a periodic sweep.
