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

### Follow-up round results (2 October 2026)

The owner asked to fix four criticisms from the wave 2 re-runs, and added a
fifth: one builder style across sinal and json_blueprint. Each fix landed in
its package. Every dependent package and all eight apps were then migrated and
validated before anything was pushed.

| Criticism                                                              | Fix                                                                                                                                                                                                                                                 | Commits                |
| ---------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- |
| Record builder needs a getter annotation per field                     | Getter moved after the callback as a labelled `get:`, so Gleam infers it: `use sku <- codec.field("sku", codec.string(), get: fn(q) { q.sku })`. The 6-field `Invoice` went from 50 to 40 lines and 9 annotations to 0. Wire output byte-identical. | json_blueprint bb4da39 |
| Sinal builder binds by position (silent swaps) and needs an annotation | Same shape as json_blueprint: `use route <- fields.include(fields.string("route"), get: fn(m) { m.route })` … `fields.success(..)`. Fields bind by name; no swap found in 73 existing sites. Wire output byte-identical.                            | sinal 5e8bee3, 6de2b69 |
| `correlation.field()` is always `Option`                               | `correlation.required_field()`, same key and encoding, readable by `field()` handlers and the reverse.                                                                                                                                              | sinal f9cca37          |
| grind's encoder cannot fail                                            | `worker.codec` takes a fallible encoder; `worker.infallible` wraps a plain one. Every submit path returns `InvalidInput` before writing; an unencodable output ends the job `runtime_failed` without retry.                                         | grind c44e4be          |
| http_gun's `correlation` key clashes                                   | `with_correlation` takes `sinal/correlation.Correlation`, carried under `correlation`; http_gun's own id is the opaque `RequestId` under `request_id`. Only apps used the old `Id`.                                                                 | http_gun c45adfe       |

Package migrations: saga d4eef94, grind 2d66835, http_gun 056536b, warden
6c06de5, llm_wire ea7c90b, relay 5f3c183, fabric 310c184. Each kept its
public API and its wire and stored formats.

Effect on the apps, net lines of glue removed: support_desk 62, research_agent
61, extractor 28, webhooks 29, secure_mcp 27, checkout 23, tool_hub 6,
sso_portal 0. Every app that called http_gun deleted its table mapping
http_gun ids to its own key. The wave 2 follow-up rows for the grind encoder,
the http_gun key clash, the `Option` correlation and the getter annotations
are resolved.

**Follow-ups found during the follow-up round:**

| Package | Item                                                                                                                                                                                                                                                    | Wave |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---- |
| sinal   | A correlation is 1–128 bytes. Two apps derive it from external ids that can be longer or empty, and silently fall back to `unique()`. Add `correlation.from_key(String) -> Correlation`, a stable hash that always succeeds.                            | 3    |
| sinal   | A `required_field()` handler skips and reports an event that another emitter sent without a correlation. Intended; document it next to `required_field()`.                                                                                              | 3    |
| sinal   | A `fields.include` block runs once with placeholder values at definition, so it must stay free of side effects. Documented; nothing enforces it.                                                                                                        | —    |
| grind   | `worker.codec` still returns `Result` only to reject an empty version string, so apps keep a `let assert`. Make it total, like sinal's and json_blueprint's constructors (decision 4).                                                                  | 3    |
| grind   | No app test reaches `InvalidInput`, because no app codec has a refinement. Add one app-level rejection test when an app gains a refined codec.                                                                                                          | 3    |
| fabric  | Correlation stops at fabric: the run id exists only after `fabric.start` (FABRIC-R2), model calls receive no run id (FABRIC-R8), and fabric_saga drops the run context (SD-2). These block zero join glue in support_desk, tool_hub and research_agent. | 5    |
| warden  | `restore_session` and `refresh_session` take no correlation, so the `/token` call cannot be tagged (sso_portal).                                                                                                                                        | 4    |
| grind   | The bench L3 open-loop scenario crashed once with `noproc` on its drain pool while nine package gates ran in parallel, and passed when run alone. Check the bench harness for a load-dependent race before the bench is used as release evidence.       | 3    |

### Wave 3 results (3 October 2026)

