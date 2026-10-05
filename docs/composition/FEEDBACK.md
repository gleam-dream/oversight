# Composition feedback

> Historical assessment. Round 9 supersedes the bridge-package proposals:
> classification is in llm_wire, run invocation is in fabric, and composition
> uses compiled recipes. See the [Round 9 migration guide](../release-api/migration-round-9.md). Findings below retain their original context.

This document synthesizes the evidence from eight composition apps in
[apps/](../../apps/README.md) and nine package API cards in [scan/](scan/).
It answers whether the gleam-dream packages compose through their public APIs.
It also names the changes that would let the packages compose with less glue.
Each app's `FEEDBACK.md` holds the detailed findings, with `file:line` evidence
in both the app and the package. This document cites those findings by id.

Evidence date: 1 October 2026. The package heads at that date were:

| Package        | Head    |
| -------------- | ------- |
| sinal          | 8acec45 |
| json_blueprint | 129c963 |
| http_gun       | 369da4f |
| saga           | 2c9992e |
| grind          | a1627b5 |
| llm_wire       | 220b134 |
| relay          | f261309 |
| warden         | 55a493b |
| fabric         | 8648f6f |

## Verdict

- Every app works through public imports only. Each app runs its common path,
  one advanced configuration and its failure paths. The eight apps contain 77
  passing tests.
- The packages compose. Composing them costs about 200 to 1,100 lines of
  glue per app. Most of that glue repeats the same few missing pieces across
  apps (correlation, caller-owned resources, codec bridges, outcome mapping),
  not app-specific logic.
