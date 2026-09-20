# Wave 3 work order: production-facade convergence

Run the two repository scopes independently. This is a large convergence wave,
not a one-test checkpoint. Work in coherent red-green increments and continue
until the required milestone is reviewable. Do not weaken tests or silently
shrink the design to meet a wave count.

The release target is the initial production facade in [`PUBLIC-API.md`](../../../PUBLIC-API.md).
Retained later capabilities remain explicit backlog: Blueprint source generation,
recursive references and broader schema families are not deleted by their
exclusion from this release. The package designs remain authoritative when this
handoff summarizes them.

## Common start and execution contract

1. Confirm the repository, clean status, branch, and exact baseline below. Read
   this work order, [`review-2.md`](review-2.md), the package design,
   `PUBLIC-API.md`, relevant `API-COVERAGE.md` rows, and current source/tests.
2. Probe the configured Gleam LSP against a real source file using the absolute
   executable `/etc/profiles/per-user/edgar/bin/agent-lsp`. Avoid shell wrappers
   whose banner text can corrupt MCP framing. Record the exact success or failure
   and compiler fallback in `test/oracle/wave-3-capabilities.md`.
3. The verified tools include `search_web` and `read_url_content`. Invoke each once for
   a small official-oracle check and distinguish search from URL reading in the
   capability record. Confirm oversight-file access there too. Do not expose
   secrets or dump tool/environment configuration.
4. Preserve public-contract TDD and durable oracle provenance. Tests must fail
   for the intended behavior before the smallest coherent implementation makes
   them pass. No skips, masked reds, forged opaque values, or fake defaults.
5. Adapt slice size to implementation dependencies and evidence. Report work
   completed, work deferred, and why. Do not broaden or rewrite the design. A
   material mismatch stops that part for review without blocking independent
   work.
6. Reuse unchanged accepted evidence. Run focused and changed-package gates;
   avoid repetitive full oversight gates. Await every command and child process.
   Do not return while background work is running.
7. Do not commit, push, publish, install tools, or modify the oversight repo.
   Stop with a formatted working tree for Sol Medium review.

## Sinal: feature-complete production candidate

**Repository:** `/code/gleam-dream/sinal`

**Branch and baseline:** `master` at
`0204cc7088266e97eb76f77c1b1fb8ef96d5cdb4`

Close the Wave 2 evidence gaps first, before spans or other expansion:

- Prove exact original error, exit, and throw class/reason/stacktrace fidelity in
  scoped work. Repeat original-exception assertions when detach returns an error
  and when the cleanup reporter raises; the reporter must not replace the work
  exception.
- Decode and assert the full native `[telemetry, handler, failure]` payload:
  measurements/times plus metadata event name, raw handler identity,
  configuration, exception class, reason, and stacktrace. Cover adapter-raised
  typed decode/handler failures and the original unexpected callback exception.
- Attach one identity to at least two events, fail one invocation, and prove
  later emission of every registered event cannot invoke it. Correct the oracle
  provenance claim.
- Correct the Wave 2 capability record by probing the absolute LSP path above.

Then complete the initial facade and native acceptance contract in
[`sinal-design.md`](../../../sinal-design.md):

- Implement scoped attachment lifetime for ordinary return, returned cleanup
  error, work error/exit/throw, reporter failure, nested private identities,
  already-removed handlers, and attach refusal. Preserve work values separately
  from cleanup outcomes. State the documented non-quiescence and uncatchable
  termination limits.
- Implement native span descriptor derivation and `run_span` through
  `telemetry:span/3`: native time units, owned-field collision rejection,
  context equality within one invocation and difference across invocations,
  independent stop metadata, ordinary business `Result.Error` as stop, exact
  error/exit/throw re-raise, one exception event, and nested event order. Do not
  invent trace parentage.
- Complete differential native-boundary and concurrency evidence: raw telemetry
  handlers over Sinal emissions and Sinal handlers over raw maps; unknown fields,
  malformed maps and native terms; caller PID and slow synchronous handler;
  concurrent emitters; overlapping subscriptions; selection already in flight
  during detach; behavior around `telemetry:persist/0`; and unspecified handler
  order. Test declared limits instead of promising linearity or quiescence.
- Update package/oracle documentation so supported behavior, failure-event
  configuration exposure, known registry races, and remaining adapter-owned
  export/buffering concerns are accurate.

