# Release change plan

This plan lists every proposal from the nine [package reviews](README.md),
with its status after the [owner decisions](DECISIONS.md) of 2 October 2026.
Decisions 3 (correlation), 4 (definition bugs) and 5 (default numbers) are
accepted. Decisions 1 (durability ownership) and 2 (fabric's graph runtime)
are deferred. Each proposal's full description, evidence and signature sketch
is in its package report.

## Status values

- **Planned**: in scope for the release.
- **Adjusted**: planned, with a change from the report to follow an accepted
  decision.
- **Deferred**: waits for decision 1 or 2.
- **Out**: rejected by the owner.

## Waves

Each wave ends with all eight composition apps passing on the new heads. Each
app also deletes the glue the wave made unnecessary, and records the reduction
in its `FEEDBACK.md`. Packages publish in this order.

| Wave | Packages                | Purpose                                                                                                                                                             |
| ---- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1    | all                     | Release blockers: redacted secrets, bounded parsing, the SSE line limit, a fail-closed relay listener, module docs, CHANGELOGs. Small, non-breaking where possible. |
| 2    | sinal, json_blueprint   | Leaves. Correlation, total constructors, one emission path; Blueprint 2.0 builders, bridges and surface cut. Publish both.                                          |
| 3    | http_gun, saga, grind   | Transport and engines. Publish all three.                                                                                                                           |
| 4    | llm_wire, relay, warden | Protocols. Publish all three.                                                                                                                                       |
| 5    | fabric                  | Agent runtime, excluding deferred items. Publish.                                                                                                                   |

Wave 1 items are drawn from later proposals and land early in reduced form:

| Blocker                                          | Proposal                        | Wave 1 scope                                                                                                                                                       |
| ------------------------------------------------ | ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Secrets print in `string.inspect` and crash logs | LLM-R5 (part), RELAY-R5 (audit) | Store `ApiKey` and relay `BearerToken` as `reveal: fn() -> String`, as warden does. Stop `provider.headers` returning the key. Add a test per secret-holding type. |
| Parser memory unbounded                          | JSONB-R7                        | 1 MiB and depth 64 default; a byte check before 1.x `decode` and generated decoders.                                                                               |
| OpenAI replies over 16 KiB fail                  | LLM-R1 (part)                   | Raise the SSE line limit to the event limit (1 MiB); confirm with a recorded OpenAI fixture.                                                                       |
| Relay starts unauthenticated off loopback        | RELAY-R13 (part)                | `start` fails on a non-loopback bind without protection; `allow_unauthenticated()` opts in.                                                                        |
| Module docs do not render; no CHANGELOG          | each package's docs proposal    | `////` module docs on every public module; CHANGELOG in grind and http_gun.                                                                                        |

### Wave 1 results (2 October 2026)

Every wave 1 item landed. Each repo passed its own full gate before push.

| Package        | Commits          | Result                                                                                                                                                                                                                                                                                                     |
| -------------- | ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| llm_wire       | 6c1031e…87c96cb  | `ApiKey` and prepared headers held in closures; `provider.headers` → `reveal_headers`, `Spec.headers` is a function (small break). SSE line limit 1 MiB; a quadratic scan found on the way is now linear (4,041 ms → 34 ms per 1 MiB line). Gemini's large tool calls covered. Docs gate added. 234 tests. |
| relay          | 6e7e449…d908b9f  | `BearerToken` held in a closure. `http.start` refuses a non-loopback host without protection; `http.allow_unauthenticated` opts in (additive). All 17 module docs. 143 tests.                                                                                                                              |
| json_blueprint | 84a5fe4, 787cf12 | Parse defaults 1 MiB and depth 64; byte checks before 1.x `decode` and generated decoders; peak heap per 1 MiB input 95–106 MB → 14–69 MB. All 12 module docs, with tested examples. 177 Erlang, 176 JavaScript tests.                                                                                     |
| saga           | 78081e3…a736cff  | All 11 module docs converted to `////` and corrected; docs gate added. 165 tests.                                                                                                                                                                                                                          |
| sinal          | 59b7723…3db37bf  | Module docs; README leads with the common path and a defaults table; `telemetry >= 1.4.2 and < 2.0.0`; docs gate added. 94 tests.                                                                                                                                                                          |
| http_gun       | 008da53, b2821fc | 12 module docs rewritten; CHANGELOG; tests prove credential headers never reach failures, telemetry or cassettes. Sinal snapshot refreshed. 136 tests.                                                                                                                                                     |
| grind          | 9b3d22d          | Database password held in a closure; `Settings.database_url` is a function (small break). Module docs and doc defects fixed; CHANGELOG. 269 tests plus the Oban oracle.                                                                                                                                    |
| fabric         | fa0cd54          | fabric_typesafe API key and fabric_mcp server environment held in closures (`Options.environment` is a function, small break); inspect tests in core and fabric_postgres; four CHANGELOGs. 45/45 gate checks.                                                                                              |
| warden         | af26ee1          | Inspect tests confirm every credential-holding type redacts; CHANGELOG; the D7 contradiction in PROGRESS.md fixed. 130 tests.                                                                                                                                                                              |

Relay and saga now pin the wave 1 heads of json_blueprint (787cf12) and sinal
(3db37bf).

All eight composition apps pass on the wave 1 heads (77 tests). The older
[ecosystem pilot](../../playground/ecosystem_pilot/README.md) does not
compile: it calls llm_wire's `Continuation` and `prepare_continue`, which
llm_wire removed before wave 1 when conversations became caller-owned. The
`tool_hub` app covers its Relay-to-LLM path, so the pilot is superseded rather
than ported.

**Follow-ups found during wave 1**, now part of later waves:

| Package        | Item                                                                                                                                                                                                                                                   | Wave  |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----- |
| warden         | `LogoutOutcome.RedirectToProvider(url)` embeds the ID token as `id_token_hint`, so it prints. Redact it with the WARDEN-R7 redesign.                                                                                                                   | 4     |
| sinal          | Without the `telemetry` application running, `attach` and `observe` crash the caller with `noproc` and `emit` reaches no handler. Start or check the application in sinal.                                                                             | 2     |
| http_gun       | `cassette.new` keeps caller-supplied credential headers in the in-memory value; the pool's waiting queue holds request headers, which a crash report prints; `fixture.sanitise` drops a fixed list of header names only. Part of the redaction policy. | 3     |
| grind          | `PoolStartFailed(actor.StartError)` carries a dynamic exit reason that needs a credential audit.                                                                                                                                                       | 3     |
| json_blueprint | No element-count limit: adding one needs a new error variant, which belongs to the 2.0 error redesign (JSONB-R8). Worst case is about 70 bytes of heap per input byte.                                                                                 | 2     |
| relay          | About half of the public functions have no function doc. The stdio client's process arguments are not redacted.                                                                                                                                        | 4     |
| fabric         | fabric_mcp `Options.arguments` is a plain list.                                                                                                                                                                                                        | 5     |
| all            | llm_wire, saga and sinal gates now fail on a public module without a `////` doc. Add the same check to every package's gate.                                                                                                                           | 2–5   |
| http_gun       | `AGENTS.md` still says "No push" and keeps oversight and siblings read-only, from the construction phase. It conflicts with release work.                                                                                                              | owner |

### Wave 2 results (2 October 2026)

Wave 2 redesigned the two leaf packages, migrated every dependent package and
all eight apps, and validated the whole set before anything was pushed. Every
package's full gate passed against the final heads (sinal 5aef827,
json_blueprint 8d4839b).

