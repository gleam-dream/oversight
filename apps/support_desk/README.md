# support_desk

[![CI](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

A customer-support agent with typed tools for order lookup, refund eligibility
and refunds. A refund waits for a human approver through Fabric's policy
gate, then runs as a Saga that refunds through the payment API, writes a ledger entry and
notifies the customer. The agent finishes with a typed `Resolution`.

The model is a scripted OpenAI Responses provider and the order, payment and notification
APIs are a scripted mist server, all on loopback.

## Run

From this directory, inside the Oversight shell:

```sh
gleam test
gleam run
```

Order ids select the scripted behavior: `A-100` succeeds, `A-200` is rejected, `A-300` fails
notification and compensates, `A-400` stalls the payment API past the client deadline (unknown
outcome), `A-500` makes the model send an invalid amount, and `A-600` was already refunded.

The [composition contract](../../docs/design/design-layer.pdf) describes
approval, evidence and compensation. `src/support_desk/approvers.gleam` holds the
application-owned authorization recipe.
