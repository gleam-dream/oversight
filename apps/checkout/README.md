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
lost payment answer, a payment that never answers, and a durable order) and prints
stock, receipts and the cross-package telemetry trace for two orders.

The [composition contract](../../docs/design/design-layer.pdf)
describes the checkout's authorities, invariants and recovery behavior.