- Five findings are blockers: each needed a workaround that defeats part of a
  package's purpose. Two report the same grind defect, one is a
  dependency-range conflict, and two are missing extension points (the grind
  pool and Warden custody). [Fix first](#fix-first) lists the defect and the
  ranges; theme 2 covers the extension points.
- Individual package designs hold up well. Typed failures, worker closures,
  caller-owned HTTP clients, a single schema source for tools, saga
  compensation and Sinal's typed events composed without friction in every app
  that used them.

| App            | Packages                                                                         | Tests | Glue (lines)                        | Blockers                            |
| -------------- | -------------------------------------------------------------------------------- | ----: | ----------------------------------- | ----------------------------------- |
| checkout       | saga, grind, http_gun, sinal + wisp, mist, pog                                   |     9 | ~750                                | CHK-1 grind cannot use the app pool |
| webhooks       | grind, http_gun, sinal + wisp, mist, pog                                         |     8 | ~530                                | WHK-1 grind snooze defect           |
| extractor      | grind, http_gun, llm_wire, json_blueprint, sinal + pog                           |    11 | ~290                                | EXT-1 grind snooze defect           |
| support_desk   | fabric, the workflow bridge, llm_wire, http_gun, blueprint, saga, sinal          |    10 | ~210                                | none                                |
| tool_hub       | relay, fabric, llm_wire, blueprint, http_gun, sinal                              |    11 | ~380                                | none                                |
| secure_mcp     | relay, warden, grind, blueprint, sinal + wisp, mist, pog                         |    10 | ~480, plus a 459-line test provider | SMCP-1 packages do not resolve      |
| sso_portal     | warden, http_gun, sinal + wisp, mist, pog                                        |    10 | ~490, plus a 644-line test provider | SSO-1 sessions cannot be durable    |
| research_agent | fabric, fabric_postgres, grind, saga, llm_wire, http_gun, blueprint, sinal + pog |     8 | ~900                                | none (7 major)                      |

## Fix first

These items are defects or cheap changes that block a common design today.

| Item                                                                                                                                                                                                                                                                                        | Owner                                        | Evidence                                   | Change                                                                                                                                                                                              |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------- | ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A job whose worker has an error codec loses its error-contract version on snooze and on success. A snoozed job is then re-claimed as a contract mismatch and never runs again, and `bind_handle` fails on a finished job.                                                                   | grind                                        | EXT-1, WHK-1, WHK-2, SMCP-7, RA-9 (5 apps) | Keep the registered error-contract version on the job row. Write the error payload, but never clear the version.                                                                                    |
| Library dependency ranges prevent packages from resolving together. Warden pins `gleam_crypto == 1.6.0`, which needs `gleam_stdlib >= 1.0`. Fabric, grind, llm_wire, relay and saga cap `gleam_stdlib < 1.0.0`. Relay and warden, or grind and warden, therefore do not resolve in one app. | warden, relay, grind, saga, llm_wire, fabric | SMCP-1, CHK-9, EXT-10, SD-8, WHK-9, TH-12  | Use `>= x.y.z and < (x+1).0.0` ranges in every library. Widen `gleam_stdlib` to `< 2.0.0`. Remove exact pins unless a private native contract requires them, and document each remaining exact pin. |
| `logout` with a stale session revision returns `SessionStale` and leaves the session live in custody.                                                                                                                                                                                       | warden                                       | SSO-4                                      | End a session by reference regardless of revision.                                                                                                                                                  |
| Over Relay's HTTP transport, `notifications/cancelled` never reaches the running call, because each POST gets its own runtime.                                                                                                                                                              | relay                                        | TH-1                                       | Keep an in-flight request table in the listener and route cancellation to it.                                                                                                                       |
| `send` turns a 200 response with an oversized body into `LimitExceeded` and discards the status. A retrying worker then delivers the request again.                                                                                                                                         | http_gun                                     | WHK-3                                      | Keep the status and headers in the limit failure, or accept a per-request collect policy.                                                                                                           |
| Fabric's `model.stop` event reports unreported usage as zero.                                                                                                                                                                                                                               | fabric                                       | TH-10                                      | Report usage as `Option(Usage)`.                                                                                                                                                                    |
| Relay's CI uses path dependencies but clones no siblings, so it cannot run on GitHub.                                                                                                                                                                                                       | relay                                        | relay pin refresh                          | Check out the pinned sibling SHAs in CI, as saga's workflow does.                                                                                                                                   |

## Fix round results (2 October 2026)

The fix round addressed every item in the table above. Each package passed its
own full gate before push, and all eight apps were re-run on the new heads.
Every package and app now resolves `gleam_stdlib` 1.0.5.

| Item                         | Status   | Commits                                                                                                        | Effect on the apps                                                                                                                                                                                                                        |
| ---------------------------- | -------- | -------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Grind error-contract version | fixed    | grind 7a04831                                                                                                  | extractor, webhooks, secure_mcp and research_agent restored their error codecs and real snoozes. webhooks deleted its read-back worker. The EXT-1 and WHK-1 blockers are gone.                                                            |
| Dependency ranges            | fixed    | warden 845b75e, relay c62bc29, grind b2545a9, saga 26dbc73, llm_wire 56d793d, fabric db81b79, http_gun a2869b7 | secure_mcp deleted its vendored `gleam_crypto` (759 lines). The SMCP-1 blocker is gone. Exact pins remain only on gun and cowlib (http_gun), and on pog and pgo (grind, fabric_postgres), each with a documented private-contract reason. |
| Warden logout                | fixed    | warden 47e49d8                                                                                                 | sso_portal removed its 19-line restore-and-retry glue.                                                                                                                                                                                    |
| Relay HTTP cancellation      | narrowed | relay 5caff50                                                                                                  | MCP 2026-07-28 makes connection close the HTTP cancellation, and `notifications/cancelled` is not expected. Relay now cancels a buffered call when its client disconnects. tool_hub deleted its 68-line raw cancel client.                |
| http_gun oversized body      | fixed    | http_gun 94b11b9                                                                                               | A per-request collect policy with `Truncate` keeps the status. The failure value itself still drops the status, because changing it would break warden's exhaustive match.                                                                |
| Fabric unreported usage      | fixed    | fabric c60bc1c                                                                                                 | `model_turn()` reports `Option(Usage)`, and run totals count unreported replies.                                                                                                                                                          |
| Relay CI                     | fixed    | relay b07a88c                                                                                                  | CI checks out pinned siblings. It needs a `SIBLINGS_READ_TOKEN` repository secret with read access to gleam-dream/sinal. Saga's CI fails today for the same reason.                                                                       |
| Loopback helper (theme 10)   | partial  | http_gun ba497b9                                                                                               | `config.allow_loopback` replaced the nested update in four apps. Apps that also deny public hosts or pin `allowed_hosts` still need the nested update.                                                                                    |

Two blockers remain: grind cannot use the application's pog pool (CHK-1), and
Warden custody cannot be made durable (SSO-1). Both belong to theme 2.

The fix round produced four new findings:

- **Adding a field to a public record breaks positional construction.**
  http_gun added a field to `request_options.Options`, which broke llm_wire's
  positional constructor. A package should document which records callers
  must build with a record update from a default value. Adding a variant to
  a public union also breaks an exhaustive match in a consumer: warden
  matches every http_gun failure reason. Changes to http_gun's failure type
  therefore need warden and llm_wire changed with them.
- **The loopback helper covers only one decision.** A test client usually
  allows loopback and also denies public hosts or pins `allowed_hosts`.
  http_gun should offer a helper such as `config.allow_only_hosts(config,
hosts)` that expresses both (checkout, research_agent, support_desk).
- **A snooze that never consumes an attempt can repeat forever.** With real
  snoozes restored, a receiver that always answers 429 is snoozed without end,
  because the worker cannot see the snooze count. WHK-8 (`JobContext`) is
  therefore major.
- **Relay's client timeout leaves the server working.** A timeout cancels the
  gun stream but keeps the HTTP/1.1 connection open, so the server keeps
  working until `client.close`, which drops every call on that client. The
  client should close a call's connection on timeout or cancel (TH-2).

## Cross-package themes

Each theme appeared in at least three apps. A theme describes a convention that
all packages should follow. Packages still share no runtime dependency unless the
meaning and invariants of the shared value match, as the
[public API guidelines](../../PUBLIC-API-GUIDELINES.md) require.

### 1. Correlation across packages

- **Problem.** No app could follow one request across packages without app
  join tables. Several apps also used process identity to attribute events
  (CHK-5, EXT-4, WHK-5, SSO-7, SMCP-9, SD-3, TH-7, RA-7). In the
  research_agent demo, 15 llm_wire events, 5 saga events and 6 http_gun events
  of one request had no key that joins them to that request.
- **Causes.**
  - http_gun's correlation `Id` is opaque and cannot be built from an
    application value.
  - llm_wire events carry no request id or correlation.
  - Saga events carry no durable execution id or caller label.
  - Grind workers never learn their job id.
  - Fabric's `model.Request` carries no run id, so the adapter cannot tag a
    model call.
  - Relay invocation events name the JSON-RPC method instead of the tool.
- **Convention.** Every package accepts an optional caller correlation value
  at the point where it starts work. It copies that value into every event it
  emits for that work. It also passes the value to every package it calls on
  the caller's behalf (fabric → llm_wire → http_gun). Sinal should define the
  value's name and representation (for example `sinal.Correlation`, a
  string), so that all packages use the same metadata field.
