# checkout

An order API built from `saga`, `grind`, `http_gun` and `sinal` on `wisp`,
`mist` and `pog`. It is composition evidence, not a product: the payment and
shipping providers are scripted mist servers on 127.0.0.1.

`POST /orders` runs a checkout saga:

1. **reserve_stock**: a conditional `UPDATE` on the `stock` row through the
   app's pog pool. Undo releases the stock.
2. **charge_card**: `POST /charges` on the payments API through http_gun,
   with an `idempotency-key` derived from the order. Undo voids the charge.
   When the outcome is unknown (`MayHaveBeenSent`), the step retries under the
   same key, then holds the order for reconciliation.
3. **book_shipment**: `POST /shipments` on the shipping API. If the request
   timed out after it may have been sent, the step's compensation cancels the
   shipment by key before aborting.

Failures compensate in reverse. On success the order row and a receipt
outbox row commit in one transaction, and the outbox is flushed to a grind
job (`checkout.receipt`) with a submission id derived from the order.

`POST /orders?mode=durable` enqueues a grind job (`checkout.run`) instead. Its
handler drives the same saga through `saga/durable`, on a PostgreSQL `Storage`
the app implements with pog (`src/checkout/saga_store.gleam`). A lost saga
runner snoozes the job, and redelivery resumes from the checkpoint.
`GET /orders/:id` reads the order row.

## Running

Inside the oversight dev shell, from this directory:

```sh
../scripts/with-postgres.sh gleam test   # 9 tests
../scripts/with-postgres.sh gleam run    # narrated demo
```

`gleam run` places six orders (happy path, a declined card, a shipping timeout,
a lost payment answer, a payment that never answers, and a durable order).
Then it prints stock, receipts, and the cross-package telemetry trace for two
orders.

## Layout

| Module                         | Role                                                                     |
| ------------------------------ | ------------------------------------------------------------------------ |
| `checkout/domain`              | Order, step outputs, `CheckoutError` (carries http_gun's `Failure`)      |
| `checkout/workflow`            | The saga definition, used for both local and durable runs                |
| `checkout/gateway`             | Payments and shipping clients on one http_gun `Client` (loopback policy) |
| `checkout/saga_store`          | pog-backed `saga/storage.Storage` (owner registry + VM lease)            |
| `checkout/jobs`                | Grind worker that drives the durable saga                                |
| `checkout/orders`              | Local placement, outcome finalisation, receipt worker, outbox flush      |
| `checkout/db`                  | App tables and queries on the app pool                                   |
| `checkout/codecs`              | JSON codecs; bridge to grind and saga codecs; http_gun `Failure` codec   |
| `checkout/telemetry`           | Sinal handlers for saga, http_gun and grind; per-order correlation       |
| `checkout/providers`           | Scripted payment and shipping APIs (mist)                                |
| `checkout/web`, `checkout/app` | wisp routes; wiring and lifecycle                                        |

## Seams exercised

- Saga steps over http_gun: typed `Failure` in step errors, deadlines, and
  `MayHaveBeenSent` against saga's unknown-effect reporting.
- Saga durable storage on pog, checked with `saga/storage/conformance`.
- A grind worker driving `saga/durable`, including a killed runner (snooze and
  redeliver) and a killed job (lease expiry, `Uncertain`, then an authorised
  replay).
- Grind admission next to an app transaction (outbox plus `submit_with_id`).
- One pog pool for the app and the saga storage; grind keeps its own.
- Sinal: saga (synchronous), http_gun (app-owned forwarder) and grind
  (grind-owned forwarder) events collected and attributed to one order,
  keyed by a `sinal/correlation` value made from the order id.

The friction is in [FEEDBACK.md](FEEDBACK.md).
