# checkout

An order API built from `saga`, `grind`, `http_gun` and `sinal` on `wisp`,
`mist` and `pog`. It is composition evidence, not a product: the payment and
shipping providers are scripted mist servers on 127.0.0.1.

`POST /orders` runs a checkout saga:

1. **reserve_stock**: a conditional `UPDATE` on the `stock` row through the
   app's pog pool. Undo releases the stock.
2. **charge_card**: `POST /charges` on the payments API through http_gun,
   with an `idempotency-key` derived from the order. Undo voids the charge.
   When the outcome is unknown (`MaybeSent`), saga records an unknown effect
   (`saga.unknown_when`), and the step retries under the same key, then holds
   the order for reconciliation.
3. **book_shipment**: `POST /shipments` on the shipping API. If the request
   timed out after it may have been sent, the step's compensation cancels the
   shipment by key before aborting. Undo cancels a booked shipment when a
   cancellation rolls the run back.

Failures compensate in reverse. On success the order's confirmation and its
receipt job (`checkout.receipt`, id `receipt:<order>`) commit in one
transaction through `grind.submit_in`.

`POST /orders?mode=durable` records the order and enqueues a grind job
(`checkout.run`) in one transaction. Its handler drives the same saga through
`saga/durable` on `saga_postgres`. A lost saga runner snoozes the job, and
redelivery resumes from the checkpoint; an abandoned job attempt is replayed
after its lease expires; `grind.cancel` of a running job rolls the saga back.
`GET /orders/:id` reads the order row.

## Running

Inside the oversight dev shell, from this directory:

```sh
../scripts/with-postgres.sh gleam test   # 12 tests
../scripts/with-postgres.sh gleam run    # narrated demo
```

`gleam run` places six orders (happy path, a declined card, a shipping timeout,
a lost payment answer, a payment that never answers, and a durable order).
Then it prints stock, receipts, and the cross-package telemetry trace for two
orders.

## Layout

| Module                         | Role                                                                      |
| ------------------------------ | ------------------------------------------------------------------------- |
| `checkout/domain`              | Order, step outputs, `CheckoutError` (carries http_gun's `Failure`)       |
| `checkout/workflow`            | The saga definition, used for both local and durable runs                 |
| `checkout/gateway`             | Payments and shipping clients on one http_gun `Client` (loopback, pinned) |
| `checkout/jobs`                | Grind worker that drives the durable saga, with cancellation              |
| `checkout/orders`              | Local and durable placement, finalisation, receipt worker and job         |
| `checkout/db`                  | App tables and queries on the shared pool                                 |
| `checkout/codecs`              | JSON codecs; bridge to grind and saga codecs                              |
| `checkout/telemetry`           | Sinal handlers for saga, http_gun and grind; per-order correlation        |
| `checkout/providers`           | Scripted payment and shipping APIs (mist)                                 |
| `checkout/web`, `checkout/app` | wisp routes; wiring and lifecycle                                         |

## Seams exercised

- Saga steps over http_gun: typed `Failure` in step errors, deadlines, and
  `MaybeSent` reported as an unknown effect (`unknown_when`).
- Saga durable storage on `saga_postgres`, checked with
  `saga/storage/conformance` on the shared pool.
- A grind worker driving `saga/durable`, including a killed runner (snooze and
  redeliver), a killed job (the runner stops with it; lease expiry, then an
  automatic replay) and `grind.cancel` (rollback through `durable.cancel`).
- Grind admission inside the app's transactions (`grind.submit_in`).
- One pog pool for the app, grind and saga_postgres, built by grind from the
  app's `pog.Config`.
- Sinal: saga (synchronous), http_gun (app-owned forwarder) and grind
  (grind-owned forwarder) events collected and attributed to one order by
  the `sinal/correlation` each package carries in its metadata.

The friction is in [FEEDBACK.md](FEEDBACK.md).
