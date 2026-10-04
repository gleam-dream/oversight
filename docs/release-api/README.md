# Release API review

This review judges each gleam-dream package as a first public release. It asks
whether a developer without context can learn the API quickly, use it
correctly, and upgrade without breakage. Each package report in this
directory follows one rubric:

- the shortest program for the common path;
- the public surface;
- evolution safety;
- default bounds;
- the failure model;
- naming;
- lifecycle;
- dependencies;
- documentation.

The reports cite the eight [composition apps](../../apps/README.md) and the
[composition feedback](../composition/FEEDBACK.md) as consumer evidence.
Scratch consumer packages checked the claims marked as probes.

| Package                             | Verdict                                                                                                                                         | Functions before → after | Report lines |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------ | -----------: |
| [sinal](sinal.md)                   | Runtime release-quality. API carries laboratory scaffolding: three emission paths, fallible constant descriptors, no correlation field.         | 53 → 49                  |          474 |
| [json_blueprint](json_blueprint.md) | Capabilities sound. Surface serves app authors, generated code and 1.x at once; no bridge to `gleam/json`; records above three fields are hard. | 226 → 123                |          525 |
| [http_gun](http_gun.md)             | Runtime contract strong. Every caller-built value is a public record; `_with_options` twins; one deadline bounds every phase.                   | 48 → 87 (36 setters)     |          473 |
| [saga](saga.md)                     | Local path nearly ready. Durable path and `Storage` port are not; returned "maybe sent" errors count as known.                                  | 58 → 76                  |          472 |
| [grind](grind.md)                   | Engine careful. Surface exposes engine parts; app cannot supply the pool or transaction; worker has no job context.                             | 159 → ~105               |          467 |
| [llm_wire](llm_wire.md)             | Runtime sound. Stream defaults fail ordinary calls; plain and structured families duplicate; API keys print in `string.inspect`.                | 79 → 64                  |          481 |
| [relay](relay.md)                   | Protocol core sound. A third of the surface is twin families or machinery; not mountable; client errors are strings.                            | 227 → ~185               |          524 |
| [warden](warden.md)                 | Security core ready and fail-closed. Custody has no store port; refresh surface returns failures inside `Ok`; no test support.                  | 61 → 91 (new capability) |          469 |
| [fabric](fabric.md)                 | Runtime contract strongest in the ecosystem. Two runtimes with two vocabularies; final answer is a `String`; no default bound on waits.         | 191 → ~162               |          487 |

**Verdict.** No package is release-ready as an API. Every runtime that the
apps exercised behaved correctly. The release work is on the
surface: callers construct public records, operations exist in twin
families, failures carry strings, and waits have no bound by default.
Function counts fall where a surface had duplicates. They rise where a
package gains missing capabilities or one-line setters that replace public
records.

## Release blockers

These items must be fixed before any package is published. Each is a defect,
a security exposure, or a publication prerequisite, not a design preference.

| Blocker                                                                                                                                                                                                                                                                        | Owner                               | Evidence                               |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------- | -------------------------------------- |
| **Secrets print in logs.** `string.inspect` of llm_wire's `Config` or `ApiKey` prints the API key, and `provider.headers` returns it. An opaque type does not hide a value on the BEAM; crash reports print it too. Warden already stores secrets as `reveal: fn() -> String`. | llm_wire; audit relay `BearerToken` | [llm_wire](llm_wire.md) R5             |
| **Parser memory is unbounded.** The strict parser's 10 MiB byte cap admitted 10 MiB of `1,` that produced a 503 MB value and a 915 MB heap peak in 6.8 s. The 1.x `decode` and generated codecs parse with no limit.                                                           | json_blueprint                      | [json_blueprint](json_blueprint.md) R7 |
| **OpenAI replies over 16 KiB fail.** The SSE line limit (16 KiB) is below the size of OpenAI's final events, which repeat the full text on one line. A 20 KB probe failed; an 8 KB probe succeeded. A recorded fixture should confirm the event shape.                         | llm_wire                            | [llm_wire](llm_wire.md) R1             |
| **Relay fails open off loopback.** A listener bound to a non-loopback address accepts unauthenticated requests when no protection is configured.                                                                                                                               | relay                               | [relay](relay.md) Q4                   |
| **Module docs do not render.** 63 of 105 public modules have no rendered module doc. Saga writes all 11 with `///` instead of `////`; none of relay's 17 or json_blueprint's 12 renders. grind and http_gun have no CHANGELOG.                                                 | all except fabric, warden           | `gleam docs` probe in [saga](saga.md)  |
| **Path dependencies block Hex.** Every package depends on its siblings by path. Publication must follow the dependency order below, with each package depending on the published version of the one beneath it.                                                                | all                                 | [http_gun](http_gun.md) R10            |
| **Exact pins block patches.** http_gun pins `gun == 2.6.0` and `cowlib == 2.20.0` because its FFI matches undocumented terms. Every consumer then inherits the pin and cannot take a security patch.                                                                           | http_gun                            | [http_gun](http_gun.md) Q5             |