| Package        | Commits          | Result                                                                                                                                                                                                                                                                                                   |
| -------------- | ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| sinal          | 1ff1c18…5aef827  | SINAL-R1–R10. `sinal/correlation`; total definitions that panic with the key; one route-aware `emit`; automatic handler ids; one `Subscription`; forwarder default capacity 1,024. Starts `telemetry` itself. A decode failure now skips one call instead of detaching the handler. 114 tests.           |
| json_blueprint | 0cc4b60…8d4839b  | JSONB-R1–R10. Functions 228 → 129, modules 12 → 6. `use` record builder, N-ary union builder, `to_json`/`decoder` bridges, `contract` with `value_codec`, element-count limit (262,144), codegen in a dev-only package, 1.x frozen at the root. 210 Erlang tests, 69 codegen, `jsonschema` oracle 73/73. |
| http_gun       | 0f2e74f…1b705cc  | Migrated; no API change. Sinal snapshot at 5aef827. 136 tests, full gate.                                                                                                                                                                                                                                |
| saga           | 43ae141, 2eb5cf5 | Migrated; no API change; 235 added, 340 removed. 165 tests plus examples, negative fixtures and durable restart.                                                                                                                                                                                         |
| grind          | c1920e6, 69bbc3c | Migrated; no API change; 823 added, 1,339 removed. 269 tests, Oban oracle, consumer 12.                                                                                                                                                                                                                  |
| llm_wire       | 6b5ae2d, bc5d626 | Migrated. `tool_from_contract` takes `contract.Contract`. The Float-based Value→JSON bridge is replaced by exact `value.to_json`. 234 tests, full gate.                                                                                                                                                  |
| relay          | 23e4063, cf0295b | Migrated; the ~70-line Value↔JSON bridge is gone. Tool schemas expose `UnionSchema`. 143 tests in CI mode.                                                                                                                                                                                               |
| warden         | bf4f796, efead8a | Migrated; no API change. 130 tests, negative compile tests, consumer 8.                                                                                                                                                                                                                                  |
| fabric         | 7844fa7          | Migrated. `fork.result_codec` returns the codec directly. `graph/llm` receipts write v2 and still read v1. 45/45 gate checks, core 653.                                                                                                                                                                  |