Wave 3 redesigned http_gun, saga and grind, added `saga_postgres`, and landed
small additive follow-ups in sinal and json_blueprint. Owner decisions for
the wave:

- gun and cowlib on patch ranges, with a CI matrix and an FFI audit;
- redaction of headers and query parameters, plus a caller body hook;
- grind versions default to "1" with total constructors;
- `saga_postgres` ships now.

The apps' re-runs found defects and hazards in the new code, and those were
fixed in the same wave. Every package gate and every app passed on the final
heads before anything was pushed.

| Package        | Commits          | Result                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| -------------- | ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| http_gun       | e55fa1d…0bf369f  | HTTPGUN-R1–R10. Opaque config with setters; views replace `_with_options`; named connect, pool, request and idle timeouts (5 / 5 / 30 / 30 s, idle pooled 60 s, drain 5 s); opaque `Failure` with closed `Kind`, `to_json`/`decoder` and response headers; `supervised`/`named`; destination builders, `host:port`, public `check`, and fail-closed `require_view_destination`; redaction; client labels and `without_observations`; gun/cowlib patch ranges. Functions 47 → 107 (setters and views), records 13 → 6. 200 tests.                     |
| saga           | 89c1aec…92612fd  | SAGA-R1–R13. `unknown_when`, with unknown effects holding the run `Unresolved` by default (`on_unknown(RollBack)` opts in); one durable `Run`; storage addressed by id, claims as values with renewal; a killed runner releases its claim at once; `drive(run, timeout:)`; JSON codecs with fallible encoders; correlation in `saga/telemetry`; total `define`/`durable.new`. 198 tests.                                                                                                                                                             |
| saga_postgres  | 2ee5e0a          | New package. Uses the app's `pog.Connection`, ships its migration, pins pog/pgo with grind, and passes the storage conformance suite on PostgreSQL 16 (26 tests).                                                                                                                                                                                                                                                                                                                                                                                    |
| grind          | ad37658…eb7b173  | GRIND-R1–R12. One `grind` facade over a supervised named runtime; pool from the app's `pog.Config`, shared through `grind.connection`; `submit_in` inside the app's transaction; worker owns its queue; `worker.Context` with attempt, snooze count, correlation, cancellation, deadline and connection; one admission builder; typed `Outcome`; opt-in abandonment replay and `admin.list`; bounded defaults; startup refuses an unmigrated schema (`with_startup_migration`). Functions 161 → 126, no `@internal`. 310+ tests and the Oban oracle. |
| sinal          | c6e2d36…44c5395  | `correlation.from_key`, `fields.check`, handler labels that cannot fail, event codec accessors; `encode_for_emit` moved to `internal/`. 134 tests.                                                                                                                                                                                                                                                                                                                                                                                                   |
| json_blueprint | 60c0dfb, 74a9a7d | `codec.placeholder` and `codec.value()`. Both targets green.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| llm_wire       | 576482e          | Migrated. Each call's budget replaces the client's request timeout and lifts the idle timeout, so the client default no longer cuts reasoning-model streams. 235 tests.                                                                                                                                                                                                                                                                                                                                                                              |
| warden         | 57e1f54…b59ffc1  | Migrated: `persistent_term` shim deleted, `Kind`-based failure mapping, `stop` waits for the client, client labelled `"warden"`. 131 tests.                                                                                                                                                                                                                                                                                                                                                                                                          |
| fabric         | d10635f, 8eb5a16 | Migrated. fabric_saga reports saga's unknown effects as `Uncertain` (SD-1); `codec.placeholder` and `measurement_fields` replace three workarounds. 45/45 gate checks.                                                                                                                                                                                                                                                                                                                                                                               |

Effect on the apps:

- **Blockers resolved:** CHK-1 (shared pool), CHK-2 (transactional submit), CHK-4 and RA-6 (Postgres saga storage) and RA-2 (abandonment replay).
- **Majors resolved:** CHK-3, CHK-5, CHK-6, CHK-7, SD-1, WHK-3, WHK-4, WHK-5, WHK-6 and WHK-8.
- **Glue removed:** checkout removed 553 lines, research_agent 378 and webhooks 211; both hand-written saga storage adapters (326 and 262 lines) are deleted.
- **One pool:** in research_agent, a single pool now serves grind, fabric_postgres, saga_postgres and the app.