## Ecosystem conventions

These conventions replace the draft that the reviews tested. The reviews
confirmed most rules and corrected some. Each rule names the problem it
removes.

### 1. Callers build opaque values; the library returns records

A compile probe added one field to a library's public record and one variant
to its public union. The result:

| Caller code                                                 | After the library adds a field or variant |
| ----------------------------------------------------------- | ----------------------------------------- |
| `Config(1000, 1)` (positional construction)                 | breaks                                    |
| `Config(timeout: 1000, retries: 1)` (labelled construction) | breaks (wrong arity)                      |
| `Config(..default(), timeout: 1000)` (record update)        | compiles                                  |
| `let Config(timeout:, ..) = c` (label read)                 | compiles                                  |
| `let Config(t, _) = c` (positional pattern)                 | breaks                                    |
| exhaustive `case` on a union that gains a variant           | breaks                                    |

Labels do not protect construction. A public record that callers build turns
every new option into a major release. This already happened: http_gun added
`collect` to `request_options.Options`, and llm_wire stopped compiling.

- A value that callers build (configuration, options, requests, limits,
  policies) is opaque. A constructor takes the required values, safe
  defaults fill the rest, and `with_<option>(value, x)` sets an option.
  Validation happens once, at `start` or at first use, and returns a typed
  error.
- A value that the library returns may be a public record. Its docs tell
  callers to read fields by label.
- This replaces the guideline "use public records for straightforward
  settings" in [PUBLIC-API-GUIDELINES.md](../../PUBLIC-API-GUIDELINES.md).
  Saga's review found that the guideline conflicts with release safety.

### 2. Growing unions have a stable classification

An error or outcome union that may gain variants comes with a small closed
classification (`kind(error) -> Kind`) and the predicates callers need
(`is_retryable`). It also has `describe_error(error) -> String` and a
`name(error) -> String` for logs and stored records. Most callers branch on
`Kind` and never match the growing union exhaustively. Warden's exhaustive
match on http_gun's 22-variant `Reason` shows the cost of the alternative.
Where a failure crosses into another package, it can make the opaque value
itself the failure (http_gun R4).

### 3. Bounded by default

Every wait has a default timeout. Every read has a byte limit, every queue a
capacity, and every retry and snooze a cap. An unbounded value must be
requested explicitly (`with_timeout(Infinity)`), and each package README lists
its defaults in one table. The reviews found these unbounded or ineffective
defaults:

| Package        | Unbounded or ineffective defaults                                                                                                                                                                                                                                    |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| sinal          | Forwarder capacity has no default; route count; atom creation from names and keys. (Handlers run inline by `:telemetry` design; routing to a forwarder is the isolation.)                                                                                            |
| json_blueprint | 1.x `decode` and generated codecs parse with no limit; the byte cap does not bound memory; the 24-digit integer limit is undocumented.                                                                                                                               |
| http_gun       | No idle read timeout; pool checkout, DNS and head wait bounded only by the request deadline; `batch` results (about 80 GB worst case); idle pooled connections; `cancellation.cancel` and actor calls wait forever; `stop` drains nothing.                           |
| saga           | `durable.drive` waits forever and outlives its caller; `RetryAfter` has no cap; storage calls; memory adapter `receive`; file adapter lock at `infinity`; checkpoint size.                                                                                           |
| grind          | Handler execution (lease renewed forever); snooze count; `process_one`; pool checkout at `infinity`; initial connect; job retention without a pruner; payload size; no `await`, so apps poll.                                                                        |
| llm_wire       | Whole-call deadline (60 s) cut to 30 s by http_gun's client default; no first-token timer; idle gap (15 s) not reset by tool-argument deltas; `next` polls with a 5 s timeout.                                                                                       |
| relay          | Concurrent HTTP requests; concurrent `listen` streams; JSON nesting depth; tombstones; stdio progress messages; stdio pending calls; no client reconnect; client timeout keeps the server working.                                                                   |
| warden         | Sessions in custody (decision D14); login option lengths; no single deadline on `complete_login` (about 34 s worst case); no refresh wait; no expiry margin; introspection skips `exp`; actor call (6 s) shorter than key fetch (10 s).                              |
| fabric         | Agent tool bodies (`selector_receive_forever`); custom `model.new` calls; approval waits in both runtimes; graph signal, job, child and fork waits; tool result size. The token budget stays opt-in, because a default would stop every model that reports no usage. |

