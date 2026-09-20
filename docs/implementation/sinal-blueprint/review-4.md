# Wave 4 implementation review

Review baselines:

- Sinal: `13105a1777d01d6e1904ae624409ff2f25c739aa` through the mixed staged and unstaged Wave 4 tree
- JSON Blueprint: review pending package completion

## Sinal

**Recommendation:** accepted for the approved initial release facade. The four
Wave 3 P1 findings are closed with direct native evidence. The README snippets,
bounded concurrent-span harness, and release claims were corrected during
review and now match the executable evidence.

The final README identifies OTP 28 and `:telemetry` 1.4.2 as the tested runtime,
describes typed codec work at the native map boundary without a zero-overhead or
performance-equivalence claim, and labels the package a reviewed release
candidate. Scoped cleanup is limited to ordinary return and catchable
error/exit/throw, with `kill` and abrupt process loss documented separately. Its
test count is the observed 47.

The corrected behavior evidence is substantive:

- Error, exit, and throw paths assert their exact origin frame. Span exception
  metadata carries the exact caught native stacktrace and only one terminal
  exception event is observed.
- All four handler-failure paths assert `[telemetry, handler, failure]`, the
  selected event, handler identity, and exact `nil` handler configuration.
- The detach race uses a callback-entry barrier, detaches while the selected
  callback is blocked, then proves that callback completes and later emissions
  do not select it. Overlapping handlers are checked without imposing order.
- Span system time, monotonic time, duration, context reference identity, and
  cross-invocation distinction are inspected as native terms.
- The stress harness accounts for all 500 concurrent emissions and checks 20
  concurrent spans for per-worker start/stop correlation and mutual context
  distinction.
- Five published Gleam snippets occur verbatim as executable code in
  `test/readme_example_test.gleam`; a test extracts all five README blocks and
  requires each block to match the compiled module. The emit example now
  destructures `FieldEncodeError` correctly.
- The Hex dry-run archive contains the expected production sources, README,
  license, package manifest, generated Erlang and include files.

Validation passed on Erlang/OTP 28; I independently reran the focused package
commands through the Hex dry run:

- `gleam check`
- `gleam test`: 47 passed
- `gleam run -m focused_behavior`
- `gleam run -m stress_test`
- `gleam format --check src test`
- `gleam docs build`
- `gleam export hex-tarball`
- `nix flake check`
- `git diff --check`

The benchmark ran independently before the final test-only corrections and
records OTP, warmup, aggregate sample count, elapsed time, mean nanoseconds per
operation, and derived throughput for four implemented paths. It is a useful
local baseline, not evidence for a performance comparison. I did not test an
OTP version other than 28, publish a package, or rerun the full unrelated
oversight suite.

## JSON Blueprint

**Recommendation:** accepted for the approved initial schema-aware facade. The
Wave 3 discriminator defect and all Wave 4 review findings are closed. The
legacy public module and its existing Erlang and JavaScript behavior remain
covered, while the new modules expose bounded parsing, exact numbers, typed
codecs, runtime validation, and an explicit legacy-decoder migration bridge.

The corrected implementation and evidence include:

- `number.from_int` is checked on both targets. JavaScript rejects non-finite,
  non-integer, and unsafe native numbers before construction; parsing,
  canonical text, comparison, binary64 decomposition, and integer projection
  retain exact BigInt/DataView behavior.
- Parser byte and depth bounds, CR/LF/CRLF location accounting, invalid UTF-8,
  and duplicate-key locations are directly tested. Duplicate detection now
  uses a dictionary, including a 2,000-member wide-object boundary fixture.
- Migration requires an explicit encoder, invokes the real legacy decoder,
  returns `UnknownSchema`, and preserves the exercised legacy object and
  `type`/`data` envelope behavior.
- All 61 differential cases have semantic identities in a frozen manifest of
  schema, instance, family, and expected outcome. The checker proves that
  missing, extra, duplicate, replaced-instance, and flipped-outcome mutations
  fail closed before comparing Blueprint decoder/runtime results with
  `jsonschema` 4.26.0's `Draft202012Validator`.
- The deterministic generated corpus exercises codec identity and idempotence
  laws plus typed rejection paths across integers, strings, booleans, lists,
  nullable values, pairs, ranges, records, enums, tagged unions, and closed
  objects on both targets.
- Consumer admission distinguishes exact decimals and decimal bounds from
  integer capability, with direct accepting and rejecting profile evidence.
- The first two README Gleam blocks occur verbatim in compiled executable test
  source. The migration example handles checked integer construction, and the
  target matrix limits browser status to unverified rather than inferring it
  from Node execution.
- The runnable benchmarks use monotonic target-native timers, warmup, elapsed
  time, sample count, mean, and throughput. The number benchmark is explicitly
  named `number_parse_canonical_7_token_batch`; its report defines one operation
  as that batch and gives batch and per-token units. The measurements are local
  baselines, not comparative performance claims.

Independent focused validation passed:

- `gleam format --check src test`
- `gleam check`
- `gleam test --target erlang`: 99 passed
- `gleam test --target javascript`: 99 passed
- `gleam run -m bench_test` on Erlang/OTP 28 and Node.js 24.15.0
- `python3 test/schema_check.py`: 61 cases across 13 families, including the
  fail-closed mutation proofs
- `gleam docs build`
- `gleam export hex-tarball`
- `git diff --check`

The dry-run archive contains the new production modules and both exact-number
native implementations. I did not run a browser, publish the package, or expand
review into the explicitly deferred source generation, recursive reference,
arbitrary union, or regex families.