**Follow-ups found during wave 3:**

| Package        | Item                                                                                                                                                                                                                          | Wave |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---- |
| llm_wire       | `HttpFailure` still carries http_gun's `Reason`, not the opaque `Failure`, so apps rebuild a `Failure` to reach `Kind` and `is_retryable` (extractor). Carry the `Failure`.                                                   | 4    |
| json_blueprint | The public `Schema` union is matched exhaustively by relay, so a new schema variant (e.g. an "any" schema for `codec.value()`) is a breaking change. Give it a stable classification or an opaque shape before 2.0 publishes. | 2.0  |
| grind          | Consumers cannot be started after an app's own setup; research_agent runs its, fabric's and saga's migrations on a separate pool first. Offer `start(without_consumers)` then `start_consumers`, or a startup hook.           | 4    |
| grind          | A handler's own cancel reason is replaced by "cancelled by caller"; `grind.stop` prints a `pgo_pool_sup` supervisor report in tests.                                                                                          | 4    |
| grind          | `submit_in` emits no `admitted` event because the caller owns the commit; only a recipe is documented.                                                                                                                        | 4    |
| sinal          | `observe_labelled` repeats a label per handler that nothing reads; default the label from the event name. Two clients sharing an http_gun label are indistinguishable.                                                        | 4    |
| saga           | Cancellation can roll back a completed last step (checkout added an undo). Document the rule or offer a "completed steps are final" option.                                                                                   | 4    |
| warden         | Pool and idle timeouts are set equal to the request timeout, so warden does not use http_gun's tighter separate bounds.                                                                                                       | 4    |
| fabric         | fabric_typesafe keeps an `@internal` placeholder accessor because `question.Batch` is not a codec.                                                                                                                            | 5    |
| all            | Timeouts mix `Duration` and `Int` milliseconds across packages (research_agent, secure_mcp). Pick one unit for the ecosystem and record it as a convention.                                                                   | 4    |

### Wave 4 results (3 October 2026)

Wave 4 redesigned llm_wire, relay and warden. Owner decisions for the wave:

- warden validates JWT access tokens locally (RFC 9068) in 1.0;
- relay stays one package with a framework-neutral handler and a thin mist listener;
- every public timeout in the ecosystem is a gleam_time `Duration`, with an explicit `Infinity`.

http_gun and saga switched to `Duration` first. Every package gate and every app passed on the final heads before anything was pushed.

| Package  | Result                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| http_gun | `Duration` for every timeout (`Timeout = After(Duration) \| Infinity`); `destination.with_plaintext` decided against resolved addresses; `http_gun.correlation(client)`; `require_view_destination` counts only real narrowing, so a library's scheme tightening cannot lift an application's fail-closed requirement. 206 tests.                                                                                                                                                                                                                                                            |
| saga     | `Duration` for every timeout, with `execution.Timeout = After(Duration) \| Infinity`. 199 tests.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| llm_wire | LLM-R1–R11. One execution family (`Request(o)`, `Outcome(o)`, `Event(o)`). Stream timers at 600 s whole call, 180 s first token and 60 s idle, reset by tool-argument deltas. `advise(failure)` returns a `Duration`. Typed errors carry http_gun's `Failure`. Opaque config. Message and turn JSON codecs. Correlation read from the http_gun view. `testing.events_for` per wire. The plaintext rule now lives in http_gun. The ported tests found three bugs: a usage report ending the first-token wait, interrupted fakes completing, and three oracle tests that never ran. 287 tests. |
| relay    | RELAY-R1–R16. A framework-neutral `http.handler` and a streaming `mist_handler`. The client runs on http_gun, with a typed `client.Error` (status, `WWW-Authenticate`, RPC error, evidence) and per-call headers, deadline, cancellation and correlation. Total `define`, three binders, an opaque `Call`, declarations with `input_contract`. Readable authorization values, rendered challenge and RFC 9728 metadata, and `http.new_protected` with a caller verifier. Bounded defaults; `relay/testing`. Seven bugs found and fixed. 277 tests; conformance 108/108.                      |
| warden   | WARDEN-R1–R11. A sealed store port (AES-256-GCM) with conformance; `access_token` with a 30 s margin and 5 s wait; `warden/testing` (scripted provider and PKI); a gleam_http boundary; restart-stable handles; RFC 7009 revocation; hardened introspection; and `warden/resource`, local RFC 9068 validation that fails closed. Decisions D19–D34 recorded. 175 tests.                                                                                                                                                                                                                      |
| fabric   | Migrated to the new llm_wire. Stored turns use llm_wire's `turn_replay_*` codecs; old records read, proven with captured fixtures. `fabric/llm.gleam` 324 → 204 lines. 45/45 gate checks.                                                                                                                                                                                                                                                                                                                                                                                                    |

