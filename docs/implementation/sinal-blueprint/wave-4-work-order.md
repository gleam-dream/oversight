# Wave 4 work order: initial release completion

Run the repositories independently and continue through coherent red-green
increments to a substantial release-ready result. This wave combines integration,
compatibility, and hardening where the evidence fits. Wave 5 exists only for
concrete blockers found here; it is not a default cleanup phase.

The target is the approved initial production facade in [`PUBLIC-API.md`](../../../PUBLIC-API.md)
and each package design. Only capabilities explicitly deferred there may remain
post-release. Blueprint source generation, recursive references, and broader
schema families stay visible as retained future work; they are outside this
initial release rather than silently removed.

## Common execution contract

1. Confirm the named clean branch and baseline. Read this work order, the final
   [`review-3.md`](review-3.md), the package design, `PUBLIC-API.md`, relevant
   `API-COVERAGE.md` rows, and current sources/tests. Resolve every applicable
   review finding before expanding scope.
2. Probe the configured Gleam LSP on a real changed source file with the absolute
   `/etc/profiles/per-user/edgar/bin/agent-lsp`. Invoke it directly; shell or Nix
   banners on stdout can corrupt MCP framing. Record the result and fallback in
   `test/oracle/wave-4-capabilities.md`. `search_web` and `read_url_content` were
   already proven in Wave 3; cite that evidence and use them again only for a
   source needed by this implementation.
3. Use public-contract TDD and durable provenance. Preserve focused reds before
   green. Do not skip, mask, weaken, or replace a behavior with a fake default.
   Adapt chunk size to dependencies, but do not broaden or rewrite the design.
4. Reuse unchanged oracle evidence. Run focused and changed-package gates, not
   repetitive full oversight suites. Await every command and child process; do
   not return while background work is running.
5. Do not commit, push, publish, install tools, access secrets, modify oversight,
   or overwrite unrelated changes. Stop with a formatted working tree for Sol
   Medium review.
6. Fix package-local setup friction when evidence shows a safe scoped repair,
   such as a stdout banner breaking machine framing; test the repair and preserve
   human usability. Do not require network benchmarks or rerun unchanged slow
   gates. Use external pinned oracles in addition to package-authored tests.

## Sinal: release-ready initial facade

**Repository:** `/code/gleam-dream/sinal`

**Branch and baseline:** `master` at
`13105a1777d01d6e1904ae624409ff2f25c739aa`

Start with all Sinal findings in `review-3.md`. Preserve the existing design:
native `telemetry` owns registration, dispatch, failure removal and span timing;
Sinal owns typed descriptors, decoding, scoped cleanup and honest limitations.
Do not add registry introspection merely because the Wave 3 agent suggested it.
No new control, exporter, buffering, metrics, supervision, or OpenTelemetry API
belongs in core without an existing design requirement and consumer.

Mandatory first corrections already identified by review:

- Prove the original error/exit/throw origin frame, not merely a nonempty
  stacktrace. Compare the span exception event's stacktrace with the re-raised
  native stacktrace and prove only one exception event is emitted. Inspect
  native span time and duration integers as well as context identity.
- Assert the actual failure event name and exact handler configuration payload;
  decoding and then discarding either value does not prove the native exposure
  contract.
- Replace the sequential detach test with real synchronization: one process must
  detach while a selected callback is in flight. Add overlapping subscriptions
  and order-independent assertions; never infer handler order.

Close the initial-release evidence and operational surface:

- Strengthen any review-identified gaps in full native failure payloads,
  error/exit/throw fidelity, scoped reporter isolation, multi-event removal,
  span start/stop/exception selection, context identity, native times and exact
  re-raise. Assertions must inspect contract fields rather than only message
  arrival or permissive dynamic decoding.
- Complete deterministic native boundary and race coverage from `sinal-design.md`:
  raw handlers over Sinal emissions, Sinal handlers over raw native maps and
  terms, unknown and malformed fields, independent captured configurations,
  overlapping subscriptions, concurrent emitters, slow synchronous handlers,
  detach after callback selection, scoped self-removal, public-ID replacement,
  nested scopes/spans, and `telemetry:persist/0`. Test documented limits; do not
  claim handler order, linear handles, quiescence, or uncatchable cleanup.
- Add a bounded stress harness for repeated attach/emit/detach, concurrent
  emission and spans. Use deterministic seeds, timeouts and exact accounting so
  races or lost observations fail loudly. Keep it separate from fast unit tests
  when runtime cost warrants it.
- Add reproducible microbenchmarks for the meaningful paths already implemented,
  such as emission without/with a handler, typed decoding and spans. Record OTP,
  warmup, sample count and reported statistics. Establish a baseline, not an
  unsupported performance guarantee or comparison claim.
- Finish README/API documentation and compile-checked examples for typed fields,
  emit/attach/detach, scoped lifetime, failure handling and spans. Document atom
  trust, synchronous execution, failure-event configuration exposure, races,
  non-quiescence and adapter-owned export/buffering.
- Publish an explicit target/support matrix: Sinal's initial release is BEAM/OTP
  native, with every advertised path covered and no hidden unsupported todo.
- Complete evidence-supported package metadata, license/readme inclusion,
  documentation generation and a nonpublishing Hex/package dry run. Do not
  invent ownership, license, repository URL or release claims when evidence is
  absent; report such a missing decision as a release blocker.

