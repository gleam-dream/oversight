# Sinal and JSON Blueprint implementation tracker

## Current state

- Program design baseline: oversight
  `bd0b83743533313eb9b4eee2bf7f99ed68a26750`.
- Approved targets:
  - Sinal: `/code/gleam-dream/sinal`, retained Wave 2 checkpoint and Wave 3
    baseline `0204cc7088266e97eb76f77c1b1fb8ef96d5cdb4` on `master`; no configured
    remote. Wave 2 review requires evidence fixes before acceptance.
  - JSON Blueprint: `/code/gleam-dream/json_blueprint`, accepted Wave 2 number
    checkpoint and Wave 3 baseline
    `fc8dae8d1c4eabf97d7ae8d4fa201cdc24f6b289` on
    `implementation/schema-aware-core`, origin `lostbean/json_blueprint`.
- User-approved execution mechanism: external `agy` code agents using
  `--sandbox --dangerously-skip-permissions`, the repo dev shell, Gleam LSP,
  progressive implementation, Gleam, and TDD skills. Main Codex orchestrates;
  it does not implement sibling code.
- Launches on 2026-09-20 used the compatible command form without
  `--output-format`; the initial attempts with that flag were rejected by the
  runtime before either agent began work. No model override was supplied.
  - Sinal original session `51470`: stdout
    `/private/tmp/gleam-dream-sinal-agy-20260920.log`; stderr
    `/private/tmp/gleam-dream-sinal-agy-20260920.stderr`. Its background task was
    cancelled when the agent exited early; resume session `1312` awaited the
    checkpoint and reported through
    `/private/tmp/gleam-dream-sinal-agy-20260920-resume.log`. Review fixes ran
    in session `83774` and reported through
    `/private/tmp/gleam-dream-sinal-agy-20260920-final-fix.log`.
  - JSON Blueprint original session `23946`: stdout
    `/private/tmp/gleam-dream-blueprint-agy-20260920.log`; stderr
    `/private/tmp/gleam-dream-blueprint-agy-20260920.stderr`. Its background task
    was cancelled on early exit; resume session `20460` awaited the checkpoint
    and reported through
    `/private/tmp/gleam-dream-blueprint-agy-20260920-resume.log`. Review fixes
    ran in session `95590` and reported through
    `/private/tmp/gleam-dream-blueprint-agy-20260920-final-fix.log`.
- Approval already covers the staged program below. Do not insert another generic
  plan-approval pause. Stop only for the named Sol Medium review checkpoint or a
  concrete material mismatch.

## Product contract

Sinal supplies typed native BEAM telemetry while preserving synchronous
`:telemetry` behavior, native atoms/maps, callback isolation, scoped cleanup, and
span semantics. It never depends on Blueprint or allocates atoms from runtime
strings.

JSON Blueprint supplies schema-aware exact JSON values, codecs, finite schemas,
runtime validation, and checked composition. Its exact `Number` is local to its
schema/value model. Ordinary JSON users prefer standard Gleam JSON; no universal
codec package is introduced. Existing JSON Blueprint 1.7.1 behavior remains a
compatibility contract during migration. Source generation is retained future
tooling outside the initial facade.

Neither package is production-ready merely because its interface compiles.

## Approved staged method

1. **Signature scaffold:** declare top-level public types, constructors, errors,
   and signatures with honest named Gleam todos. All intended modules compile.
   No fake generic values or promoted laboratory protocol internals.
2. **Evidence harvest:** run pinned upstream/baseline suites unchanged; record
   revision, hash/checksum, license, source case, normalization, and matched
   semantic for every adopted test. Add package behavior tests that compile and
   then fail for the intended unimplemented behavior.
3. **Incremental implementation:** run one public behavior red-to-green at a
   time, refactor only while green, and continue toward the full retained design
   scope. A thin initial facade is a release slice, not permission to declare the
   package complete.

Compile-green and behavior-red are separate statuses. No skipped, commented,
expected-failure, or unconditional-pass mechanism may disguise missing behavior.
No benchmark/parity/conformance claim is accepted without the named oracle run.

## Wave 1: external checkpoint

### Sinal

- Work order: [`sinal-work-order.md`](sinal-work-order.md)
- Target: scaffold + telemetry 1.4.2 provenance/upstream baseline + first native
  attach/emit synchronous-delivery red cycle; optionally its smallest real green.
- Required stop: Sol Medium code review before broad native adapter or span work.

### JSON Blueprint

- Work order: [`blueprint-work-order.md`](blueprint-work-order.md)
- Target: untouched 1.7.1 Erlang/JS and compatibility baseline + safe branch +
  schema-aware scaffold beside legacy API + exact-number/schema/compatibility
  provenance + first exact-number red cycle; optionally its smallest exact green.
- Required stop: Sol Medium code review before broad codec/schema/runtime work.

## Acceptance record

