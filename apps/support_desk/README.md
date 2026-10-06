# support_desk

A customer-support agent with typed tools. The agent looks an order up,
checks refund eligibility and issues refunds. A refund waits for a human
approver through fabric's policy gate. Once approved, it runs as a saga:
refund through the payment API, write a ledger entry, notify the customer.
A failure after the payment voids the refund and removes the ledger entry.
The agent finishes with a typed `Resolution`.

The LLM is a scripted OpenAI Responses provider on loopback. The orders,
payments and notification APIs are a scripted mist server on loopback. No external services or provider keys are needed.

## What the tests cover

- Typed tools share Blueprint codecs with their model declarations and the
  approval policy. The agent returns a decoded `Resolution`.
- The refund tool runs a Saga and maps its complete execution report to a
  Fabric tool result. Failures distinguish work that never started from effects
  whose outcome is unknown.
- A payment request marked `MaybeSent` becomes a Saga unknown effect and a
  Fabric `Uncertain` result. The application then requires reconciliation.
- Approvers sign in through Warden's scripted provider. Token validation checks
  signature, issuer, audience and expiry; the application also requires the
  `approve:refund-approver` scope. Invalid or unavailable authentication leaves
  the approval pending without making a payment.
- Approval, rejection and cancellation each have tests. Fabric refuses proofs
  from a different approver configuration. The stored approval identifies the
  reviewer's subject, issuer and verifier.
- One corrective model turn can recover from an invalid final answer.
- The ticket correlation follows the agent, model, tool, Saga and HTTP calls.
  Reopening a ticket returns the same run.

See [the tests](test/) for individual scenarios and
[approvers.gleam](src/support_desk/approvers.gleam) for the application-owned
authorization recipe. Sign-in runs in process because this demo has no browser
callback endpoint.

## Layout

- `src/support_desk.gleam`: `main`, five tickets with scripted approvers who sign in first (T-1 tries with no token, T-4 with mallory, who lacks the scope).
- `src/support_desk/approvers.gleam`: the warden approvers (token validation and the `approve:<requirement>` scope).
- `src/support_desk/app.gleam`: wiring, including the loopback client policy.
- `src/support_desk/desk.gleam`: agent, tools, policy, typed answer.
- `src/support_desk/domain.gleam`: records, codecs, tool definitions.
- `src/support_desk/refund.gleam`: the saga. `shop.gleam`: HTTP adapters.
- `src/support_desk/events.gleam`: the desk's own `ticket.opened` and `ticket.answered` events.
- `src/support_desk/ledger.gleam`: in-memory ledger.
- `src/support_desk/services.gleam`, `provider.gleam`: scripted loopback services.
- `src/support_desk/telemetry.gleam`: event collector and per-ticket trail.

## Running

From this directory, inside the oversight dev shell:

```sh
gleam test
gleam run
```

Order ids select the scripted behavior: `A-100` succeeds, `A-200` is used
for a rejection, `A-300` fails notification (compensation), `A-400` stalls
the payment API past the client deadline (unknown outcome), `A-500` makes the
model send an invalid amount, and `A-600` was already refunded (and the model first answers in prose).

The [ecosystem design](../../docs/design/design-layer.pdf) records the current composition contract.