All eight apps pass on these heads. Each recorded its result in a `## Re-run
after wave 2` section of its `FEEDBACK.md`. Resolved outright: EXT-6, SD-6,
SMCP-8 and TH-6. Partly resolved: the Blueprint bridge findings (EXT-5, RA-8)
and every correlation and handler-id finding on the application side.

**Follow-ups found during wave 2**, now part of later waves:

| Package               | Item                                                                                                                                                                                                                           | Wave    |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------- |
| grind, json_blueprint | Grind's `worker.codec` encoder cannot fail; Blueprint's `to_json` can. Apps bridge with a panic. Give grind's codec a failure channel (GRIND-R5/R6), so a value the codec rejects fails at submit with a typed error.          | 3       |
| http_gun              | http_gun already writes its own random id under the metadata key `correlation`, which clashes with `sinal/correlation`. HTTPGUN-R8 must replace it, not add a second key.                                                      | 3       |
| sinal                 | `correlation.field()` is always `Option`; events that always carry a correlation need `Some` wrappers and an unreachable `None` arm. Add a required variant. Three apps hit this.                                              | 3       |
| sinal                 | `fields.enum` repeats the constructor list and the compiler cannot check it is complete. Decode failures no longer detach handlers, and emit warns on unlisted values; document a test pattern that round-trips every variant. | 3       |
| sinal                 | Automatic handler ids show as `{sinal_handler, N}`, so an app cannot tell its handlers apart; `with_id` reintroduces a `Result`. Add a readable label that cannot fail.                                                        | 3       |
| sinal                 | No accessor returns an `Event`'s field codecs, so a test cannot encode an event without a native handler. `fields.encode_for_emit` is `@internal` in a public module (convention 9).                                           | 3       |
| json_blueprint        | No `codec.placeholder(codec)` accessor, so a generic wrapper cannot derive a placeholder (fabric has three workarounds). No `codec.value()` identity codec for a pass-through `Value`. Both are additive.                      | 3       |
| json_blueprint        | Every getter in the record builder needs a type annotation; Gleam's inference cannot remove it, so one-field records are longer than before. Documented; revisit if Gleam's inference improves.                                | —       |
| json_blueprint        | `gleam.toml` still says version 1.7.1. Bump to 2.0.0 when publishing.                                                                                                                                                          | publish |
| relay                 | Tool declarations expose `input_schema` as `json.Json`, so consumers render and reparse it. Expose the contract or the schema value (RELAY-R4).                                                                                | 4       |

## sinal