- **Package changes.**
  - http_gun: `telemetry.id_from(String)`.
  - llm_wire: copy the client view's correlation into its metadata.
  - saga: an optional correlation in `execution.Config` and the durable
    reference in event metadata.
  - grind: a job context that exposes the job id and attempt.
  - fabric: the run id in `model.Request`.
  - relay: the tool name and invocation id in events.

### 2. Caller-owned resources

- **Problem.** Several packages own a resource that the application already
  owns or must own.
  - Grind starts its own pog pool from a URL. It cannot use the application's
    pool, so jobs cannot be inserted in the application's transaction
    (CHK-1, CHK-2, EXT-9).
  - Warden's session and transaction custody is an internal actor. A Warden
    restart therefore signs out every user, and no deployment can share
    sessions across nodes (SSO-1).
  - Saga's `Storage` contract requires process-based ownership. Each
    Postgres adapter therefore tracks processes in the VM in addition to the
    database lease (CHK-4, RA-6). The adapters took 326 and 262 lines.
  - http_gun's destination policy belongs to the client only. A multi-tenant
    app therefore needs one client per policy tier and copies the internal
    policy check to validate URLs at registration (WHK-4).
- **Convention.** A library accepts a caller-owned connection, pool, store or
  policy wherever the application already owns one. The library then documents
  the guarantees that remain its own. This follows the guideline "keep
  application values generic and implementation state local".
- **Package changes.**
  - grind: accept a `pog.Connection` in `Settings`, and add
    `submit_in(database, tx: pog.Connection, ...)`.
  - warden: `config.with_custody(store)`, with a store port built from the six
    operations in `internal/custody_store.gleam`.
  - saga: make storage ownership an opaque value returned by `claim` instead
    of the calling process.
  - http_gun: expose the policy check (`destination.check(policy, uri)`) and
    allow a per-request policy override.
  - grind and saga could also ship Postgres storage packages, as fabric
    ships `fabric_postgres`.

### 3. Outcome evidence: was the effect sent?

- **Problem.** http_gun reports whether a failed request reached the peer
  (`NotSubmitted` or `MayHaveBeenSent`). That evidence is lost at every
  boundary above it:
  - Saga treats a returned error as a known failure. Its `unknown_effects`
    report stays empty unless the step crashes. A crash in turn renders the
    typed failure as an Erlang term string (CHK-3, SD-1).
  - the workflow bridge can therefore tell the model that a refund failed cleanly
    when the provider took the refund (SD-1).
  - Relay's `TransportError` does not say whether a call was sent, so a server
    that was already down looks like a lost reservation (TH-4).
  - llm_wire reports invalid structured output as `EffectUnknown`, although
    the response completed (EXT-3).
