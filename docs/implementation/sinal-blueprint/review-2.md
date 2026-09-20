# Wave 2 implementation review

Review bases:

- Sinal: `35c83e11e1d58f1ee9e3185112842e7ab75c666e`
- JSON Blueprint: `25d554b0bdde421bd2037f68253315ebc0ab3090`

The review covered each repository's complete diff from its base. The reviewed
snapshots were subsequently committed unchanged as Sinal
`0204cc7088266e97eb76f77c1b1fb8ef96d5cdb4` and JSON Blueprint
`fc8dae8d1c4eabf97d7ae8d4fa201cdc24f6b289`. Scaffold todos outside this wave
were treated as declared incomplete scope.

## Sinal

**Recommendation:** changes required before calling the Wave 2 work order
accepted. The adapter implementation is suitable to retain as an explicitly
incomplete checkpoint; no implementation defect was demonstrated by this
review. The following evidence gaps must be the first work in the next wave.

### P1 — scoped exception tests do not prove exception fidelity

`test/sinal_test.gleam:633-669` and `test/sinal_test.gleam:671-715` claim that
the original work exception is re-raised, but pass the caught value to
`decode.dynamic`, which accepts every dynamic term. The assertion cannot
distinguish `{caught, Class, Reason, Stacktrace}` from `{ok, Value}` and checks
none of class, reason, or stacktrace. Only `erlang:error/1` is exercised;
catchable `exit` and `throw` are absent despite the work order requiring all
three classes. Add assertions for the exact caught shape, class and reason,
plus stacktrace preservation, for error, exit, and throw. Repeat the exact
original-exception assertion when cleanup returns an error and when the cleanup
reporter raises. `(in-place-fix, next-wave-first)`

### P1 — native failure-event evidence discards the contract payload

The listeners at `test/sinal_test.gleam:352-354`, `:411-413`, `:459-461`, and
`:504-506` discard event name, measurements, metadata, and configuration and
assert only that some message arrived. This does not establish the frozen
`:telemetry` 1.4.2 boundary in `sinal-design.md:171-172`: failure measurements
contain native monotonic/system times, and metadata contains the selected event
name, raw handler identity, handler configuration, exception class, reason,
and stacktrace. Decode and assert those fields, including the adapter-raised
reason for typed decode/handler failures and the original reason for an
unexpected callback exception. `(in-place-fix, next-wave-first)`

### P1 — `remove_all_handler_on_failure` provenance is overclaimed

`test/oracle/telemetry-1.4.2.md:52` marks the upstream multi-event removal case
ported, but `test/sinal_test.gleam:482-527` attaches one event and exercises
only a Gleam panic/error. It proves neither removal of every event registered
under one `attach_many` identity nor upstream error/exit/throw coverage. Attach
one identity to at least two events, fail one invocation, and prove later
emission of every registered event cannot invoke the handler. Align the table
claim with the resulting evidence. `(in-place-fix, next-wave-first)`

### P2 — capability report missed the configured LSP bridge

`test/oracle/wave-2-capabilities.md:26-28` reports only `which agent-lsp` and a
compiler fallback. The work order supplied
`/etc/profiles/per-user/edgar/bin/agent-lsp`; Blueprint successfully used that
path. Correct the capability record and run the requested real-source probe, or
record an actual failure from that path. This is a report defect, not an
implementation blocker. `(in-place-fix, next-wave-first)`

The implementation otherwise preserves opaque native handler identities,
passes native atom lists and maps without Blueprint/JSON conversion, performs
typed callback decoding, and uses the upstream detach path after callback
failure. `sinal_scope_ffi:with_scope/3` captures and re-raises the original
BEAM class, reason, and stacktrace in source; the missing point is independent
behavioral proof.

Independent focused validation passed:

- `gleam check`
- `gleam test`: 25 tests
- `gleam run -m focused_behavior`
- `gleam format --check src test`

The two declared span todos remain outside Wave 2. I did not independently
exercise callback concurrency/quiescence because the frozen design explicitly
does not promise it, and I did not run the full oversight gate.

## JSON Blueprint

**Recommendation:** accept the Wave 2 exact-number vertical for Erlang, with
the JavaScript number kernel honestly deferred by named todos.

No acceptance-blocking finding was found. The package test file directly
enumerates the oracle's 39 parse cases, 11 comparison pairs, 7 binary64
fixtures, and 5 integer fixtures. It asserts canonical text, integrality,
checked integer/float projections, projection failure categories, and exact
float roundtrip bits rather than using aggregate counts as a substitute. The
implementation keeps exact decimal state in the opaque `Number`, uses native
float parsing only as a checked projection candidate, and guards token bytes,
raw significand digits, normalized exponent magnitude, and integer projection
digits. No Blueprint/schema dependency was introduced into the kernel, no
JavaScript throwing FFI stub remains, and legacy sources were unchanged.

Independent focused validation passed:

- Erlang `gleam check` and `gleam test`: 30 tests
- JavaScript `gleam check` and `gleam test`: 21 legacy tests
- `gleam format --check src test`
- the oversight `number_check.py` oracle: `PASS: 62 independent exact-number cases`

I compared the package fixture families and expected results with
`playground/interface_lab/src/consumers/json_numbers.gleam` and the independent
Python `Decimal`/`Fraction` and float-bit checks in
`playground/interface_lab/number_check.py`. I did not claim cross-target Number
support: the JavaScript public functions remain explicit named todos, as the
work order permits, and no new JavaScript numeric behavior is tested.