Acceptance target: zero initial-facade production todo; all review findings
closed; unit, focused, fault/race, bounded stress and documentation examples
pass; format/check/flake/diff and package dry-run gates pass; benchmark evidence
is reproducible; release-blocker inventory is empty or names a concrete Wave 5
item. No speculative introspection API is added.

## JSON Blueprint: release-ready initial facade

**Repository:** `/code/gleam-dream/json_blueprint`

**Branch and baseline:** `implementation/schema-aware-core` at
`cf378926647ed83dc0669f49d4bb8591b5e1381f`

Start with all Blueprint findings in `review-3.md`. Preserve legacy 1.7.1 APIs
and wire behavior, the exact `Number` model, the finite Draft 2020-12 facade,
and the rule that ordinary Gleam JSON does not depend on Blueprint.

Mandatory first corrections already identified by review:

- Make a non-string tagged discriminator return the structured wrong-type error
  at the `tag` field instead of `DecodeMissingTag`.
- Give the Python schema differential an exact 61-case manifest with expected
  family counts so corpus shrinkage cannot pass as a nonempty mixed sample.
- After JavaScript Number parity is real, run the pure Value/codec/runtime/
  document facade tests on JavaScript; current new tests are Erlang-only.

Complete the remaining initial-release requirements:

- Implement real JavaScript exact-number parity for parsing, canonical text,
  comparison, integrality, native integer construction/projection and exact
  binary64 construction/projection. Use checked decimal/BigInt/DataView-style
  boundaries rather than `Number` shortcuts that lose mathematical equality.
  Run the full 62-case corpus and integrated Value/codec/schema/runtime tests on
  both targets; remove target isolation only when behavior is truly supported.
  Keep Blueprint `Number` arbitrary-precision while enforcing JavaScript native
  `Int` exactness limits: never round an unsafe construction or projection, and
  do not force Erlang's large native-Int behavior through JavaScript numbers. If
  the current error sum cannot state that target-specific refusal truthfully,
  add the design-required typed unsupported-representation outcome and report
  the signature change. Count every original fixture under any target-specific
  adaptation; do not weaken or silently omit the oracle.
- Supply one bounded whole-document byte admission path for Blueprint `Value`
  and schema loading. Preserve duplicate object keys until rejection; validate
  UTF-8; retain exact number tokens; enforce byte, depth, number-token,
  significand and exponent limits; and return structured category plus source
  location. Reuse standard Gleam JSON only where it preserves these contracts.
  Do not create competing parsers or a universal codec API. If the missing
  public signature cannot be derived without contradicting the frozen facade,
  stop that subpart with a concrete minimal signature and evidence for review.
- Finish the exact demonstrated legacy migration contract: the 1.7.1 bridge
  requires an explicit encoder, preserves tested legacy envelopes and decoder
  acceptance, and reports unavailable schema rather than fabricating one.
  Preserve 1.1.0/1.7.1 pinned comparators and document source/wire/error changes.
  Do not claim complete recursive or numeric legacy parity without fixtures.
- Add consumer-owned schema-admission fixtures for the selected Relay, Fabric
  and standalone LLM profiles using frozen oversight evidence. Exercise accepted
  and rejected schemas with located reasons; do not add provider policy to
  Blueprint or claim live provider conformance.
- Add deterministic generated/property and hostile-input suites for codec laws,
  schema agreement, duplicate keys, deep/wide documents, numeric limits and
  unsupported keywords. Keep the accepted 61-schema and 62-number differential
  oracles green. Add reproducible parser/validation benchmarks with methodology,
  limits and no unsupported throughput claims.
- Finish migration and release documentation, compile-checked examples, package
  metadata, license/readme inclusion, generated API docs and nonpublishing
  Hex/package dry runs. Clearly distinguish supported finite Draft 2020-12,
  target parity and explicit unsupported/future families.
- Publish an explicit target/support matrix. Every advertised Erlang and
  JavaScript release path must execute tests; an unsupported family belongs in
  the documented design-deferred inventory, not behind a reachable todo.

Do not implement source generation, `$ref`/`$defs`, arbitrary unions, regex or
the broader schema language in this wave. Those are explicitly design-deferred
families, not release blockers for the approved initial facade.

Acceptance target: no todo or throwing shim on an advertised release path; both
targets pass the initial facade and legacy suites; byte admission, migration and
consumer fixtures have exact tests; hostile/resource and benchmark evidence is
reproducible; format/check/diff, relevant compatibility/differential gates and
package dry runs pass; the release-blocker inventory is empty or identifies a
specific Wave 5 item. If this evidence is accepted, both packages' approved
initial releases are implementation-complete; Wave 5 is used only for an actual
remaining blocker.

## Required final report

Return repository/branch/starting HEAD, review findings closed, changed files,
capability record, supported public behavior, every remaining todo, red-green
increments, oracle provenance/counts, exact gate and dry-run results, benchmark
methodology/results, deferrals, and design divergence. Include a release-blocker
inventory. Separate friction and improvements actually applied from proposals;
do not present a proposal as delivered work. Confirm no commit, push or
publication. Acceptance belongs to the subsequent Sol Medium review.