- **Convention.** Every package whose operation has an external effect reports
  submission evidence with the same three meanings: not sent, maybe sent, and
  completed. Each package keeps its own type. The names and meanings match, so
  one application function maps each package's evidence.
- **Package changes.**
  - saga: a step option that classifies some returned errors as unknown
    effects.
  - relay: an `evidence` field on transport failures.
  - llm_wire: `OutputValidationError(raw_output, failure)` with completed
    evidence.

### 4. Cancellation across process boundaries

- **Problem.** Cancellation stops at package boundaries.
  - Relay cancels by killing the handler worker and gives the handler no
    signal. A fabric run started by the handler keeps running unless the app
    monitors the worker (TH-3).
  - Relay's client cannot cancel a call (TH-2).
  - Cancelling a grind job does not reach the worker, so a fabric run and its
    LLM stream stay open (RA-5).
  - A killed grind attempt leaves a saga runner alive (CHK-6).
- **Convention.** Every runtime that calls application code passes a context
  with a cancellation signal (a `process.Selector`) and a deadline. Every
  library that starts processes for a caller stops them when the caller exits.
- **Package changes.**
  - grind: `JobContext` with `job_id`, `attempt` and `cancellation`.
  - relay: a cancellation signal in `HandlerCallContext`, and
    `client.cancel`.
  - saga: `drive` with a deadline.

### 5. Durability ownership

- **Problem.** Grind, saga and fabric each implement leases, recovery,
  retries, cancellation and codecs. No package can hold another package's id,
  so research_agent keeps a job-to-run table and its own replay sweep (RA-1).
  Other gaps compound the overlap:
  - Grind does not redeliver a job whose node died. The job becomes
    `uncertain` until an operator authorizes replay (RA-2, CHK-6).
  - `fabric.start` mints the run id, so a job cannot start a run idempotently
    (RA-3).
  - After a crash, even a read-only fabric tool suspends the run until the app
    reconciles it (RA-4).
- **Decision needed.** The [fabric design](../../fabric-design.md) assigns
  durable delivery to saga and grind. Fabric's `AGENTS.md` and its graph runtime
  now own durable graphs. The owner should record which package owns each
  durability responsibility (delivery, effect checkpoints, conversation
  state) and which ids each package accepts from the others.
- **Changes that hold under either decision.**
  - fabric: `fabric.start` accepts a caller id, as `graph.start` already does,
    and agent tools get a replay policy that mirrors `operation.with_replay`.
  - grind: an abandonment policy (`ReplayAfterLeaseExpiry(max_replays)`),
    which the grind design already specifies as Lifeline.

### 6. One JSON currency

- **Problem.** Apps bridged three codec systems for one value (EXT-5, SMCP-8,
  RA-8, CHK-7, TH-6). The bridges took 18 to 129 lines per app.
  - Grind codecs use `gleam_json` and `decode`.
  - Saga persistence codecs are string closures.
  - Blueprint codecs have no bridge to `json.Json` or `decode.Decoder`. A
    Blueprint value was stored as JSON text inside a JSON string (EXT-5).
  - http_gun's `Failure` and llm_wire's conversation types have no public
    serialized form, so a durable step error needed a 129-line codec (CHK-7).
    Fabric keeps a private 120-line envelope for llm_wire turns.
- **Convention.** `json.Json` for encoding and `decode.Decoder` for decoding
  are the shared currency. Every package codec is constructible from them.
  Blueprint, as the JSON Schema layer, converts to and from them.
- **Package changes.**
  - json_blueprint: `codec.to_json`, `codec.decoder`,
    `runtime.value_codec(contract)`, and a `use`-based record builder that
    replaces the `record2`/`record3`/`combine` arity families (EXT-6, SD-6).
  - saga: codecs over `json.Json` and `decode.Decoder`.
  - http_gun: `error.to_json` and `error.decoder` for `Failure`.
  - llm_wire: public codecs for `AssistantTurn` and `Message`.

### 7. Supervision and mounting

