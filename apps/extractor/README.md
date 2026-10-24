# extractor

Batch invoice extraction. A batch of document URLs becomes Grind jobs. Each job
fetches its document with a bounded HTTP Gun stream, asks an LLM for a typed
`Invoice` through LLM Wire structured output with a Blueprint codec, and stores the
result in PostgreSQL. All external services are scripted on loopback.

## Run

From this directory, inside the Oversight shell:

```sh
../scripts/with-postgres.sh gleam test
../scripts/with-postgres.sh gleam run
```

`gleam run` submits seven documents (three good invoices, one of them rate limited
once, an unknown currency, a total that contradicts its lines, a PDF and an
oversized stream) and prints each job's outcome and the telemetry for the rate
limited job.

The [composition contract](../../docs/design/design-layer.pdf)
describes the bounds, codec reuse and outcome mapping.