### 4. Secrets cannot print

A credential (API key, client secret, access token, refresh token, bearer
token) is stored as a closure, as warden's `Secret(reveal: fn() -> String)`
does. A closure prints as a function reference in `string.inspect`, crash
reports and logger metadata. No public function returns a secret inside a
general value such as a header list. A test asserts that `string.inspect` of
each config and token type contains no secret.

### 5. One lifecycle vocabulary

- `start(config) -> Result(Handle, StartError)`;
- `supervised(config, name) -> ChildSpecification(Handle)`, where the handle
  is found by name and stays valid across restarts;
- `named(name) -> Handle` and `stop(handle)`.

Warden and http_gun return handles that a restart invalidates. Grind and
saga offer no child specification. Warden stores its client in
`persistent_term` and coerces it back as a workaround.

### 6. One failure shape per boundary

Each boundary has one error type, named `Error` in its module or
`<Boundary>Error`. No variant carries a `String` that callers must parse,
and no `Dynamic` appears in a public signature. A failure keeps what the
caller needs to decide: the status, whether the request was sent (`NotSent`,
`MaybeSent`, `Completed`), the raw input and the provider. A `String` belongs
only in `describe_error`.

### 7. One ordinary path

An advanced function must add a capability, not repeat the ordinary
function with one more argument. The reviews found these duplicate
families:

| Package        | Duplicate families                                            |
| -------------- | ------------------------------------------------------------- |
| http_gun       | `_with_options` twins                                         |
| llm_wire       | `_structured` twins                                           |
| relay          | eight `handle_*` binders, `content_*` and `dispatch_*` copies |
| saga           | keyed and unkeyed pairs                                       |
| grind          | four `submit*` variants                                       |
| json_blueprint | `record2`/`record3`/`combine`                                 |
| sinal          | seven ways to register a handler                              |

Options belong on a value: a client view (`with_timeout`), a request
builder, or a `use`-based builder (record and union codecs).

### 8. Total constructors for constants

A constructor whose inputs are written in source code does not return
`Result`. Sinal descriptors and Blueprint codecs return `Result` only to
reject cases such as an empty name, and the siblings contain about 100
`let assert` sites as a result. A definition bug is reported at first use or
by a `check` function. The open choice is between a typed error at first use
and a panic with the offending key (sinal Q2, json_blueprint Q2).

### 9. Shared vocabulary

| Concept                       | Name                                                                                                                                                          |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| configuration                 | `config` (not `settings`)                                                                                                                                     |
| setters                       | `with_<option>`                                                                                                                                               |
| telemetry module              | `<pkg>/telemetry` (not `observation`)                                                                                                                         |
| test support                  | `<pkg>/testing`, with an in-process fake of every external party                                                                                              |
| machinery                     | `<pkg>/internal/…`; no `@internal pub` functions in public modules (grind 59, fabric 72)                                                                      |
| correlation                   | `sinal/correlation.Correlation`, carried as the `correlation` metadata field                                                                                  |
| JSON                          | `gleam/json.Json` and `gleam/dynamic/decode.Decoder` as the shared currency                                                                                   |
| submission evidence           | `NotSent`, `MaybeSent`, `Completed`                                                                                                                           |
| durable reference and run ids | accepted from the caller wherever a caller needs idempotency                                                                                                  |
| correlation on the wire       | `x-correlation-id` header; `io.github.gleam-dream/correlation` in MCP `_meta`. Untrusted input, never used to authorize. Not sent to third parties by default |
| idempotency key on the wire   | `io.github.gleam-dream/idempotency-key` in MCP `_meta`: 1–128 visible ASCII, keyed by the authenticated principal                                             |
| stored-record growth          | new fields are optional on read, so records an earlier release wrote keep reading (saga checkpoint format 2, fabric fixtures)                                 |