| Id        | Change                                                                                              | Breaks              | Effort | Wave | Status                                                              |
| --------- | --------------------------------------------------------------------------------------------------- | ------------------- | ------ | ---- | ------------------------------------------------------------------- |
| SINAL-R1  | `sinal/correlation`: opaque string ≤ 128 bytes, `from_string`, `unique`, `field()`                  | no                  | S      | 2    | Adjusted: W3C trace id documented as valid; no `causation` yet (D3) |
| SINAL-R2  | One library emission path: `sinal.emit` follows routes and returns `Nil`; delete `emit_routed`      | yes                 | M      | 2    | Planned                                                             |
| SINAL-R3  | Infallible encoding; `fields.field(key, encode, decoder)` takes a `decode.Decoder`; `float`, `enum` | yes                 | M      | 2    | Planned                                                             |
| SINAL-R4  | Constant descriptors are total; definition bugs panic with the key                                  | yes                 | M      | 2    | Planned (matches D4)                                                |
| SINAL-R5  | Automatic handler ids; `observe` is total                                                           | yes, simpler        | S      | 2    | Planned                                                             |
| SINAL-R6  | One `Subscription` type for every registration                                                      | yes, no outside use | S      | 2    | Planned                                                             |
| SINAL-R7  | `forwarder.new(name)`, default capacity 1,024, `supervised`                                         | yes                 | S      | 2    | Planned (D5 value)                                                  |
| SINAL-R8  | Remove dead error variants; add `describe_*`                                                        | barely              | S      | 2    | Planned                                                             |
| SINAL-R9  | Trim `sinal/span`; make `sinal/exception` internal                                                  | no outside use      | S      | 2    | Planned                                                             |
| SINAL-R10 | Module docs, README defaults table, `telemetry >= 1.4.2 and < 2.0.0`                                | no                  | S      | 1–2  | Planned                                                             |

## json_blueprint (2.0)

| Id        | Change                                                                                             | Breaks                     | Effort | Wave | Status                                                                                                            |
| --------- | -------------------------------------------------------------------------------------------------- | -------------------------- | ------ | ---- | ----------------------------------------------------------------------------------------------------------------- |
| JSONB-R1  | `use`-based record builder replaces `record2`, `record3`, `combine` and the optional-field trio    | unreleased callers         | M      | 2    | Planned                                                                                                           |
| JSONB-R2  | Bridges: `codec.to_json`, `codec.decoder`, `value.to_json`, `value.decoder`                        | no                         | M      | 2    | Planned                                                                                                           |
| JSONB-R3  | Infallible definitions with one `DefinitionError`                                                  | unreleased callers         | M      | 2    | Adjusted: source definitions panic with the key; `check` and `contract.from_schema` return `DefinitionError` (D4) |
| JSONB-R4  | N-ary union builder (`union`, `variant`, `unit_variant`, `match`) replaces binary `tagged`         | relay and llm_wire matches | M      | 2    | Planned                                                                                                           |
| JSONB-R5  | Generator helpers move to `internal/generated`; codegen to a dev-only package                      | regenerate once            | S      | 2    | Planned                                                                                                           |
| JSONB-R6  | `runtime` renamed `contract`; absorbs `document`; `contract.value_codec`; typed `ContractMismatch` | unreleased callers         | M      | 2    | Planned                                                                                                           |
| JSONB-R7  | Memory-bounded parsing; one limits type; 1 MiB and depth 64 defaults                               | larger inputs rejected     | S      | 1    | Planned (D5 values)                                                                                               |
| JSONB-R8  | Flat errors `{path, reason}` without string payloads; `describe_*`                                 | unreleased callers         | M      | 2    | Planned                                                                                                           |
| JSONB-R9  | Shrink and freeze the 1.x surface; `dynamic` becomes internal                                      | 1.x `dynamic` importers    | S      | 2    | Planned                                                                                                           |
| JSONB-R10 | Renames, a `float` codec, docs                                                                     | small                      | S      | 2    | Planned                                                                                                           |

## http_gun

| Id          | Change                                                                                                                | Breaks                       | Effort | Wave | Status                                  |
| ----------- | --------------------------------------------------------------------------------------------------------------------- | ---------------------------- | ------ | ---- | --------------------------------------- |
| HTTPGUN-R1  | Opaque `Config`, `Limits`, `Policy`, options; `with_*` setters; typed `ConfigError`                                   | yes, mechanical              | M      | 3    | Planned                                 |
| HTTPGUN-R2  | One entry point per operation; per-call settings as client views (`with_timeout`, `with_deadline`, `with_body_limit`) | yes                          | M      | 3    | Planned                                 |
| HTTPGUN-R3  | Named timeouts: connect (with DNS), pool, request, idle; `Infinity` explicit; `next_within`                           | yes                          | M      | 3    | Planned (D5 values)                     |
| HTTPGUN-R4  | Opaque `Failure` with closed `Kind`, `is_retryable`, `status`, `name`, `to_json`, `decoder`                           | yes (warden, llm_wire, apps) | M      | 3    | Planned                                 |
| HTTPGUN-R5  | `supervised(config, name)` and `named(name)`: handle survives restarts                                                | yes                          | M      | 3    | Planned                                 |
| HTTPGUN-R6  | Destination builders for the three test setups; per-call narrowing; public `check`; `host:port` entries               | yes                          | M      | 3    | Planned                                 |
| HTTPGUN-R7  | Playback matchers; readable cassettes; `fixture` into `testing`, `recording` into `cassette`                          | test code                    | M      | 3    | Planned                                 |
| HTTPGUN-R8  | Correlation from application values (`sinal/correlation`); routed observations without a dedicated forwarder          | default change               | S      | 3    | Adjusted: uses `sinal.Correlation` (D3) |
| HTTPGUN-R9  | Bound `batch` bytes, idle pooled connections, `cancel`; drain on stop                                                 | small                        | M      | 3    | Planned (D5 values)                     |
| HTTPGUN-R10 | Docs, CHANGELOG, Hex ranges; decide `gun`/`cowlib` pins                                                               | no                           | S      | 1–3  | Planned                                 |