- **Problem.**
  - Relay's HTTP handler cannot be mounted at a route in an existing
    mist or wisp app. secure_mcp re-implemented it (114 lines) and lost
    Relay's Host/Origin checks, header checks, status mapping and SSE (SMCP-2).
  - Grind's `postgres.start` and saga have no child specification.
  - The child specifications of http_gun and warden return a handle that a
    restart replaces, so warden stores its client in `persistent_term`.
  - The name of this operation varies (`child` in http_gun and fabric,
    `supervised` in sinal, warden and grind).
- **Convention.** A package that starts processes provides
  `supervised(config) -> ChildSpecification(handle)`. The handle stays valid
  across restarts, through a name or registry. A package that serves HTTP also
  exposes its request handler for mounting in an existing router.

### 8. Test support for external parties

- **Problem.** A package that talks to an external party needs a public way to
  test against that party. Warden ships none, so secure_mcp and sso_portal
  wrote OpenID providers and a test PKI of 459 and 644 lines (SMCP-5, SSO-6).
  http_gun's playback matches requests exactly, so fabric and support_desk
  wrote loopback fake providers. Fabric copied its Erlang module between
  packages (SD-7, fabric repair). Cassettes are base64, so a reviewer cannot
  read them.
- **Convention.** Every package that talks to an external party ships a public
  `testing` module with an in-process fake of that party.
- **Package changes.**
  - warden: `warden/testing`, a scripted provider with test PKI.
  - llm_wire: a recording fake provider per built-in wire
    (`testing.events_for(provider, reply)`).
  - http_gun: request matchers for playback and a readable cassette body
    encoding.

### 9. Typed failure detail

- **Problem.** Callers branch on failures that several packages report as
  strings. Apps then mapped these strings to their own error types, at a
  cost of up to 210 lines per seam (webhooks):
  - llm_wire: `retry.assess` returns `Unknown` for every HTTP failure, and
    `OutputValidationError` holds `string.inspect` text (EXT-2, EXT-3).
  - relay: client operations return `Result(_, String)`, and a 401 arrives as
    prose (SMCP-6).
  - grind: `FailedOperationally(String)`.
  - http_gun: failure reasons have no stable name (WHK-6).
  - warden: refresh outcomes need a 40-line map to reach three decisions
    (SSO-5).
- **Convention.** A failure that a caller must distinguish is a variant, not a
  string. Every failure type has a stable name function for logs and job
  records.

### 10. Local development defaults

- **Problem.** http_gun's secure default rejects loopback and private
  addresses, which is correct. Every app needed a nested record update to reach
  a local fake. llm_wire separately admits plain HTTP only to loopback, so a
  private-network model server over plain HTTP is refused even when
  http_gun allows it (EXT-7). Each app also had to know the opt-in before its
  first request failed with `DestinationRejected`.
- **Package changes.**
  - http_gun: `config.allow_loopback(config)` and a documented
    local-development preset.
  - llm_wire: defer the plaintext rule to http_gun's destination decision.

## Per-package changes

Each list is ordered by impact. The ids point to app findings or card
concerns.

- **sinal.** Define the correlation field for theme 1. Accept a
  `decode.Decoder` in `fields.field`, and make constant event descriptors
  infallible (card concerns 1 and 2). Unify the three emission paths, so that
  http_gun needs no supervised forwarder (SD-9, TH-11, WHK-10).
- **json_blueprint.** Bridges to `json.Json` and `decode.Decoder`, and
  `runtime.value_codec` (theme 6). A record builder that replaces the arity
  families. Mark the generator-only helpers `@internal` (card concern 1).
- **http_gun.** Keep the status on limit failures (WHK-3). Per-request
  destination policy and a public policy check (WHK-4). `telemetry.id_from`.
  `Failure` codecs. A loopback helper. Playback matchers. A restart-stable
  supervised handle.
- **saga.** A step option for unknown effects from returned errors (CHK-3,
  SD-1). Ownership as a value in `Storage` (CHK-4, RA-6). A correlation and a
  durable reference in events. Codecs over gleam_json. Supervision. A
  Postgres storage package. Widen `gleam_stdlib`.
- **grind.** Fix the error-contract version defect. Accept the application's
  pog connection and support transactional submit (CHK-1, CHK-2). Add
  `JobContext` (WHK-8, RA-5). Add an abandonment and replay policy (RA-2). Add
  one worker definition without a dummy `perform` (CHK-10, EXT-8). Add
  supervision. Widen `gleam_stdlib`.
- **llm_wire.** Add `retry.advise(RunFailure)`, which needs no provider
  argument and classifies HTTP failures (EXT-2). Make `OutputValidationError`
  typed with the raw output (EXT-3). Put correlation in events. Add public
  conversation codecs. Add recording fakes per wire. Widen `gleam_stdlib`.