| Package        | External run             | Baseline                    | Scaffold                   | Oracle corpus | First red/green          | Review                             | Notes                          |
| -------------- | ------------------------ | --------------------------- | -------------------------- | ------------- | ------------------------ | ---------------------------------- | ------------------------------ |
| Sinal          | fixes reported (`83774`) | independently focused-green | compile-green; 6 todos     | traced        | expected red at `attach` | [Sol Medium accepted](review-1.md) | committed locally as `35c83e1` |
| JSON Blueprint | fixes reported (`95590`) | independently focused-green | compile-green; named todos | traced        | tested Erlang red→green  | [Sol Medium accepted](review-1.md) | committed locally as `25d554b` |

The external reports establish the execution history. The focused evidence and
acceptance verdict come from the independent [Sol Medium review](review-1.md).
Every initial blocking and secondary finding was resolved on re-review. This
accepts only the scaffold and first tested vertical; remaining named todos mean
neither package is production-complete. Main committed each accepted checkpoint
at the hashes above; neither package was pushed or published.

## Accepted Wave 1 checkpoints

### Sinal report

- The accepted checkpoint is committed as
  `35c83e11e1d58f1ee9e3185112842e7ab75c666e`. Its changes add the public
  scaffold in [`sinal.gleam`](/code/gleam-dream/sinal/src/sinal.gleam),
  [`fields.gleam`](/code/gleam-dream/sinal/src/sinal/fields.gleam),
  [`span.gleam`](/code/gleam-dream/sinal/src/sinal/span.gleam), and
  [`exception.gleam`](/code/gleam-dream/sinal/src/sinal/exception.gleam), plus
  [`internal/ffi.gleam`](/code/gleam-dream/sinal/src/sinal/internal/ffi.gleam),
  [`sinal_ffi.erl`](/code/gleam-dream/sinal/src/sinal_ffi.erl),
  [`sinal_scope_ffi.erl`](/code/gleam-dream/sinal/src/sinal_scope_ffi.erl),
  [`focused_behavior.gleam`](/code/gleam-dream/sinal/test/focused_behavior.gleam),
  updates to the template manifest/configuration and test, and
  [`telemetry-1.4.2.md`](/code/gleam-dream/sinal/test/oracle/telemetry-1.4.2.md).
- The agent reports `telemetry` 1.4.2 at commit
  `7baf8085e406d5ae9e43b284d7c866742ae04b28`, Hex checksum
  `928F6495066506077862C0D1646609EED891A4326BEE3126BA54B60AF61FEBB1`,
  Apache-2.0, with all 42 upstream Common Test cases passing. The independent
  re-review passed `gleam check` with exactly six named todos, nine unit tests,
  formatting, `git diff --check`, and the intentionally red focused command.
- The focused command stops at the intended `sinal.attach` todo after setting up
  assertions for event selection, decoded measurement and metadata, and emitter
  process identity. Six named todos remain: native emit, attach, attach-many,
  scoped lifetime, span event derivation, and `run_span`. No native adapter
  behavior is claimed green.
- Trusted atom-derived event, prefix, and field identity is accepted for this
  boundary: empty identities and duplicate native identities are rejected, and
  runtime strings do not allocate atoms. Native callback failure/removal, races,
  cleanup, and spans remain unimplemented. `agent-lsp` was unavailable during
  the external run; compiler and focused re-review gates supplied the evidence.

### JSON Blueprint report

- The accepted checkpoint is committed on `implementation/schema-aware-core` as
  `25d554b0bdde421bd2037f68253315ebc0ab3090`; legacy files remain untouched.
  New scaffold modules are
  [`number.gleam`](/code/gleam-dream/json_blueprint/src/json/blueprint/number.gleam),
  [`value.gleam`](/code/gleam-dream/json_blueprint/src/json/blueprint/value.gleam),
  [`codec.gleam`](/code/gleam-dream/json_blueprint/src/json/blueprint/codec.gleam),
  [`runtime.gleam`](/code/gleam-dream/json_blueprint/src/json/blueprint/runtime.gleam),
  and [`document.gleam`](/code/gleam-dream/json_blueprint/src/json/blueprint/document.gleam),
  with [`json_number_ffi.erl`](/code/gleam-dream/json_blueprint/src/json_number_ffi.erl),
  [`number_test.gleam`](/code/gleam-dream/json_blueprint/test/number_test.gleam), and
  [`schema-aware-core.md`](/code/gleam-dream/json_blueprint/test/oracle/schema-aware-core.md).
- The independent re-review passed Erlang and JavaScript checks, formatting,
  `git diff --check`, 24 Erlang tests, and all 21 legacy JavaScript tests. The
  external report also records the pinned 1.7.1/1.1.0 compatibility and oversight
  gates passing. The provenance ledger now contains 24 rows: 21 legacy tests and
  three focused exact-number tests.
