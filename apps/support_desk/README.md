# support_desk

A customer-support agent with typed tools. The agent looks an order up,
checks refund eligibility and issues refunds. A refund waits for a human
approver through fabric's policy gate. Once approved, it runs as a saga:
refund through the payment API, write a ledger entry, notify the customer.
A failure after the payment voids the refund and removes the ledger entry.
The agent finishes with a typed `Resolution`.

The LLM is a scripted OpenAI Responses provider on loopback. The orders,
payments and notification APIs are a scripted mist server on loopback. No
network access and no keys are used.

## Packages and seams

| Package                 | Role                                                                                       |
| ----------------------- | ------------------------------------------------------------------------------------------ |
| fabric                  | Agent runtime: three typed tools, the refund policy and approvals, cancellation, reconcile |
| fabric_saga (in fabric) | The refund saga as one fabric tool; maps the saga outcome onto the tool result             |
| saga                    | The three-step refund workflow with undo and a `Hold` for an unknown payment outcome       |
| llm_wire                | OpenAI Responses adapter, reached through `fabric/llm.model` with a caller-owned client    |
| http_gun                | Two loopback clients (model and shop APIs) with observations through a Sinal forwarder     |
| json_blueprint          | One codec per record: tool schemas, argument checks, policy match, typed final answer      |
| sinal                   | `src/support_desk/telemetry.gleam` attaches to fabric, saga, http_gun and llm_wire events  |

Seams under test:

- One tool definition (`domain.gleam`) serves fabric, llm_wire and the
  policy; no llm_wire declaration is written.
- An http_gun failure with `MayHaveBeenSent` becomes a saga `Hold`, then a
  fabric `Uncertain` effect, then an operator reconciliation (`refund.gleam`).
- The approval gate: approve, reject, and cancel while waiting.
- A typed final answer decoded from the agent's text (`desk.answer`).
- Telemetry correlation from agent to tool to saga to HTTP: the desk's own
  `sinal/correlation` ticket id joins fabric runs and the lookup HTTP calls; saga and llm_wire do not carry it.

## Layout

- `src/support_desk.gleam`: `main`, five tickets with scripted approvers.
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
gleam test   # 12 tests
gleam run    # prints each ticket, the ledger, and one ticket's telemetry trail
```

Order ids select the scripted behavior: `A-100` succeeds, `A-200` is used
for a rejection, `A-300` fails notification (compensation), `A-400` stalls
the payment API past the client deadline (unknown outcome), `A-500` makes the
model send an invalid amount, and `A-600` was already refunded.

Findings are in [FEEDBACK.md](FEEDBACK.md).
