# Workflow runtime boundaries

## Status

- The later [composition exploration](composition-contracts.md) refines this note's initial separation: local Saga execution and Grind queue execution remain distinct, while typed workflow authoring and compensation semantics can be shared through an explicit durable Saga/Grind runner. Use that proposal for shared authoring and nested-node contracts; the source findings below remain the evidence baseline.
- This note records a research recommendation for type-only exploration rather than a package decision.
- The source and test trees cited below were inspected at their named tags, but their upstream suites were not run locally.
- Feature documentation establishes an intended contract, while source and tests establish only the cases that upstream chose to exercise.

## Decision

- Grind and Saga should remain independent engines because durable job dispatch and in-memory dependency execution have different persistence, cancellation, and recovery contracts.
- Grind should be a native Gleam job engine with eventual Oban parity, because an Oban wrapper would preserve Oban's dynamic worker boundary and import its Elixir, Ecto, and configuration model.
- Saga should be a native Gleam plan engine, because its principal value is the statically typed `Plan(value, error, undo_error)` contract that a Reactor FFI boundary cannot preserve by itself.
- Fabric should compose those engines without claiming that Grind can resume an arbitrary Saga plan, because a queued job can carry a continuation reference but cannot serialize Saga closures or reconstruct running branches.
- Fabric should define a versioned continuation-store contract for its first durable approval slice, while it defers a general `durable_run` engine until a concrete flow requires resumable branch state.
- `bg_jobs`, Reactor, Oban, and `gabsurd` should serve as pinned behavior oracles and prototype comparators rather than hidden production foundations.

## Runtime ownership

- Grind owns durable admission, scheduled availability, queue capacity, claims, leases, attempt history, retry time, terminal job state, and recovery after process or node loss.
- Saga owns dependency readiness, bounded in-run concurrency, step retry, compensation of a failing step, undo of completed steps, and aggregation of undo failures.
- Fabric owns agent-turn state, model and tool transcripts, review revisions, approval identity, and compatibility of any persisted continuation format.
- A Fabric operation may enqueue a Grind job that starts or resumes one named continuation, but Fabric must reload its own state and build a fresh Saga plan after every durable boundary.
- A Saga step may enqueue a Grind job only as an explicit external effect, because silently making every Saga node a job would replace typed in-memory values with a distributed serialization protocol.
- Grind cancellation records durable intent and prevents a new claim, while a running worker observes that intent cooperatively through a cancellation token or heartbeat.
- Saga cancellation stops admission of ready steps, signals running branches, and applies the plan's declared rollback policy after those branches settle.
- Fabric cancellation resolves pending model, tool, and review work at an agent boundary, while it delegates active job interruption to Grind and active plan rollback to Saga.
- Saga alone owns compensation and undo, because compensating business effects requires the typed values and completion order that a queue does not possess.
- Grind checkpoints job attempts and leases, while Fabric stores every durable approval as a versioned continuation whose update atomically compares the expected revision and rejects stale replies.
- Sinal transports observations, while Grind, Saga, and Fabric each originate lifecycle facts for the state transitions they own.
- Automatic retry must occur at one declared layer for each effect, because combining provider retry, Saga retry, and Grind retry can multiply an external call after partial success.

## Reuse assessment