### 10. Docs are part of the API

Every public module has a `////` module doc. Every README starts with the
common path and contains a defaults table. Every package has a CHANGELOG.
Examples compile as tests.

## Owner decisions

The reviews collected about 60 open questions. These are the ones that block
several packages or a design direction. Package-local questions stay in each
report.

| #   | Decision                                                                                                                                                                                                                                                                   | Blocks                          |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------- |
| D1  | **Durability ownership.** A: fabric owns conversation and graph state. B: fabric owns the agent loop only, and the graph runtime ships separately. C: a shared durability substrate (store, lease, sweeper, ids) for grind, saga and fabric.                               | fabric, grind, saga             |
| D2  | **Is fabric's graph runtime in fabric 1.0?** Splitting it shrinks fabric to about 15 modules and 112 functions.                                                                                                                                                            | fabric                          |
| D3  | **Correlation shape.** An opaque string of at most 128 bytes (proposed), or W3C `traceparent`.                                                                                                                                                                             | sinal, then every package       |
| D4  | **Definition bugs:** a typed error at first use, or a panic with the offending key.                                                                                                                                                                                        | sinal, json_blueprint           |
| D5  | **Per-request deadlines and the plaintext rule move into http_gun.** llm_wire and relay then stop keeping their own versions.                                                                                                                                              | http_gun, llm_wire, relay       |
| D6  | **Relay's client moves onto http_gun**, once http_gun has an idle timeout and allows a stream to be read longer than the client deadline.                                                                                                                                  | relay, http_gun                 |
| D7  | **Warden's resource-server role.** Local JWT access-token validation (RFC 9068) in warden, or a separate library for relay.                                                                                                                                                | warden, relay                   |
| D8  | **Durable store trust.** Sealed records for every durable store (warden proposes it for custody), or trusted stores.                                                                                                                                                       | warden; pattern for saga, grind |
| D9  | **Postgres adapters ship with the first release:** `saga_postgres` (two apps wrote one), grind accepting the app pool, and `fabric_postgres` aligned with grind's pins.                                                                                                    | saga, grind, fabric             |
| D10 | **Where 1.x lives in json_blueprint 2.0** (frozen at the root, recommended), and whether codegen becomes a dev-only package.                                                                                                                                               | json_blueprint                  |
| D11 | **Default numbers.** Handler timeout 15 min, snooze cap 100, retention 7 days, payload 1 MiB (grind); stream deadlines 600 s whole / 180 s first token / 60 s idle (llm_wire); approval expiry 7 days (fabric); parser 1 MiB (json_blueprint); SSE keepalive 15 s (relay). | several                         |
| D12 | **Test support placement:** `<pkg>/testing` inside each package (proposed), or separate `<pkg>_testing` packages.                                                                                                                                                          | warden, llm_wire, http_gun      |

## Release order

Packages publish in dependency order. Each wave changes the API per its
package report, re-runs the composition apps, removes the glue the change
made unnecessary, and records the reduction in each app's `FEEDBACK.md`.

1. **Blockers.** Redact secrets, bound the parser, raise the SSE line limit,
   decide fail-closed relay listeners, fix module docs, add CHANGELOGs. These
   are small and need only D11's numbers.
2. **Leaves: sinal and json_blueprint.** Correlation, total descriptors, one
   emission path; Blueprint 2.0 builders, bridges and the surface cut. Needs
   D3, D4 and D10. Publish both.
3. **Transport and engines: http_gun, saga, grind.** Opaque configuration,
   named timeouts, client views and a classified `Failure` in http_gun; one
   durable `Run` handle, claims as values and `unknown_when` in saga; a
   `grind` facade, app-owned pool, job context and supervision in grind.
   Needs D5, D9 and D11. Publish all three.
4. **Protocols: llm_wire, relay, warden.** One execution family and correct
   stream deadlines; a mountable relay handler and a typed client error; a
   warden store port, `access_token` and `warden/testing`. Needs D6, D7, D8
   and D12. Publish all three.
5. **fabric.** Typed answers, caller run ids, one vocabulary for both
   runtimes, public tool accessors and a relay adapter. Needs D1 and D2.
   Publish.

Waves 2 to 5 each end with every composition app passing on the new heads.
