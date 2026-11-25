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
books a shipment, compensating in reverse on failure. Every placement is durable:
`POST /orders` records the pending order, enqueues a Grind job and names the job on
the order in one transaction, and answers 202 with the job id. The job drives the
saga durably and records the outcome on the order. `GET /orders/:id` reads the order
row. Error bodies carry a
stable `error` code; internal detail goes to the log.

Every route needs `Authorization: Bearer <token>` for a customer in the app's
configured token table, and answers 401 otherwise. An order belongs to the customer
who placed it, and another customer's order reads as 404. The `order_id` is the
customer's own idempotency key: 1 to 64 ASCII letters, digits, `.`, `_` or `-`,
starting with a letter or digit. Any other id is refused with 422, because the id
becomes part of job ids, saga execution ids and the keys in provider URLs. Repeating a placement returns the existing order
with 200 and does not run the saga again. Reusing the id for a different SKU or
quantity answers 409. Order ids are scoped to the customer: another customer placing
under the same id creates a separate order of their own and never touches or learns
about the first.

A job ends only after the order row holds the saga's outcome. When the row cannot be
written, the job snoozes, and its redelivery reads the saved saga outcome and repeats
the write, up to Grind's snooze limit.

A supervised sweeper resolves orders that nothing will finish. Every
`Config.sweep_every` (one minute by default) it looks at the orders pending longer
than `Config.stale_after` (five minutes). It leaves an order whose job is still
running or waiting. For an order whose job ended without recording an outcome, it
records the saga's saved outcome with its receipt job, records `rejected` when the
saga never started, and records `needs_reconciliation` when the saga stopped before
it finished. An order with an uncertain job, or with no job, is held as
`needs_reconciliation` as well. The sweeper never runs a saga step, so it never
charges or books
([ADR 0043](../../docs/adr/0043-place-every-checkout-order-durably.md)).

At boot the app creates its tables and checks the shape of tables that already exist.
A database holding tables from an earlier version, without the catalog price or the
customer-scoped keys, is refused with a message naming each outdated table and is
left unchanged. There is no upgrade path, because the old orders have no customer or
price to backfill. Drop the `stock`, `reservations`, `orders` and `receipts_sent`
tables, or use a fresh database.

`app.start` starts one root supervisor and returns when the tree is up and the
schemas are applied. An observation group holds the Sinal forwarder and the telemetry
collector, and each restarts alone. A service group starts the provider client, Grind
(with the pool), the order API listener and the sweeper in that order, and restarts a failed child
together with the ones started after it. The application reaches each of them by a
name made once at start, so a restart does not invalidate a handle. A restart restores
processes, not state: jobs and sagas resume from PostgreSQL, and the collector starts
empty. The collector is Sinal's bounded collector: its process attaches the telemetry
handlers and owns them, so they exist exactly while it runs and a restart attaches them
again. It keeps the newest `Config.telemetry_capacity` entries (10,000 by default);
`telemetry.usage` reads how many it holds and how many it overwrote. Sinal is pinned to
an unreleased commit that carries owner-bound handlers and the collector. `Config.port`
sets the API port; with 0 the listener binds a free port, which
`app.port` reads and which changes when the listener restarts. `app.stop` stops the
tree in reverse order and waits for it.

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