- Oban `v2.24.1` is the primary Grind oracle because its Apache-2.0 source and public test tree cover the open-source queue contract at an exact tag ([package](https://hex.pm/packages/oban/2.24.1), [source and tests](https://github.com/oban-bg/oban/tree/v2.24.1)).
- Oban Pro is a separately licensed product whose public documentation describes global and rate limits, workflows, batches, chunks, relay, and recording, but its implementation and internal tests are not a public oracle ([terms](https://getoban.pro/terms), [features](https://getoban.pro/)).
- Grind may retain full Pro-equivalent product goals, but each such behavior needs an original black-box contract from public documentation or licensed oracle access before the design claims parity.
- `bg_jobs` `v0.5.2` is an Apache-2.0 Gleam implementation with PostgreSQL and SQLite adapters, queue actors, delayed jobs, schedules, listeners, and tests ([package](https://hex.pm/packages/bg_jobs/0.5.2), [tag](https://github.com/MaxHill/bg_jobs/tree/v0.5.2), [tests](https://github.com/MaxHill/bg_jobs/tree/v0.5.2/test)).
- Its README still lists periodic release of abandoned jobs as pre-1.0 work because a missed process monitor can strand a job, so its recovery model does not yet supply Grind's required fault contract ([README](https://github.com/MaxHill/bg_jobs/blob/v0.5.2/README.md)).
- Grind should reuse `bg_jobs` patterns selectively under its license, especially database adapters and actor tests, but should not wrap its schema because adding Oban uniqueness, limits, workflows, and migrations would bind Grind to an incomplete state model.
- Reactor `v1.0.6` is the Saga oracle because its MIT source and test tree exercise asynchronous dependency scheduling, retry, compensation, undo, and halt/resume of an in-memory reactor ([package](https://hex.pm/packages/reactor/1.0.6), [source and tests](https://github.com/ash-project/reactor/tree/v1.0.6), [step contract](https://reactor.hexdocs.pm/Reactor.Step.html)).
- Reactor stores named intermediate results dynamically and crosses Elixir callback boundaries, so wrapping it would still require a second typed representation to implement Saga's compile-time result and error guarantees.
- Reactor can return an incomplete reactor after a controlled halt, but its documented halt is not a persistent checkpoint that survives node loss ([runtime contract](https://reactor.hexdocs.pm/Reactor.html), [architecture](https://reactor.hexdocs.pm/architecture.html)).
- `gabsurd` `v0.2.0` is an Apache-2.0 Gleam SDK around an embedded Absurd PostgreSQL schema rather than a self-contained workflow engine ([package](https://hex.pm/packages/gabsurd/0.2.0), [tag](https://github.com/kasuboski/gabsurd/tree/v0.2.0), [tests](https://github.com/kasuboski/gabsurd/tree/v0.2.0/test)).
- Its operation requires installing both Absurd and extension SQL, maintaining generated Parrot queries, running PostgreSQL queue tables, and operating polling workers with leases and heartbeats.
- Its named steps persist JSON checkpoints, whole-task retries skip completed steps, awaited events suspend a task, and cancellation becomes visible at a later checkpoint or heartbeat.
- Its event value is a first-write cached value rather than an append-only lifecycle stream, and its step model does not provide Saga compensation, typed fan-in, or Fabric review revisions.
- Its checkpoint decoder asserts successful JSON parsing, so incompatible persisted data can crash restore instead of returning a typed migration error ([context source](https://github.com/kasuboski/gabsurd/blob/v0.2.0/src/gabsurd/context.gleam)).
- Its vendored Absurd schema reports version `main`, so the package tag does not identify an upstream Absurd schema revision suitable for a production migration contract ([vendored schema](https://github.com/kasuboski/gabsurd/blob/v0.2.0/priv/absurd.sql), [current Absurd repository](https://github.com/earendil-works/absurd)).
- `gabsurd` should therefore remain a black-box experiment for checkpoint, event-wait, and cooperative cancellation behavior until its schema provenance and migration policy become pin-able.

## Exploration slices

- The first Grind prototype should define worker identity, versioned argument codecs, job states, attempt outcomes, retry decisions, cancellation intent, and lifecycle events as pure types and transition functions.
- The first Saga prototype should define typed plan nodes, `map`, `and_then`, `zip`, effect declarations, retry policy, compensation outcome, and undo-error accumulation without OTP processes or persistence.
- The first Fabric prototype should type-check an agent turn that uses a Saga plan, a Fabric-owned continuation-store contract, and a durable invocation that stores only the continuation reference in a Grind job.
- That Fabric prototype should make restart reconstruct a new plan from versioned Fabric state, rather than pretend that a closure-bearing Saga value is serializable.
- The first behavioral Grind slice should implement PostgreSQL enqueue, claim, lease renewal, completion, failure, delayed retry, cancellation, and abandoned-claim recovery before uniqueness or advanced scheduling.
- The first behavioral Saga slice should implement dependency scheduling, bounded parallel `zip`, step retry, compensation, reverse-completion undo, cancellation, and undo-failure reporting in one BEAM node.
- The first durable Fabric slice should persist one approval pause and resume by atomic compare-and-set, reject a stale revision, and pass a stable idempotency or fencing key to a tool that honors it.
- Fabric may promise that a tool effect is applied no more than once only when the downstream system honors that key or when the effect and completion record share an atomic transaction.
- A worker loss after any other tool effect leaves execution ambiguous, so Fabric must expose that outcome for consumer reconciliation instead of promising duplicate prevention.
- Grind should then expand through the public Oban contract before adding original Pro-equivalent limits, workflow composition, batches, chunks, relay, and recording.
- Saga's runtime-schema graph for visual construction should follow the native plan engine as a distinct surface, because finite JSON port schemas and `TypedValue` have different guarantees from closure-based plans.
- Fabric should require atomic review-revision comparison from the first persisted approval, while it defers historical forks until a consumer demonstrates that the linear continuation record cannot express the required interaction.

## Minimum consumer proofs

- Grind must prove exclusive claims under competing workers, lease expiry after process death, retry timing, cancel-versus-complete races, graceful shutdown, abandoned-job rescue, codec-version rejection, and one lifecycle fact per committed transition.
- Grind must expose at-least-once execution explicitly by proving the crash window between an external effect and completion acknowledgement.
- Saga must prove one execution per dependency, concurrency bounds, typed failure mapping, the distinction between compensation and undo, reverse completion order, accumulated undo failures, and cancellation while sibling branches are active.
- Fabric must prove continuation migration failure as data, atomic approval application, stale-revision rejection, and correct classification of a post-effect worker loss as prevented, committed, or ambiguous according to the downstream guarantee.
- Differential prototypes should run equivalent public scenarios against the named Oban and Reactor tags, while `bg_jobs` and `gabsurd` tests should be treated as upstream examples until their suites pass in this repository's toolchain and PostgreSQL environment.

## Irreversible boundaries

- A production database schema, worker identity format, codec version, checkpoint name, event identity, and migration order become compatibility promises as soon as consumers persist them.
- An at-least-once execution promise constrains every tool and business effect, so the downstream idempotency, fencing, transaction, or reconciliation owner must be explicit before the first durable integration.
- A direct dependency on Oban, Reactor, `bg_jobs`, or `gabsurd` imports its runtime state and upgrade path, so FFI experiments must not write production data.
- Proprietary Oban Pro behavior cannot become an oracle corpus without license rights and a pinned version.

## Evidence that would change the decision

- Grind should adopt or fork `bg_jobs` only if its tagged implementation passes the Grind fault suite and can add the required state transitions without a persistent-schema rewrite.
- Saga should consider a Reactor backend only if a native scheduler cannot meet the cancellation, rollback-order, and resource-bound contracts, and a single adapter can contain every dynamic value.
- Fabric should consider `gabsurd` only after an exact Absurd schema revision, forward migrations, typed checkpoint decode failures, and the required revision semantics are demonstrated in executable tests.
- Fabric should introduce a separate durable execution engine only when a real workflow requires resumable branch state that cannot be reconstructed from a Fabric continuation and cannot be represented as Grind jobs whose effects have an explicit idempotency, fencing, transaction, or reconciliation contract.
