# checkout

[![CI](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

An order API built on Saga, Grind, HTTP Gun and Sinal, with Wisp routes and
PostgreSQL storage. Payment and shipping providers are scripted servers on
loopback.

`POST /orders` takes a SKU, a quantity, a shipping address and a payment token. The
customer gets the token by sending the card number to the payment provider
(`POST /tokens`), so the order API never receives a card number. The server prices
the order from its catalog, and a body that carries an amount or any other unknown
field is refused with 422. The checkout saga reserves stock, charges the token and
books a shipment, compensating in reverse on failure. `POST /orders?mode=durable`
records the order and enqueues a Grind job in one transaction, and the job drives
the same saga durably. `GET /orders/:id` reads the order row. Error bodies carry a
stable `error` code; internal detail goes to the log.

Every route needs `Authorization: Bearer <token>` for a customer in the app's
configured token table, and answers 401 otherwise. An order belongs to the customer
who placed it, and another customer's order reads as 404. The `order_id` is the
customer's own idempotency key. Repeating a placement returns the existing order
with 200 and does not run the saga again. Reusing the id for a different SKU or
quantity answers 409. Order ids are scoped to the customer: another customer placing
under the same id creates a separate order of their own and never touches or learns
about the first.

`POST /orders` without `?mode=durable` answers only after the saga's outcome is
recorded. A saga that cannot start is recorded as rejected. A saga still running after
the request's budget (60 seconds) is cancelled, and the outcome it settles on is
recorded before the reply, so the order never stays pending behind a local placement.

At boot the app creates its tables and checks the shape of tables that already exist.
A database holding tables from an earlier version, without the catalog price or the
customer-scoped keys, is refused with a message naming each outdated table and is
left unchanged. There is no upgrade path, because the old orders have no customer or
price to backfill. Drop the `stock`, `reservations`, `orders` and `receipts_sent`
tables, or use a fresh database.

`CHECKOUT_SECRET_KEY_BASE` sets Wisp's signing secret (at least 64 characters). When
it is unset, the app generates a random secret at boot, so signed values do not
survive a restart.

## Run

From this directory, inside the Oversight shell:

```sh
../scripts/with-postgres.sh gleam test
../scripts/with-postgres.sh gleam run
```

`gleam run` places six orders (happy path, a declined card, a shipping timeout, a
lost payment answer, a payment that never answers, and a durable order). It then
repeats one placement as its owner and as a second customer, and prints stock,
receipts and the cross-package telemetry trace for two orders.

The [composition contract](../../docs/design/design-layer.pdf)
describes the checkout's authorities, invariants and recovery behavior.
