# Release decisions

The [release API review](README.md) left five decisions that block the most
work. Each section states the context, the options with their trade-offs, and
a recommendation.

| Decision                | Status                                                                                                                                                                                                |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1. Durability ownership | Deferred. Option B (the graph runtime leaves fabric) is ruled out by decision 2.                                                                                                                      |
| 2. Graph runtime in 1.0 | Decided (3 October 2026): the graph runtime stays in fabric and ships in fabric 1.0, under the same semver promise. FABRIC-R5 (one vocabulary) and the graph parts of R4, R7 and R15 must land first. |
| 3. Correlation shape    | Accepted: opaque string up to 128 bytes, W3C trace id valid, `causation` deferred.                                                                                                                    |
| 4. Definition bugs      | Accepted: panic for source definitions; typed errors and `check` for runtime definitions.                                                                                                             |
| 5. Default numbers      | Accepted: the table in section 5. Approval and graph waits default to 7 days for new runs; records stored without a deadline keep none (3 October 2026).                                              |

Package decisions taken with these (3 October 2026):

- **fabric reviewer:** a typed caller identity, not a string. An answer to an approval names its reviewer with a fabric `Reviewer` value, built by the application from an authenticated identity.
- **fabric approval expiry:** 7 days by default (decision 5). An expired approval rejects the action, and the model sees the rejection. The default is configurable, with an explicit `Infinity`.

## 1. Durability ownership

**Context.** Three packages implement durable execution:

- **grind** delivers jobs at least once, with leases, claims and retries in
  PostgreSQL.
- **saga** runs workflows with compensation, effect checkpoints and a durable
  runner over a `Storage` port.
- **fabric** keeps agent conversation state, plus a durable graph runtime with
  compare-and-set records, leases, a sweeper, signals, job polling and forks.

In research_agent, one request ran under three leases, three recoveries and
three cancel commands. The app joined them with a job-to-run table (115 lines),
a replay sweep (38 lines), tool reconciliation (77 lines) and a cancellation
fan-out (37 lines). The fabric design assigns durable graphs to saga, but
fabric's code now owns them.

| Option                                                                                                                                                                     | Gains                                                                                                                                                                                   | Costs                                                                                                                                                                                                                                                           |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **A. Keep today's split.** Fabric owns conversation and graph state. Add a `fabric_grind` integration, and record the decision in the design.                              | Least work; the code exists and passes 885 tests; fastest release.                                                                                                                      | Two durable graph runtimes (saga and fabric's graph) with overlapping concepts. A newcomer must choose between them. Fabric 1.0 commits to both runtimes and both vocabularies.                                                                                 |
| **B. Fabric owns the agent loop and its conversation state.** The graph runtime moves to a separate `fabric_graph` package at 0.x and may later converge on saga's runner. | Each package has one stated job: grind delivers, saga runs effects with compensation, fabric runs agents. Fabric 1.0 shrinks to about 15 modules and 112 functions. Matches the design. | Graph users migrate. No external users exist, because nothing is released. Saga lacks subgraphs, forks, signals and job polling, so convergence is later work. Until then `fabric_graph` is a third runtime, isolated at 0.x.                                   |
| **C. A shared durability layer** (store, lease, sweeper, ids) that grind, saga and fabric build on.                                                                        | One model of leases and recovery across the ecosystem.                                                                                                                                  | The largest change, and it delays every release. The leases differ: a grind claim uses `SKIP LOCKED` over a queue, a saga claim owns one execution, a fabric record uses compare-and-set. The guidelines forbid sharing an abstraction whose invariants differ. |

**Recommendation: B.** State the ownership in each design:

- grind delivers work;
- saga runs effectful workflows;
- fabric runs agents.

Make the connecting points first-class, because they remove the research_agent
glue under any option:

- callers supply run ids (fabric R2);
- a grind `JobContext` carries cancellation and an abandonment policy (grind R4,
  R7);
- every package carries the correlation field.

When a grind job drives an agent run, the job is the driver and fabric's
sweeper stays off for that run. Revisit C after 1.0, if the three
implementations then show the same invariants.

## 2. Fabric's graph runtime in 1.0

**Context.** The graph runtime is 9 of fabric's 23 modules and about 50 of its
functions. It uses a different vocabulary from the agent runtime for failures,
policy, approval, cancel, context and run ids (fabric R5). Gleam versions a
package as a whole. Every public module in fabric 1.0 is therefore under the
same semver promise; a module cannot be marked experimental.

| Option                                                                       | Gains                                                                                                                 | Costs                                                                                                                                        |
| ---------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| **Ship it in fabric 1.0.**                                                   | One dependency; graph users get stability now.                                                                        | R5 (one vocabulary) must be finished before release. Any later change to the graph API is a fabric major release.                            |
| **Ship it as `fabric_graph` 0.x**, depending on fabric for the shared types. | The agent API stabilizes first. The graph API can still change freely. The fabric 1.0 surface is about 112 functions. | One more package. Graph users add a dependency. The failure, policy and approval types must live in fabric core so both packages share them. |
| **Keep it in fabric, documented as unstable.**                               | No package split.                                                                                                     | The semver promise still covers it. Breaking it in a minor release violates semver, and holding it stable is the first option.               |