## saga

| Id       | Change                                                                                               | Breaks                     | Effort | Wave | Status                             |
| -------- | ---------------------------------------------------------------------------------------------------- | -------------------------- | ------ | ---- | ---------------------------------- |
| SAGA-R1  | `unknown_when(step, fn(e) -> Bool)`: returned "maybe sent" errors count as unknown effects           | exhaustive `UnknownEnding` | M      | 3    | Planned                            |
| SAGA-R2  | One durable `Run` handle; labelled `durable.new`; storage addressed by execution id                  | durable callers, adapters  | M      | 3    | Planned                            |
| SAGA-R3  | Storage ownership as an opaque `Claim` value; opaque contract; `saga_postgres`                       | adapters (they shrink)     | L      | 3    | Planned                            |
| SAGA-R4  | `drive(run, timeout:)`; the runner stops when its caller dies and keeps the checkpoint               | signature                  | M      | 3    | Planned (D5)                       |
| SAGA-R5  | `codec.json(version, to_json, decoder)`; typed durable errors with `error_kind` and `describe_error` | codecs, error matches      | M      | 3    | Planned                            |
| SAGA-R6  | Collapse keyed/unkeyed pairs; labelled callback records; stable idempotency key across retries       | callbacks, mechanical      | S      | 3    | Planned                            |
| SAGA-R7  | Correlation and durable id in events; rename to `saga/telemetry`                                     | positional matches, rename | S      | 3    | Adjusted: `sinal.Correlation` (D3) |
| SAGA-R8  | Opaque `Config`; explicit unbounded values; capped `RetryAfter`                                      | record-update callers      | S      | 3    | Planned                            |
| SAGA-R9  | Persistence modifiers in `durable`; `map_step_errors` keeps codecs                                   | durable authoring          | S      | 3    | Planned                            |
| SAGA-R10 | `memory.start` and `supervised`; adapter lifecycle                                                   | renames                    | M      | 3    | Planned                            |
| SAGA-R11 | Stable classification for growing unions; hide machinery                                             | barely                     | S      | 3    | Planned                            |
| SAGA-R12 | Module docs that render (`////`); docs that match behavior                                           | no                         | S      | 1    | Planned                            |
| SAGA-R13 | Hex dependency ranges                                                                                | no                         | S      | 3    | Planned                            |

## grind

| Id        | Change                                                                                                            | Breaks      | Effort | Wave | Status                                                                 |
| --------- | ----------------------------------------------------------------------------------------------------------------- | ----------- | ------ | ---- | ---------------------------------------------------------------------- |
| GRIND-R1  | Pool built from the app's `pog.Config`; `grind.connection`; `submit_in(grind, tx, job)` (blockers CHK-1, CHK-2)   | yes         | L      | 3    | Planned                                                                |
| GRIND-R2  | One supervised runtime: `grind.supervised`, `named`; `stop` from any process; submit-only nodes                   | yes         | M      | 3    | Planned                                                                |
| GRIND-R3  | Worker owns its queue; registry derived from workers; `worker.new` and `worker.responding`; no dummy `perform`    | yes         | M      | 3    | Planned                                                                |
| GRIND-R4  | Opaque `worker.Context`: job id, attempt, snooze count, correlation, cancellation, deadline                       | no (new)    | L      | 3    | Adjusted: `sinal.Correlation` (D3)                                     |
| GRIND-R5  | One admission builder (`job.new \|> with_id \|> at \|> unique`) and one `grind.submit`; receipts for every submit | yes         | M      | 3    | Planned                                                                |
| GRIND-R6  | Typed `Outcome` with `Failure(e)`; `ErrorKind`; `describe_*`; `job.state_name`                                    | yes         | M      | 3    | Planned                                                                |
| GRIND-R7  | Abandonment policy (`ReplayAfterLeaseExpiry`, opt-in) and `admin.list`                                            | no          | L      | 3    | Planned: needed under any outcome of decision 1                        |
| GRIND-R8  | Bound every wait by default; `await(within:)`                                                                     | behavior    | M      | 3    | Planned (D5: 15 min, 100 snoozes, 7 days, 1 MiB, 15 s connect, jitter) |
| GRIND-R9  | Opaque `Config`; `config`, not `settings`; no `Validated*` types                                                  | yes         | S      | 3    | Planned                                                                |
| GRIND-R10 | Consolidate to 8 modules; machinery out of the public surface (59 `@internal pub`)                                | yes         | M      | 3    | Planned                                                                |
| GRIND-R11 | Public `grind/testing`                                                                                            | manual mode | M      | 3    | Planned                                                                |
| GRIND-R12 | Dependencies, CHANGELOG, docs that match behavior                                                                 | partly      | S      | 1–3  | Planned                                                                |

