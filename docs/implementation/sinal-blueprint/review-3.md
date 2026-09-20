# Wave 3 implementation review

Review ranges:

- Sinal: `0204cc7088266e97eb76f77c1b1fb8ef96d5cdb4..13105a1777d01d6e1904ae624409ff2f25c739aa`
- JSON Blueprint: `fc8dae8d1c4eabf97d7ae8d4fa201cdc24f6b289..cf378926647ed83dc0669f49d4bb8591b5e1381f`

The snapshots were committed unchanged while this review ran. They are useful
large checkpoints, but the findings below prevent claiming the Wave 3 work
order fully accepted. Fix them before expanding Wave 4 integration scope.

## Sinal

**Recommendation:** retain the checkpoint; changes required before accepting
the production candidate. I found no source defect requiring an architectural
redesign. Native adapter and span execution use `:telemetry` 1.4.2 directly,
and all production-path todos are gone.

### P1 — original stacktrace fidelity is still not proved

The scoped error/exit/throw assertions at `test/sinal_test.gleam:739-815` and
cleanup variants at `:855-963` establish exact class and reason but only call
`is_stacktrace_list`. Any newly generated nonempty stacktrace passes. The same
weak assertion appears for span work at `:1433-1495`, while the exception
event's `ExceptionStacktrace` is not inspected at all. The work order requires
the original triple. Assert a stable origin frame from each raising helper in
the caught stacktrace, and assert the exception event carries the same native
stacktrace as the re-raised exception. Also prove no second exception event
remains after the final throw case. `(in-place-fix, wave-4-first)`

### P1 — full handler-failure payload evidence still omits two fields

`test/scope_test_ffi.erl:37-61` decodes `handler_config`, but no test asserts the
field (`handler_config` occurs only in the test record declaration at
`test/sinal_test.gleam:607`). The failure listeners at `:352`, `:419`, `:475`,
and `:528` also discard their callback event-name argument. Assert that the
listener receives exactly `[telemetry, handler, failure]` and that metadata
contains the adapter's exact native configuration, currently `nil`, alongside
the already-checked handler identity, selected event, class, reason, and
stacktrace. `(in-place-fix, wave-4-first)`

### P1 — the required detach race test is sequential

`detach_during_concurrent_emission_test` at `test/sinal_test.gleam:1769-1792`
emits, waits for completion, detaches, and emits again in one process. It does
not select a callback, block it in flight, detach concurrently, and then show
that selected work may finish after detach. The diff also has no evidence for
overlapping subscriptions or the explicitly unspecified cross-handler order.
Add deterministic barriers rather than sleeps to establish selection before
detach, then test overlapping identities while asserting only per-handler
delivery, not an order guarantee. `(in-place-fix, wave-4-first)`

### P1 — native span-owned values are wrapped but not behaviorally checked

The ordinary span test at `test/sinal_test.gleam:1223-1288` ignores start timing
and stop duration/monotonic values. The exception test ignores exception
duration/monotonic values and its stacktrace wrapper. Consequently it proves
typed record routing but not the work order's native time-unit and native-term
boundary. Inspect the unwrapped dynamics through a test-only native predicate:
times and durations must be native integers, contexts must preserve native
identity within an invocation and differ across invocations, and exception
stacktraces must be nonempty native lists matching the re-raised origin.
`(in-place-fix, wave-4-first)`

The Wave 2 multi-event removal claim is now supported for error, exit, and
throw, and class/reason checks replace the formerly vacuous dynamic assertion.
Reserved span fields, business `Result.Error` as stop, context correlation,
distinct invocations, and nested start/stop order have direct tests.

Independent focused validation passed:

- `gleam check`
- `gleam test`: 39 tests
- `gleam run -m focused_behavior`
- `gleam format --check src test`
- `git diff --check` was clean for the reviewed range

I did not run stress or release gates, which belong to later waves.

## JSON Blueprint

**Recommendation:** retain the checkpoint; changes required before accepting
the complete initial facade. The Erlang finite facade and independent schema
differential are substantial and green, but one structured-error defect and
two evidence holes remain.

### P1 — a present non-string tag is reported as missing

`src/json/blueprint/codec.gleam:685-699` sends every non-successful tag/payload
shape through `DecodeMissingTag`. A wire object with a present numeric or
boolean `tag` is therefore classified as absence. This contradicts the
structured wrong-type contract and differs from
`runtime.gleam:430-464`, which correctly returns `NonStringTag`. Add a distinct
codec reason, or a located `DecodeExpectedString`, and cover present
non-string tag separately from missing tag and missing payload.
`(in-place-fix, wave-4-first)`

### P1 — the differential oracle can silently shrink below 61 cases

`test/schema_check.py:20-52` accepts any nonempty emitted case list containing
one accepted and one rejected outcome. It prints the observed count but never
requires 61 cases, the 13 family counts, unique case identities, or the frozen
fixture manifest. Deleting most runner cases can still produce green. Give
every fixture a stable case identity and make the Python oracle reject missing,
duplicate, or extra cases against the frozen 61-case family manifest. Keep the
direct Gleam expected outcomes and the independent `Draft202012Validator`
comparison. `(in-place-fix, wave-4-first)`

### P1 — JavaScript-safe facade behavior is compiled but untested

Every new facade test module is marked `@target(erlang)`; the JavaScript run
executes only the 21 legacy tests. The work order permits JavaScript Number
todos, but explicitly requires pure facade behavior on both targets when it
does not depend on the Number kernel. Add JavaScript execution for safe
`Value`, string, boolean, nullable, list, object, enum, tagged, normalization,
validation, and strict-loader cases that do not construct or compare Number.
Keep Number-dependent cases target-specific until Wave 4 resolves the named
todos. `(in-place-fix, wave-4-first)`

The reviewed implementation otherwise preserves duplicate object entries at
the `Value` layer, rejects duplicates at checked object/codec/document
boundaries, propagates `UnknownSchema`, retains located errors, normalizes
finite schemas, rejects unsupported document keywords/forms, and leaves legacy
sources intact. The differential uses the actual package-emitted schema,
normalized schema, and instance with `Draft202012Validator`; its semantic
comparison is real once the fixed corpus manifest is enforced.

Independent focused validation passed:

- Erlang `gleam check` and `gleam test`: 65 tests
- JavaScript `gleam check` and legacy `gleam test`: 21 tests
- `gleam format --check src test`
- schema differential in the oversight Python environment:
  `PASS: 61 schema/decoder/runtime cases agree with Draft202012Validator`
- `git diff --check` was clean for the reviewed range

The package's own dev shell does not provide `python3`; the documented
differential command correctly uses `nix develop /code/gleam-dream/oversight`.
I did not run the full oversight suite or claim JavaScript Number support.