**Outcome.** The owner chose the first option: ship it in fabric 1.0.

**Recommendation at the time: `fabric_graph` at 0.x**, consistent with decision 1. Do the
vocabulary work of fabric R5 in fabric core first: one `tool.Failure`, one
`policy.Action`, one approval and cancel shape, and `fn(RunId) -> context`.
The graph package then reuses those types, and moving it later costs only an
import change.

## 3. Correlation shape

**Context.** No app could follow one request across packages without join
tables or attributing events by process (8 findings in 8 apps). Sinal is the
one dependency every emitter shares. The proposal adds `sinal/correlation`,
whose value every package carries as the `correlation` field of its event
metadata. Each package accepts the value where work starts and passes it to the
packages it calls.

| Option                                                                                                                                                     | Gains                                                                                                                                                                                   | Costs                                                                                                                                                                                      |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Opaque string of at most 128 bytes.** `from_string`, `unique` (128 random bits, hex), `to_string`.                                                       | Any app id works directly: an order id, a job id or a request id, so the app needs no join tables. Readable in logs. One concept. No tracing dependency.                                | No parent and child structure. An OpenTelemetry exporter must map the value to a trace.                                                                                                    |
| **W3C `traceparent`** (16-byte trace id, 8-byte span id, flags).                                                                                           | Standard; an OpenTelemetry adapter reads it directly, and it propagates over HTTP.                                                                                                      | The app id cannot be the key, so apps keep a join table. Every package must create child spans across processes, which is a large change. Newcomers learn span semantics to use a log key. |
| **Both:** the opaque string now, with a documented rule that a W3C trace id (32 hex characters) is a valid value, and an optional `causation` field later. | Simple now. Compatible with tracing: an adapter sets correlation to the trace id. A parent field can be added without breaking callers, because callers read metadata records by label. | Two steps instead of one. Parent and child links wait until a tracing adapter needs them.                                                                                                  |

**Recommendation: the third option.** Ship the opaque string and the
propagation rule in every package now, and defer `causation` until an
OpenTelemetry adapter exists. Outbound `traceparent` headers in http_gun are a
separate feature and are not required for correlation.

## 4. Definition bugs: typed error or panic

**Context.** Some constructors take definitions written in source code: sinal
event names and field keys, and json_blueprint properties, tags, enums and
bounds. They return `Result` only to reject cases such as a duplicate key, so
the sibling packages contain about 100 `let assert` sites that turn the
`Result` into a crash anyway.

| Option                                                                                                                                                                                       | Gains                                                                                                                                                                                                                      | Costs                                                                                                                                                                                                                                |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Keep `Result`.**                                                                                                                                                                           | Explicit; nothing panics inside the library.                                                                                                                                                                               | Every call site asserts. The common path stays noisy. The crash message is a generic `let assert` failure, not the offending key.                                                                                                    |
| **Panic at construction** with a message naming the definition and key. A separate fallible constructor (`check`, `from_*`) serves definitions built from runtime data.                      | Call sites are total, which removes the ~100 asserts. The behavior matches what callers already do, with a better message. Gleam reserves panic for programmer errors, and any test that builds the definition catches it. | The library panics. A definition built lazily on a rare path fails late. Runtime-built definitions need the second constructor.                                                                                                      |
| **Deferred typed error.** The constructor returns the value with the error inside; it surfaces as `InvalidDefinition` at first use (`schema`, `encode`, `decode`), and `check` serves tests. | Call sites are total and nothing panics. json_blueprint's `encode` and `decode` already return `Result`.                                                                                                                   | A source bug looks like a data error at run time and may be logged and retried instead of fixed. Sinal's `emit` returns `Nil`, so it has no channel for the error. Every use site handles an error that correct code never produces. |

**Recommendation: panic for source definitions, typed errors for runtime
definitions.** This rule works for both packages. A sinal event or a Blueprint
codec written in code panics at construction with the key in the message.
`check` and `contract.from_schema` return a typed `DefinitionError` for
definitions built from runtime data, such as enums loaded from a database or
schemas from a remote server. The json_blueprint review preferred the deferred
error. Its main argument, that `encode` and `decode` already return `Result`,
does not carry over to sinal. That review also accepts panic as its
alternative.

## 5. Default numbers

**Principle.** A default must never stop a normal workload. It must bound a
pathological one, and the error must name the limit and the setter that raises
it. An unbounded value must be requested explicitly (`Infinity` or `Never`).

**Coupled limits.** The defaults of llm_wire, http_gun and fabric nest: a
fabric model call runs an llm_wire call over an http_gun request. Today
http_gun's 30 s client default silently cuts llm_wire's 60 s deadline to 30 s.
Decision D5 of the review lets a request carry its own deadline. Each layer then
sets its own limit, and an inner default never cuts an outer one.

