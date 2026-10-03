# extractor

Batch invoice extraction. A batch of document URLs becomes Grind jobs. Each
job fetches its document with a bounded http_gun stream, asks an LLM for a
typed `Invoice` through llm_wire structured output with a Blueprint codec,
and stores the result in Postgres. All external services are scripted on
loopback.

## Run

From this directory, inside the oversight dev shell (`nix develop`):

```sh
../scripts/with-postgres.sh gleam test   # 13 tests
../scripts/with-postgres.sh gleam run    # the demo batch, with a narrative
```

`gleam run` submits seven documents: three good invoices (one rate limited
once), one answer with an unknown currency, one answer whose total contradicts
its lines, one PDF, and one oversized stream. It prints each job's outcome
and the telemetry attributed to the rate-limited job.

## Layout

| Module                | Responsibility                                                                                  |
| --------------------- | ----------------------------------------------------------------------------------------------- |
| `extractor/invoice`   | Domain record (6 fields, nested `LineItem` list, `Currency` enum) and its Blueprint codec       |
| `extractor/document`  | Bounded fetch: status, content type and declared length checked at the head; `body.collect` cap |
| `extractor/llm`       | Provider settings (OpenAI Responses, Anthropic Messages, Google) and structured extraction      |
| `extractor/outcome`   | Maps fetch, llm_wire and storage failures to a Grind `Response` (retry, snooze, discard)        |
| `extractor/clients`   | Two http_gun clients: document fetcher and LLM client, with different policies                  |
| `extractor/jobs`      | Grind worker, codecs, pipeline start, submit, await, stop                                       |
| `extractor/store`     | `extracted_invoices` table on Grind's pool (`grind.connection`); idempotent upsert              |
| `extractor/telemetry` | Sinal handlers for grind, http_gun and llm_wire events; per-document correlation                |
| `extractor/scripted`  | Loopback mist servers: documents, and the three provider SSE wire formats                       |
| `extractor/fixtures`  | The demo batch                                                                                  |

## Packages and seams

- **grind**: one runtime on the app's `pog.Config`, a `responding` worker, a typed retry policy, `await`, and `grind.connection` for the app's own table.
- **http_gun**: two clients with separate destination policies; `with_response` with `body.collect` caps; `destination.loopback_only() |> only_hosts` per client; `Kind` and `is_retryable` for failures; `with_correlation` views passed into llm_wire.
- **llm_wire**: `prepare_structured` / `run_structured` on three built-in adapters; `retry.assess` and `RetryHint` drive Grind snoozes.
- **json_blueprint**: one `Invoice` codec supplies the output schema, provider-output decoding, the Postgres payload and the Grind output codec.
- **sinal**: typed observation of every package's events; one forwarder for http_gun.
- **pog**, **mist**, **envoy**: storage, scripted servers, configuration.

Seams under test: llm_wire retry advice to Grind snooze, retry and discard;
one or two HTTP clients; provider portability of structured output; codec
reuse across Blueprint, Grind and pog; following one job across packages.
Findings are in [FEEDBACK.md](FEEDBACK.md).