- The tested Erlang vertical went red then green for exact decimal parsing,
  canonical rendering, comparison, resource limits, and bounded exact-integer
  projection. Other number functions, codec composition, value-object
  validation, schema rendering, runtime-contract validation, native decoding,
  and document loading remain named todos.
- The new numeric behavior is Erlang-first. The throwing JavaScript FFI was
  removed; new JavaScript numeric paths are explicit todo scaffolds, while all 21
  legacy JavaScript tests still pass. The broader exact-number oracle, schema,
  parser, compatibility, and generation work remains open.

## Wave 2: checkpointed and reviewed

- Shared handoff: [`wave-2-work-order.md`](wave-2-work-order.md).
- Launched with the requested sandbox flags and no model override. Sinal logs:
  `/private/tmp/gleam-dream-sinal-wave2.log` and `.stderr`; Blueprint logs:
  `/private/tmp/gleam-dream-blueprint-wave2.log` and `.stderr`.
- Sinal milestone: native emit/attach/attach-many/detach and callback/decode
  failure semantics, with coherent scoped lifetime permitted after that adapter
  is green.
- JSON Blueprint milestone: exercise the complete 62-case exact-number oracle
  through the package, then add only a coherent tested Value/primitive-codec
  slice if it fits without a schema-engine detour.
- Both checkpoints include `test/oracle/wave-2-capabilities.md` and were committed
  locally without push or publication. See the independent
  [`review-2.md`](review-2.md).

| Package        | Wave 2 baseline                            | External session | Checkpoint commit                          | Review                                                                        |
| -------------- | ------------------------------------------ | ---------------- | ------------------------------------------ | ----------------------------------------------------------------------------- |
| Sinal          | `35c83e11e1d58f1ee9e3185112842e7ab75c666e` | `90715`          | `0204cc7088266e97eb76f77c1b1fb8ef96d5cdb4` | changes required: three P1 evidence gaps and one P2 capability correction     |
| JSON Blueprint | `25d554b0bdde421bd2037f68253315ebc0ab3090` | `55928`          | `fc8dae8d1c4eabf97d7ae8d4fa201cdc24f6b289` | accepted Erlang exact-number vertical; JavaScript numbers explicitly deferred |

Sinal's retained adapter has no demonstrated implementation defect, and its
focused gates pass. Wave 3 must first prove error/exit/throw fidelity, the full
native failure-event payload, and attach-many removal across every registered
event, then correct the absolute-path LSP probe. Blueprint independently passes
30 Erlang tests, 21 legacy JavaScript tests, and the 62-case number oracle.

## Wave 3: ready to launch

- Shared handoff: [`wave-3-work-order.md`](wave-3-work-order.md).
- Sinal target: close the Wave 2 review gaps, then complete scoped lifetime,
  native spans, boundary/error/concurrency evidence, and documentation as a
  feature-complete initial-facade candidate.
- JSON Blueprint target: complete the current Value/codec/schema/runtime/document
  facade with package-level law and differential evidence while preserving
  legacy Erlang/JavaScript behavior.
- Both runs use the absolute LSP bridge, verify `search_web` and
  `read_url_content`, record `wave-3-capabilities.md`, remain uncommitted, and
  stop for Sol Medium review.

| Package        | Wave 3 baseline                            | External session/log | Delivery    | Review              |
| -------------- | ------------------------------------------ | -------------------- | ----------- | ------------------- |
| Sinal          | `0204cc7088266e97eb76f77c1b1fb8ef96d5cdb4` | pending launch       | not started | Sol Medium required |
| JSON Blueprint | `fc8dae8d1c4eabf97d7ae8d4fa201cdc24f6b289` | pending launch       | not started | Sol Medium required |

## Subsequent roadmap

- **Wave 3 — core behavior:** complete each initial production facade and its
  direct native/differential evidence.
- **Wave 4 — integration and compatibility:** Sinal upstream/raw-BEAM and
  package-observation compatibility; Blueprint advertised JavaScript parity,
  byte-parser/reuse policy, legacy migration, and selected Relay/Fabric/LLM
  schema-consumer profiles.
- **Wave 5 — hardening and release:** fault, stress, hostile-input, benchmark,
  documentation, packaging, upgrade, and release gates. Compress Waves 4 and 5
  when evidence is already green; extend beyond Wave 5 only for a concrete
  blocker.
- Blueprint source generation, recursive references, and broader schema families
  remain explicit design-deferred post-release capabilities. Their exclusion
  from the initial release does not cancel them.

Each later wave must name a public behavior, real boundary, source oracle, focused
red, green gate, and evidence limitation. Reopen the frozen API only when actual
implementation exposes a concrete caller mismatch; update the owning design
before continuing through a material change.

## Standard external result contract

Every external run returns: repository/branch/HEAD; changed files; public
surface; named todos; baseline commands; oracle provenance; focused red/green;
all gate results; preserved user changes; concrete design mismatch; and next
smallest slice. Main records the result in the table above after independent
review. No external agent pushes or publishes.