Acceptance target: no production-path todo in the initial Sinal facade; native
oracle tests are meaningful and deterministic; format, check, unit/focused tests,
relevant fault/concurrency tests, and `git diff --check` pass. This should leave
integration/compatibility and then hardening/release work for Waves 4 and 5.

## JSON Blueprint: complete initial facade

**Repository:** `/code/gleam-dream/json_blueprint`

**Branch and baseline:** `implementation/schema-aware-core` at
`fc8dae8d1c4eabf97d7ae8d4fa201cdc24f6b289`

Build the complete current facade in [`blueprint-design.md`](../../../blueprint-design.md)
end to end, while preserving the legacy API and its 21 JavaScript tests:

- Finish `Value`, including duplicate-preserving object input and checked
  duplicate-key rejection, with one exact `Number` leaf.
- Implement codec construction, encode/decode/schema, `imap`, primitives,
  exact pairs and lists, nullable versus optional, typed object properties,
  closed objects/fields, finite string enums, tagged alternatives, inclusive
  integer and exact-number bounds, and Draft 2020-12 schema rendering. Preserve
  structured located errors and `UnknownSchema` propagation.
- Implement normalized finite `RuntimeContract`, `ValidatedValue`, exact
  structural matching, validation, retained-codec native decode, and strict
  loading from an already-parsed `Value`. Reject unsupported keywords,
  references, dialects, and forms explicitly; distinguish malformed supported
  syntax from unsupported capability without dropping constraints.
- Exercise codec roundtrip/schema laws, duplicate and location behavior, and the
  independent 61-case Draft 2020-12 corpus directly against package behavior.
  Strengthen the accepted 62-case number evidence where integration touches
  `Value`, bounds, validation, or rendering; keep wire acceptance distinct from
  native projection.
- Preserve all existing 1.7.1 Erlang/JavaScript behavior and pinned 1.1.0/1.7.1
  comparator evidence. Ordinary Gleam JSON users must not depend on Blueprint,
  and no universal codec package is introduced.

Create a durable capability inventory covering JavaScript parity, whole-document
byte parsing and its duplicate-key/UTF-8/number/size/depth/location policy,
legacy migration, recursive references, broader constraints/unions, hostile
input/performance, consumer-owned provider admission, and source generation.
Classify each as implemented, Wave 4 integration/compatibility, Wave 5 release
hardening, or a retained post-release family with its evidence/revisit trigger.
Do not claim unsupported behavior.

Pure facade behavior should work on both targets where it does not depend on the
Erlang-first Number kernel. JavaScript Number paths may remain named todos in
this wave, but must be explicit and included in the Wave 4 release decision.
Do not detour into source generation, recursive schemas, a broad byte parser, or
the whole JSON Schema language during this wave.

Acceptance target: the current finite codec/schema/runtime/document facade has
no production-path todo on its supported target; legacy and new tests, both
target checks, formatting, relevant compatibility/differential oracles, and
`git diff --check` pass. Unsupported forms fail explicitly. Wave 4 should be
cross-target/parser/migration and consumer-compatibility closure, not unfinished
core facade implementation.

## Convergence after this wave

- **Wave 4 — integration and compatibility:** Sinal completes upstream/raw-BEAM
  interoperability and selected package-observation compatibility without
  absorbing exporter policy. Blueprint resolves advertised JavaScript parity,
  whole-document parser/reuse policy, legacy migration, and the Relay/Fabric/LLM
  schema-consumer profiles selected for the initial release.
- **Wave 5 — hardening and release:** fault/stress and hostile-input suites,
  benchmarks with stated methodology, documentation, packaging, upgrade/release
  checks, and removal or explicit disposition of every release-blocking todo.
- Compress Waves 4 and 5 when all named evidence is already green. Add work
  beyond Wave 5 only for a concrete blocker. Only capabilities explicitly
  deferred by the package design may remain post-release backlog.
- **Retained post-release families:** Blueprint recursive references, broader
  schema/constraint/union families, stable source-generation tooling and wider
  generation profiles. They stay in the design backlog and require their own
  consumer/oracle before promotion; they are not implicit initial-release work.

## Required final report

Return repository/branch/starting HEAD, changed files, capability record,
implemented behaviors, remaining todos, red-green evidence, oracle provenance
and counts, exact gate results, deliberate deferrals, design divergence, and
confirmation of no commit/push/publication. Include friction encountered and
separate concrete improvements actually made from proposals for later work.
Acceptance belongs to the subsequent Sol Medium review.