## llm_wire

| Id      | Change                                                                                                        | Breaks | Effort | Wave | Status                                         |
| ------- | ------------------------------------------------------------------------------------------------------------- | ------ | ------ | ---- | ---------------------------------------------- |
| LLM-R1  | Stream defaults: whole call, first token and idle gap timers; SSE line limit; tool-argument deltas reset idle | yes    | M      | 1, 4 | Planned (D5: 600 s / 180 s / 60 s; 1 MiB line) |
| LLM-R2  | One execution family parameterized by output; delete the `_structured` twins; one `ReadError`                 | yes    | M      | 4    | Planned                                        |
| LLM-R3  | `advise(failure)` from the failure alone; classifies http_gun failures; delay in ms                           | yes    | S–M    | 4    | Planned                                        |
| LLM-R4  | Typed failure detail: `Limit` enum, `InvalidOutput` with raw output, separate `PrepareError`                  | yes    | M      | 4    | Planned                                        |
| LLM-R5  | Callers construct only opaque values; secrets redacted                                                        | yes    | M      | 1, 4 | Planned (redaction in wave 1)                  |
| LLM-R6  | One root module and one assistant message type                                                                | yes    | M      | 4    | Planned                                        |
| LLM-R7  | Public conversation and turn JSON codecs                                                                      | no     | M      | 4    | Planned                                        |
| LLM-R8  | Call id and correlation in telemetry metadata                                                                 | yes    | S      | 4    | Adjusted: `sinal.Correlation` (D3)             |
| LLM-R9  | Tool declarations without Blueprint ceremony                                                                  | partly | S      | 4    | Planned                                        |
| LLM-R10 | Plaintext rule moves to http_gun's destination policy                                                         | no     | S      | 3–4  | Planned                                        |
| LLM-R11 | Test fakes for each built-in wire (`testing.events_for`)                                                      | no     | M      | 4    | Planned                                        |

## relay

