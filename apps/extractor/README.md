# extractor

[![CI](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

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

The job payload codec in `src/extractor/generated/` is generated from the typed
definition in `test/document_job_definition.gleam`. After changing the definition
or the `DocumentJob` type, regenerate it from this directory. `gleam test` compares
the committed module's fingerprint with a fresh compilation of the definition,
so it fails when the definition changes and the module was not regenerated:

```sh
gleam run -m generate_codecs
gleam format src/extractor/generated
```

The [composition contract](../../docs/design/design-layer.pdf)
describes the bounds, codec reuse and outcome mapping.