- **relay.** Fix HTTP cancellation (TH-1). Add a mountable handler and a
  request-aware context (SMCP-2). Make authorization values readable and
  render challenges and RFC 9728 metadata (SMCP-3). Add client headers,
  cancellation and evidence on failures (SMCP-6, TH-2, TH-4). Allow
  structured error results (TH-9). Name the tool in events. Widen `mist` and
  `gleam_stdlib`. Fix CI. Move the client onto http_gun once http_gun supports
  long-lived SSE reads (relay card).
- **warden.** Remove the exact pins (SMCP-1). Add a custody store port
  (SSO-1). Fix logout on stale revision (SSO-4). Add RFC 7009 revocation
  (SSO-2). Add a refresh operation that waits for a running refresh (SSO-3).
  Add `warden/testing` (SMCP-5, SSO-6). Add an audience and an `exp` check in
  `TokenInfo` (SMCP-4). Add correlation. Add a restart-stable supervised
  handle.
- **fabric.** Accept a caller run id in `fabric.start` (RA-3). Add a run id
  in `model.Request` (SD-3). Give agent tools a replay policy (RA-4). Add
  `agent.with_answer(schema)` for typed final answers through structured
  output (SD-4, RA-10). Make tool accessors public so that fabric tools can be
  served over relay (TH-5, TH-8). Pass the run context in the workflow bridge (SD-2).
  Replace fabric_mcp's client with relay's client (TH-5). Report usage as
  optional (TH-10). Widen `gleam_stdlib`.

## Keep

These properties composed cleanly in every app that used them. Changes should
preserve them.

- **Typed failures with submission evidence.** http_gun's `Failure` and its
  `NotSubmitted`/`MayHaveBeenSent` split mapped directly onto grind's
  `WorkerResponse` and retry policy. Grind's retry policy receives the typed
  error before it is stored.
- **Workers and steps are plain functions.** A grind worker or a saga step is
  a closure. It captures an http_gun client, a cassette playback client, or a
  fabric runtime without an adapter.
- **Caller-owned HTTP clients.** llm_wire and fabric take an `http_gun.Client`
  from the caller. A correlation view of that client passes through.
- **One schema source for tools.** One Blueprint codec produced the same JSON
  Schema in Relay's listing, in fabric's tool and in the llm_wire request
  (tool_hub). Structured output ran unchanged on OpenAI, Anthropic and Google,
  with 1 to 6 lines of provider-specific settings (extractor).
- **Saga compensation and the storage conformance suite.** The suite caught
  ownership mistakes in two independent Postgres adapters.
- **Fabric's approval gate and its `Explain`/`Uncertain` split.** Approval
  suspends a run as data. The split expresses an outcome that MCP itself
  cannot express.
- **Destination policy as SSRF protection.** http_gun checks every resolved
  address, including after DNS rebinding.
- **Sinal's typed descriptors.** Events from four packages attached the same
  way in one app.
- **Warden's framework-neutral login.** Login and callback fit a wisp router
  in about 14 lines of string glue. The refresh reservation sent exactly one
  refresh grant under concurrency.
- **Ecosystem fit.** wisp, mist and pog needed no special handling once the
  dependency ranges resolved.

## Suggested order

1. **Hygiene.** The [Fix first](#fix-first) changes landed on 2 October 2026
   (see [Fix round results](#fix-round-results-2-october-2026)). Still open:
   add the `SIBLINGS_READ_TOKEN` secret for relay and saga CI, and refresh the
   stale design statements that the scans found. For example, `sinal-design.md` still
   calls the native adapter pending, and `llm-design.md` mentions the removed
   `provider.Replay`.
2. **Conventions.** Record themes 1, 2, 4, 6, 7, 8 and 9 in the
   [public API guidelines](../../PUBLIC-API-GUIDELINES.md). Then apply them
   package by package. Correlation (theme 1) and the JSON currency (theme 6)
   remove the most glue across apps.
3. **Design decisions.** Decide durability ownership (theme 5) and the
   outcome-evidence names (theme 3). Decide whether warden gains a
   resource-server role or relay verifies tokens with another library
   (SMCP-4). Decide where the Relay ↔ fabric tool adapter lives (TH-5).
4. **Re-run the apps.** Each app is an executable baseline. After a package
   change, re-run the affected apps, delete the glue that the change made
   unnecessary, and record the reduction in the app's `FEEDBACK.md`.