| Package        | Operation                                | Today                        | Recommended                                      | Reason                                                                                                                        |
| -------------- | ---------------------------------------- | ---------------------------- | ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| http_gun       | connect, including DNS                   | 5 s (DNS unbounded)          | 5 s                                              | Covers DNS too.                                                                                                               |
| http_gun       | pool checkout                            | inside the request deadline  | 5 s                                              | A saturated pool fails fast, separately from a slow server.                                                                   |
| http_gun       | request (head and body)                  | 30 s                         | 30 s; a request may set its own                  | Ordinary APIs. Streams set their own.                                                                                         |
| http_gun       | idle read (no bytes)                     | none                         | 30 s                                             | Detects a dead stream. llm_wire sets its own idle gap.                                                                        |
| http_gun       | idle pooled connection                   | none                         | 60 s                                             | Releases sockets that servers would close anyway.                                                                             |
| llm_wire       | whole call                               | 60 s, 30 s in effect         | 600 s                                            | Long outputs and reasoning models.                                                                                            |
| llm_wire       | first token                              | 15 s idle timer              | 180 s                                            | Reasoning models think before emitting anything.                                                                              |
| llm_wire       | idle gap between events                  | 15 s                         | 60 s, reset by tool-argument deltas and pings    | Detects a stalled stream without cutting slow tool arguments.                                                                 |
| llm_wire       | SSE line                                 | 16 KiB                       | 1 MiB (equal to the event limit)                 | 16 KiB fails OpenAI replies above about 16 KB.                                                                                |
| fabric         | model call                               | none for custom models       | 600 s, matching llm_wire's whole call            | The fabric review proposed 120 s. That would cut reasoning models that llm_wire allows, so 600 s keeps the layers consistent. |
| fabric         | agent tool body                          | none                         | 60 s; expiry is `Uncertain`                      | Same as graph operations. A tool that may have acted reports an unknown effect.                                               |
| fabric         | approval and graph waits                 | none                         | 7 days; an expired approval rejects the action   | Human-scale waits; the model sees the rejection.                                                                              |
| fabric         | tool result size                         | none                         | 1 MiB                                            | A result is stored and resent every turn.                                                                                     |
| fabric         | token budget                             | none                         | opt-in                                           | A default would stop every model that reports no usage.                                                                       |
| grind          | handler execution                        | none; lease renewed forever  | 15 min                                           | Generous for jobs; long jobs set it. Oban's default is unbounded, which this ecosystem's rule rejects.                        |
| grind          | snoozes per job                          | unbounded                    | 100, then `SnoozeLimitReached`                   | Stops a receiver that always answers 429 from snoozing a job forever (webhooks).                                              |
| grind          | job retention                            | forever unless a pruner runs | pruner on, 7 days                                | Bounded table growth with a week of visibility. `without_pruner` keeps everything.                                            |
| grind          | payload size                             | unbounded                    | 1 MiB                                            | Jobs carry references, not documents.                                                                                         |
| grind          | initial connect                          | unbounded                    | 15 s                                             | `start` fails with a typed error instead of hanging.                                                                          |
| grind          | retries                                  | 20, 15 s doubling, no jitter | keep, add jitter                                 | Matches Oban; jitter avoids synchronized retries.                                                                             |
| saga           | `durable.drive`                          | waits forever                | required `timeout:` argument                     | The caller states how long it waits; the runner stops and keeps the checkpoint.                                               |
| saga           | storage call                             | unbounded                    | 5 s                                              | A stuck store suspends the run instead of hanging it.                                                                         |
| saga           | checkpoint size                          | unbounded                    | 16 MiB                                           | Every commit rewrites the snapshot.                                                                                           |
| json_blueprint | parse input                              | 10 MiB (memory unbounded)    | 1 MiB, depth 64                                  | 10 MiB of input produced a 915 MB heap peak.                                                                                  |
| relay          | concurrent HTTP requests                 | none                         | 1,024, then 503                                  | Bounds processes per listener.                                                                                                |
| relay          | concurrent `listen` streams              | none                         | 64, then 503                                     | Long-lived streams hold resources.                                                                                            |
| relay          | SSE keepalive                            | 250 ms                       | 15 s                                             | 250 ms wastes bandwidth; proxies need only tens of seconds.                                                                   |
| relay          | non-loopback listener without protection | starts unauthenticated       | `start` fails; `allow_unauthenticated()` opts in | Fail closed. This breaks anyone binding `0.0.0.0` without auth, deliberately.                                                 |
| warden         | refresh race loser                       | fails at once, app polls     | waits up to 5 s for the running refresh          | Removes polling (SSO-3).                                                                                                      |
| warden         | refresh margin before expiry             | none                         | 30 s                                             | Refreshes before a token expires mid-request.                                                                                 |
| warden         | `complete_login`                         | about 34 s worst case        | 30 s total                                       | One documented bound.                                                                                                         |
| warden         | sessions per identity                    | unbounded (decision D14)     | keep unbounded; document                         | A cap evicts sessions, which is a product policy, not a library default.                                                      |
| sinal          | forwarder capacity                       | required argument            | 1,024                                            | Matches the forwarder's existing drop accounting.                                                                             |

**Recommendation: adopt the table.** Two values differ from the package
reviews: fabric's model call (600 s, not 120 s) and warden's session cap
(documented, not imposed). Each README lists its defaults with the setter that
changes each one.