Late fixes, also before the push:

- **relay:** a cancelled handler gets its grace period (`http.with_cancellation_grace`, default 5 s) before it is killed, on every cancellation path (TH-3). `client.close` cancels in-flight calls at once instead of draining.
- **warden:** the relay verifier recipe in the README did not compile. It is corrected, mirrored verbatim in the `resource` module doc, and compiled against relay by a new gate step. `resource.verifier` takes labelled `rejected:` and `unavailable:` arguments.

Effect on the apps:

- **Blocker SSO-1 resolved:** sessions survive a warden restart through a pog store that passes `check_store`.
- **SMCP-2 to SMCP-6 resolved:** secure_mcp deleted its MCP mount (114 lines), raw client (109), test provider (459) and challenge code (41). JWT verification went from 89 lines to 18.
- **Test providers:** sso_portal deleted its 644-line provider and 160-line refresh policy.
- **Correlation:** llm_wire events are now fully attributed in extractor and research_agent, and support_desk's llm_wire events now join the ticket (100 → 0 unattributed per ticket).
- **tool_hub:** TH-2, TH-4, TH-6 and TH-9 resolved.

**Follow-ups found during wave 4:**

| Package  | Item                                                                                                                                                                                                                                                                                   | Wave |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---- |
| fabric   | `fabric/llm.model` binds its client when the agent is built, so a per-request correlation needs an agent per request (support_desk, research_agent). `model.Request` should carry the run and correlation (FABRIC-R8).                                                                 | 5    |
| fabric   | fabric's own public timeouts are still `Int` milliseconds (`fabric.await`, `rollback_within`, `with_deadline`, `fabric_postgres.with_lease`). Apply the `Duration` rule (FABRIC-R3/R7).                                                                                                | 5    |
| fabric   | Stored turns written after wave 4 omit the dead `issues` list, so a pre-wave-4 fabric cannot read them. Accepted because fabric is unpublished; recorded in its CHANGELOG.                                                                                                             | —    |
| fabric   | `advise`'s `Retry-After` delay is dropped because `ModelError` has no field for it. `fabric.await` has no selector, so a handler that must react to relay's `cancelled` signal needs an unlinked waiter process (tool_hub: 33 lines that a run-status selector would cut to about 12). | 5    |
| warden   | The test provider has no HTTP `/authorize`, so apps add a login hook in production code; it cannot revoke a single access token; its audience is fixed at start. The trust anchor is PEM only. The redirect URI cannot vary per login (SSO-10).                                        | 5    |
| warden   | Warden's exact-audience check runs before relay's, so a wrong-audience token gets the generic 401.                                                                                                                                                                                     | 5    |
| relay    | A verifier receives only the token, not the request's correlation, so an introspection call cannot be tied to its MCP request. A relay client's correlation does not reach the server's events.                                                                                        | 5    |
| llm_wire | `testing.events_for` covers success streams only and returns a `Reply` the caller must unwrap; tests build `Failure` values by hand; `advise` stops short of grind's snooze-versus-backoff choice.                                                                                     | 5    |
| upstream | pog's `timestamp_decoder` fails on `timestamptz` columns (sso_portal casts through epoch microseconds). gleam_time 1.11's `duration.compare` mis-orders negative durations (saga works around it). Report both upstream.                                                               | —    |