| Id        | Change                                                                                          | Breaks           | Effort | Wave | Status                                                                          |
| --------- | ----------------------------------------------------------------------------------------------- | ---------------- | ------ | ---- | ------------------------------------------------------------------------------- |
| RELAY-R1  | Mountable `http.handler`; context built from the request                                        | yes              | L      | 4    | Planned                                                                         |
| RELAY-R2  | One typed `client.Error` with evidence, HTTP status and RPC error; `call` returns `Result`      | yes              | M      | 4    | Planned                                                                         |
| RELAY-R3  | Client headers; `call_with` deadline and cancellation; timeout closes the call's connection     | partly           | M–L    | 4    | Planned                                                                         |
| RELAY-R4  | `tool.define` as the single fallible step; 3 binders instead of 8; opaque call context          | yes              | M      | 4    | Planned                                                                         |
| RELAY-R5  | Readable authorization values; rendered challenge and resource metadata; `http.with_protection` | no (additive)    | M–L    | 1, 4 | Planned (token redaction audit in wave 1)                                       |
| RELAY-R6  | `http.start`, `supervised`, `stop`, `port`; typed `StartError`; `stdio.serve`                   | yes              | M      | 4    | Planned                                                                         |
| RELAY-R7  | Opaque configuration and service entries                                                        | yes              | M      | 4    | Planned                                                                         |
| RELAY-R8  | Hide machinery (`emit_*`, framer, `*_to_json`, `protocol/*`); conformance server to `dev/`      | barely           | S      | 4    | Planned                                                                         |
| RELAY-R9  | Server description separate from reducer state                                                  | advanced callers | M      | 4    | Planned                                                                         |
| RELAY-R10 | One name per meaning (duplicate type names)                                                     | yes              | S–M    | 4    | Planned                                                                         |
| RELAY-R11 | Protocol data matches the pinned revision (`Annotations`, byte content)                         | yes              | M      | 4    | Planned                                                                         |
| RELAY-R12 | Telemetry names the tool and carries correlation                                                | no               | S–M    | 4    | Adjusted: `sinal.Correlation` (D3)                                              |
| RELAY-R13 | Bounded, fail-closed defaults                                                                   | mostly no        | M      | 1, 4 | Planned (D5: 1,024 requests, 64 streams, depth 64, 15 s keepalive, fail closed) |
| RELAY-R14 | One entry type per service; list-based `listen`                                                 | yes              | M      | 4    | Planned                                                                         |
| RELAY-R15 | Public `relay/testing`                                                                          | no               | M      | 4    | Planned                                                                         |
| RELAY-R16 | Module docs (none render today), CHANGELOG, Hex ranges                                          | no               | S      | 1    | Planned                                                                         |

## warden

| Id         | Change                                                                                                               | Breaks | Effort | Wave | Status                                             |
| ---------- | -------------------------------------------------------------------------------------------------------------------- | ------ | ------ | ---- | -------------------------------------------------- |
| WARDEN-R1  | Custody and transaction store port (`get`, compare-and-set `put`, `delete_expired`); in-memory default               | no     | L      | 4    | Planned; store trust is a package decision (below) |
| WARDEN-R2  | `access_token(client, session)`: margin, waits for a running refresh, recovers stale revisions; failures out of `Ok` | yes    | M      | 4    | Planned (D5: 30 s margin, 5 s wait)                |
| WARDEN-R3  | `warden/testing`: scripted provider with test PKI; store conformance check                                           | no     | L      | 4    | Planned                                            |
| WARDEN-R4  | gleam_http boundary; warden sets the binding cookie with secure attributes                                           | yes    | S–M    | 4    | Planned                                            |
| WARDEN-R5  | Handle survives restarts; lazy discovery when supervised                                                             | yes    | M      | 4    | Planned                                            |
| WARDEN-R6  | Opaque `Config`; `service_client` without a redirect URI                                                             | yes    | M      | 4    | Planned                                            |
| WARDEN-R7  | RFC 7009 revocation on logout                                                                                        | yes    | M      | 4    | Planned                                            |
| WARDEN-R8  | Introspection with `audiences`, typed claims decoding, strict `exp` check                                            | yes    | S      | 4    | Planned                                            |
| WARDEN-R9  | Failure classification and descriptions                                                                              | partly | S      | 4    | Planned                                            |
| WARDEN-R10 | `warden/telemetry`: closed reasons, correlation, session events                                                      | yes    | M      | 4    | Adjusted: `sinal.Correlation` (D3)                 |
| WARDEN-R11 | Small corrections                                                                                                    | small  | S      | 4    | Planned                                            |

Warden keeps its sessions per identity unbounded and documents it (D5).
`complete_login` gets one 30 s bound.

## fabric

