# checkout

[![CI](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

An order API built on Saga, Grind, HTTP Gun and Sinal, with Wisp routes and
PostgreSQL storage. Payment and shipping providers are scripted servers on
loopback.

`POST /orders` runs a checkout saga that reserves stock, charges the card and books
a shipment, compensating in reverse on failure. `POST /orders?mode=durable` records
the order and enqueues a Grind job in one transaction, and the job drives the same
saga durably. `GET /orders/:id` reads the order row.

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