### Round 5 results (3 October 2026)

Round 5 took four wave 4 follow-ups chosen by the owner: correlation at the model call in fabric, `Duration` units and a selector-aware await in fabric, an HTTP `/authorize` and per-login redirect URIs in warden's test provider, and a stable classification for json_blueprint's `Schema`. relay and llm_wire moved to the new schema view. Every package gate and every app passed on the final heads before anything was pushed.

| Package        | Result                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| json_blueprint | `Schema` is opaque. `codec.view(schema)` returns a `SchemaView` of twelve stable kinds, `AnySchema` and an `OtherSchema(document:)` fallback, so later kinds land without breaking matches. `codec.description`; `contract.from_schema` is total. 226 tests.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| relay          | Reads schemas through `codec.view`. An `AnySchema` input is refused as not an object (`InputSchemaNotObject(name, "any")`); an `OtherSchema` is an object only if its document says so. 284 tests; conformance unchanged.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| llm_wire       | Reads schemas through `codec.view`. `AnySchema` tool parameters pass through as `{}`; strict structured output refuses both new kinds. 288 tests.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| warden         | The test provider serves HTTP GET/POST `/authorize`, decided by a `LoginDecision` (`SignIn`/`Refuse`) set with `with_login`/`set_login` and steered by `login_hint`. `testing.revoke_access_token` and `testing.set_access_token_audiences`. `config.with_allowed_redirect_uris` and `LoginOptions.redirect_uri`, matched exactly (`RedirectUriNotAllowed`). Decisions D35–D37; D37 keeps the test provider's port reservation. 183 tests.                                                                                                                                                                                                                                                                                                                                                                                   |
| fabric         | FABRIC-R2, R3 (part), R8 and R11. `fabric.start(runs, agent, id:, context:, prompt:, correlation:)` with `run.new_id()` and `AlreadyStarted(id)`; correlation defaults to `correlation.from_key(id)`. `model.Request` carries run, turn and correlation, and `fabric/llm` applies it per turn, so one agent serves every run. Tool handlers receive `tool.Call(run, action, correlation)`; `fabric_saga.tool` takes `input: fn(ctx, call, input)` and starts the saga under the run's correlation. Every public timeout is a `Duration` (`run.Timeout = After \| Infinity`, `graph.with_timeouts`). Defaults: model call 600 s, tool body 60 s (`Uncertain` on expiry), tool result 1 MiB. `fabric.await_with(run, within:, or: selector)` returns `Reached(status) \| Interrupted(msg)`. 45/45 gate checks; core 672 tests. |

Effect on the apps:

- **support_desk:** one agent for every ticket; a run id derived from the ticket, so a second open reaches the stored run. 0 of 267 events unattributed, where 22 saga events and the refund, notify and void HTTP calls were before (SD-2, SD-3 resolved).
- **tool_hub:** the 33-line waiter became `fabric.await_with(.., or: relay_tool.cancelled(call))` (TH-3); the per-question agent and the ~35-line run↔correlation link are gone (TH-7). src +102 −143.
- **research_agent:** the job starts its run as `research-<job>-<attempt>`, so a replay recovers its run; `run_id`, `set_run`, `bind_run` and `agent_for` are gone, and `await_with` replaced 250 ms polling (RA-1, RA-3, RA-7). 0 of 51 events unattributed. Net −28 lines.
- **sso_portal:** the browser follows the test provider's `/authorize`; `Context.login_response` and the production login hook are gone (SSO-10).
- **secure_mcp:** `/login` passes `login_hint`; its own token revocation helper gave way to `testing.revoke_access_token`.

**Follow-ups found during round 5:**