| Id         | Change                                                                                         | Breaks             | Effort | Wave | Status                                                                                        |
| ---------- | ---------------------------------------------------------------------------------------------- | ------------------ | ------ | ---- | --------------------------------------------------------------------------------------------- |
| FABRIC-R1  | Typed final answers: `agent.with_answer(spec, codec)`, `Completed(answer)`                     | yes                | L      | 5    | Planned                                                                                       |
| FABRIC-R2  | Caller-supplied run ids: `fabric.start(.., id:, ..)`, `run.new_id()`; one start                | yes                | S      | 5    | Planned: holds under any outcome of decision 1                                                |
| FABRIC-R3  | Bounded by default: tools, models, approvals, waits, result size                               | behavior           | M      | 5    | Adjusted: model call 600 s, not 120 s (D5)                                                    |
| FABRIC-R4  | Typed failures; one error per facade; opaque `ModelError` with kind and retry-after            | yes                | M      | 5    | Planned for the agent runtime; graph part deferred                                            |
| FABRIC-R5  | One vocabulary for the agent and graph runtimes                                                | yes                | L      | —    | Deferred (decisions 1 and 2)                                                                  |
| FABRIC-R6  | Move 72 `@internal` functions into `internal/`; backend modules under `fabric/store/`          | `@internal` users  | M      | 5    | Planned                                                                                       |
| FABRIC-R7  | Opaque constructed configuration (`agent.Limits`, `graph.with_timeouts`, `definition.Spec`, …) | yes                | M      | 5    | Planned for the agent runtime; graph part deferred                                            |
| FABRIC-R8  | Run id and turn in `model.Request`                                                             | positional         | S      | 5    | Planned                                                                                       |
| FABRIC-R9  | Tool parity: replay policy, timeout, public accessors, typed reconciliation                    | no                 | S      | 5    | Planned                                                                                       |
| FABRIC-R10 | `fabric_relay` replaces `fabric_mcp`                                                           | `fabric_mcp` users | L      | 5    | Planned after relay wave 4                                                                    |
| FABRIC-R11 | `fabric_saga` passes run context and evidence                                                  | one argument       | S      | 5    | Planned                                                                                       |
| FABRIC-R12 | Optional provider adapters (`fabric_llm`); one HTTP client                                     | import path        | S      | —    | Out: adapters stay in fabric core (owner, 1 October). The single-client part is already done. |
| FABRIC-R13 | Lifecycle: sweeper, owner, stop                                                                | renames            | S      | 5    | Planned; sweeper behavior with grind-driven runs waits for decision 1                         |
| FABRIC-R14 | Naming collisions                                                                              | renames            | S      | 5    | Planned                                                                                       |
| FABRIC-R15 | `fabric/telemetry`, correlation, graph events                                                  | import path        | M      | 5    | Adjusted: `sinal.Correlation` (D3); graph events deferred                                     |
| FABRIC-R16 | README common path first, defaults table, CHANGELOG, Hex ranges                                | no                 | S      | 1, 5 | Planned                                                                                       |

## Package decisions still open

The reports list these package-local questions. Each wave starts by settling
its own. Where the report recommends an answer, the plan assumes it unless the
owner says otherwise.

| Package        | Question                                                   | Report's recommendation                                                                    |
| -------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| sinal          | Event names and keys as `String` or `Atom`                 | `String` with a grammar check                                                              |
| sinal          | Ship a default forwarder application                       | open                                                                                       |
| json_blueprint | Where 1.x lives                                            | frozen at the root, so 1.x code keeps compiling                                            |
| json_blueprint | Codegen placement                                          | a dev-only package                                                                         |
| json_blueprint | Numbers without an exact gleam_json form in `to_json`      | typed error                                                                                |
| json_blueprint | 1.x union wire format (`type`/`data`)                      | open                                                                                       |
| http_gun       | May a per-call timeout exceed the client's                 | yes, as an explicit view (needed by llm_wire and relay)                                    |
| http_gun       | `gun` and `cowlib` exact pins                              | open: depends on the FFI's use of undocumented terms                                       |
| http_gun       | Redaction policy in the first release                      | open: required scope in the design                                                         |
| saga           | One `Storage` per pool or per execution                    | per pool, with the id per operation                                                        |
| saga           | Ship `saga_postgres` in the first release                  | yes (two apps wrote one)                                                                   |
| saga           | Who re-drives suspended executions                         | waits for decision 1                                                                       |
| grind          | Pool ownership and transactional submit shape              | grind builds its pool from the app's `pog.Config`; `submit_in` takes a borrowed connection |
| grind          | Default worker and codec version `"1"`                     | open                                                                                       |
| llm_wire       | Invalid structured output as a failure or an outcome       | a failure                                                                                  |
| relay          | Move the client onto http_gun                              | yes, after HTTPGUN-R3 (idle timeout, long streams)                                         |
| relay          | Split the mist server into `relay_mist`                    | open                                                                                       |
| warden         | Sealed or trusted durable stores                           | sealed                                                                                     |
| warden         | Resource-server role (local JWT validation)                | open                                                                                       |
| warden         | `warden/testing` inside the package or as `warden_testing` | inside the package                                                                         |
| fabric         | Reviewer as a required string or a typed identity          | open                                                                                       |
| fabric         | Where the Relay ↔ fabric adapter lives                     | `fabric_relay` (FABRIC-R10)                                                                |
