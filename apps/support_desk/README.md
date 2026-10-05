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

| Package                | Role                                                                                                                                 |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| fabric                 | Agent runtime: three typed tools, the refund policy and approvals, cancellation, reconcile                                           |
| Local saga tool recipe | The refund saga as one fabric tool; maps the saga outcome onto the tool result                                                       |
| saga                   | The three-step refund workflow with undo and `unknown_when` for an unknown payment outcome                                           |
| llm_wire               | OpenAI Responses adapter, reached through `fabric/llm.model` with a caller-owned client                                              |
| http_gun               | One loopback-only client; the shop API is a shorter-timeout view; Sinal events by default                                            |
| json_blueprint         | One codec per record: tool schemas, argument checks, policy match, typed final answer                                                |
| sinal                  | `src/support_desk/telemetry.gleam` attaches to fabric, saga, http_gun and llm_wire events                                            |
| warden                 | Approvers sign in through OIDC; `approvers.gleam` is fabric's warden recipe: token validation plus the scope `approve:<requirement>` |

Seams under test:

- The 59-line Saga recipe receives a full typed execution report, then
  explicitly classifies it for Fabric. Reporting failures distinguish work
  that never started from work whose effects are unknown.
- One tool definition (`domain.gleam`) serves fabric, llm_wire and the
  policy; no llm_wire declaration is written.
- An http_gun failure with `MaybeSent` becomes a step error marked with
  `saga.unknown_when`, then a fabric `Uncertain` effect, then an operator
  reconciliation (`refund.gleam`).
- The approval gate: approve, reject, and cancel while waiting.
- Authenticated and authorized approvers: an approver signs in at warden's scripted OIDC provider (`warden/testing`) and answers with the access token it issued. `approvers.warden_approvers` is fabric's documented recipe (`fabric/approvers`): `resource.verify` checks signature, issuer, audience and expiry, then the token must carry the scope `approve:refund-approver` (the desk's requirement name), and the reviewer is built from `sub` and `iss`. It is built once at boot, given to the agent with `agent.with_approvers` and shared with `desk.approve` and `desk.reject`, which take the bearer token (a `String`), call `approvers.check` and pass the `Proof` to `fabric.approve` or `fabric.reject`. A proof from any other approvers value is refused by fabric. The stored approval records `sub`, `iss` and the verifier name `"warden"`. An absent, expired, forged or wrong-audience token is `desk.NotAuthenticated`; a genuine token without the scope (`mallory` is granted `openid` only, through `testing.with_granted_scopes`) is `desk.NotAuthorized`; unreachable keys are `desk.Unavailable`. None of them reaches fabric, and the approval stays pending with no payment. Signing in is a person's, not a ticket's: the sign-in is played in process (`app.sign_in`), because the desk serves no HTTP callback, and the collector leaves Warden's own HTTP events out of the ticket trails.
- A typed final answer: `agent.with_answer` gives the model the `Resolution` schema as its output format and the run completes with the decoded value. A refused answer gets one corrective turn (`A-600`).
- Telemetry correlation from agent to tool to saga to HTTP: the desk's own
  `sinal/correlation` ticket id is the fabric run's correlation (`fabric.start(.., correlation: Some(ticket))`), so one agent serves every ticket and each fabric, llm_wire, http_gun and saga event carries the ticket: the model calls through `fabric/llm`, the tools' and the refund saga's HTTP calls through `tool.Call.correlation`. The run id is derived from the ticket, so opening a ticket twice returns its one run.

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
gleam test   # 21 tests
gleam run    # prints each ticket (with its approver's subject and issuer), the ledger, and one ticket's telemetry trail
```

Order ids select the scripted behavior: `A-100` succeeds, `A-200` is used
for a rejection, `A-300` fails notification (compensation), `A-400` stalls
the payment API past the client deadline (unknown outcome), `A-500` makes the
model send an invalid amount, and `A-600` was already refunded (and the model first answers in prose).

Findings are in [FEEDBACK.md](FEEDBACK.md).