| Package | Item                                                                                                                                                                                                                                            | Wave |
| ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---- |
| fabric  | Approval expiry and graph waits stay unbounded unless set. The planned 7-day defaults need a durable clock in the agent record and would stop stored graph runs recovering; both wait for decisions 1 and 2.                                    | —    |
| fabric  | A saga step cannot read the run's correlation, so the saga's own HTTP client is correlated by hand (support_desk, research_agent). `lease.lose` carries no correlation.                                                                         | 5    |
| fabric  | `run.parse_id` returns a `Result`, so an id built from known-good parts needs `let assert`. The migration guide's "start under the job id" reopens a finished run on retry; it should say to include the attempt when a retry must start fresh. | 5    |
| fabric  | A second `start` with an existing id drops its prompt silently; `AlreadyStarted` could say whether the stored run was started with the same input.                                                                                              | 5    |
| relay   | A relay client's correlation still does not reach the server's events (tool_hub: 17 relay events unjoined per question). A handler gets no invocation id, so a retried tool call starts a second run.                                           | 5    |
| warden  | D37: the test provider still reserves its port before it starts. A local JWT cannot see revocation (`revoke_access_token` only affects introspection), which secure_mcp now asserts.                                                            | —    |
| apps    | One unexplained first-run sso_portal failure (supervisor `init_failed`, 4 tests) did not recur in later runs.                                                                                                                                   | —    |

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

| Id         | Change                                                                                         | Breaks             | Effort | Wave | Status                                                                                                             |
| ---------- | ---------------------------------------------------------------------------------------------- | ------------------ | ------ | ---- | ------------------------------------------------------------------------------------------------------------------ |
| FABRIC-R1  | Typed final answers: `agent.with_answer(spec, codec)`, `Completed(answer)`                     | yes                | L      | 5    | Planned                                                                                                            |
| FABRIC-R2  | Caller-supplied run ids: `fabric.start(.., id:, ..)`, `run.new_id()`; one start                | yes                | S      | 5    | Done (round 5)                                                                                                     |
| FABRIC-R3  | Bounded by default: tools, models, approvals, waits, result size                               | behavior           | M      | 5    | Partly done (round 5): model 600 s, tool 60 s, result 1 MiB; approval and wait defaults wait for decisions 1 and 2 |
| FABRIC-R4  | Typed failures; one error per facade; opaque `ModelError` with kind and retry-after            | yes                | M      | 5    | Planned for the agent runtime; graph part deferred                                                                 |
| FABRIC-R5  | One vocabulary for the agent and graph runtimes                                                | yes                | L      | —    | Deferred (decisions 1 and 2)                                                                                       |
| FABRIC-R6  | Move 72 `@internal` functions into `internal/`; backend modules under `fabric/store/`          | `@internal` users  | M      | 5    | Planned                                                                                                            |
| FABRIC-R7  | Opaque constructed configuration (`agent.Limits`, `graph.with_timeouts`, `definition.Spec`, …) | yes                | M      | 5    | Planned for the agent runtime; graph part deferred                                                                 |
| FABRIC-R8  | Run id and turn in `model.Request`                                                             | positional         | S      | 5    | Done (round 5)                                                                                                     |
| FABRIC-R9  | Tool parity: replay policy, timeout, public accessors, typed reconciliation                    | no                 | S      | 5    | Planned                                                                                                            |
| FABRIC-R10 | `fabric_relay` replaces `fabric_mcp`                                                           | `fabric_mcp` users | L      | 5    | Planned after relay wave 4                                                                                         |
| FABRIC-R11 | `fabric_saga` passes run context and evidence                                                  | one argument       | S      | 5    | Done (round 5): run context and correlation; evidence still open                                                   |
| FABRIC-R12 | Optional provider adapters (`fabric_llm`); one HTTP client                                     | import path        | S      | —    | Out: adapters stay in fabric core (owner, 1 October). The single-client part is already done.                      |
| FABRIC-R13 | Lifecycle: sweeper, owner, stop                                                                | renames            | S      | 5    | Planned; sweeper behavior with grind-driven runs waits for decision 1                                              |
| FABRIC-R14 | Naming collisions                                                                              | renames            | S      | 5    | Planned                                                                                                            |
| FABRIC-R15 | `fabric/telemetry`, correlation, graph events                                                  | import path        | M      | 5    | Adjusted: `sinal.Correlation` (D3); graph events deferred                                                          |
| FABRIC-R16 | README common path first, defaults table, CHANGELOG, Hex ranges                                | no                 | S      | 1, 5 | Planned                                                                                                            |

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
