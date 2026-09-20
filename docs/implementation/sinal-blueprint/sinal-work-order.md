# Sinal implementation work order

## Assignment and stop point

Implement the first production-bound Sinal checkpoint in
`/code/gleam-dream/sinal`. Work only in that repository. The authoritative design
baseline is oversight commit `bd0b83743533313eb9b4eee2bf7f99ed68a26750`:

- [`sinal-design.md`](../../../sinal-design.md)
- [`PUBLIC-API.md`](../../../PUBLIC-API.md)
- [`API-COVERAGE.md`](../../../API-COVERAGE.md), Sinal rows
- [`research/sinal-lifetime-contract.md`](../../../research/sinal-lifetime-contract.md)

This first external run ends at a review checkpoint. Deliver:

1. a clean, compiler-checked public type/signature scaffold using honest named
   `todo` bodies where behavior is not implemented;
2. a traced, pinned `telemetry` 1.4.2 oracle corpus and a passing upstream
   baseline;
3. one focused new behavior test that is red for the intended missing Sinal
   behavior, or one small red-to-green vertical only after the scaffold and
   corpus have been recorded;
4. a concise report using the template at the end of this file.

Stop there for independent Sol Medium review. Do not broadly implement the
adapter, spans, or every field combinator in this run. Do not push, publish, or
read secrets.

## Fixed boundaries

Sinal is a typed facade over native BEAM `telemetry`, not an actor/event bus and
not a JSON library. Production events use trusted native atom lists and native
BEAM maps. Never allocate an atom from a request string, tenant name, provider
name, or any other runtime text. Native references, exception reasons, and
stacktraces must cross the FFI without JSON conversion. Sinal has no Blueprint
dependency.

Native `telemetry` owns the shared registry and synchronous callback execution in
the emitting process. Separate emitters may call one handler concurrently.
Declared decode or handler failures must be classified and then enter native
callback-failure behavior; unexpected error/exit/throw follows the same upstream
removal path. A subscriber error never becomes `emit`'s error result.

Observations report an already-decided package transition and cannot control it.
Buffering, export, OpenTelemetry, and supervision are separate adapters. Do not
add a universal lifecycle event, request context, or background actor.

## Repository and tool facts to establish first

The current repository is a clean Gleam 1.18/OTP template at commit
`225f38c391170fabb8795b9cdf41362540350d3f`
when this order was written. Preserve unrelated user changes if that fact has
changed. It currently has no configured git remote; do not add one as part of
this checkpoint. Read `/code/gleam-dream/sinal/AGENTS.md`, `gleam.toml`,
`manifest.toml`, and the flake before editing.

Run and record:

```sh
git status --short --branch
git rev-parse HEAD
nix develop --command gleam --version
nix develop --command gleam deps list
nix develop --command gleam check
nix develop --command gleam test
nix flake check
```

Start Gleam language intelligence before edits. Detect `agent-lsp`, start it
through the project shell as `nix develop --command agent-lsp gleam:gleam,lsp`,
inspect server capabilities, and use absolute paths. Use symbol/diagnostic tools
for the scaffold; finish with the compiler because LSP is not the build gate. If
the bridge is unavailable, record that precisely and continue with the project
compiler rather than installing an unreviewed global tool.

Add the exact `telemetry` 1.4.2 dependency through the project package tooling.
Inspect and retain the generated manifest change in the worktree. Record its Hex
checksum, upstream tag and exact source commit, Apache-2.0 license, and
source/test URLs. Do not loosen the version silently or create a git commit unless
the orchestrator requests it.

## Scaffold: public contract, compile-green

Replace the version-only skeleton with a small module layout. Keep unstable FFI
and adapter records under `sinal/internal/*`; public constructors alone may
construct opaque invariant-bearing values. Use custom errors and exhaustive
cases. Never return fake `Nil`, fabricate opaque values, use an undefined generic,
or erase a type to make the scaffold compile. An unfinished executable path is a
named `todo as "..."`, and its warning must be inventoried.

Use these laboratory modules as type evidence, not files to copy blindly:

- [`lab/sinal.gleam`](../../../playground/interface_lab/src/lab/sinal.gleam)
- [`lab/sinal_fields.gleam`](../../../playground/interface_lab/src/lab/sinal_fields.gleam)
- [`lab/sinal_span.gleam`](../../../playground/interface_lab/src/lab/sinal_span.gleam)
- [`lab/sinal_exception.gleam`](../../../playground/interface_lab/src/lab/sinal_exception.gleam)
- [`sinal_scope_ffi.erl`](../../../playground/interface_lab/src/sinal_scope_ffi.erl)

The compile-green surface must represent these initial-facade families:

- `Fields(a)`: empty, one native field, pair/composition, `imap`, declared keys,
  fallible encode/decode, duplicate declaration rejection, missing/duplicate/
  invalid value errors, and tolerance of unrelated foreign fields. The lab's
  `FieldMap` and Blueprint codec are disposable evidence; production fields need
  trusted atom keys and native map conversion. If a safe public native-field
  constructor cannot be stated without resolving atom ownership, stop and report
  the exact signature collision instead of accepting strings and allocating atoms.
- `Event(measurements, metadata)`: opaque descriptor, logical/native identity,
  separate measurement and metadata `Fields`, safe name accessor, `emit`.
- `Handler(m, d, e)`, `HandlerId`, `Attachment`: checked public IDs, typed
  handler, `attach`, nonempty `attach_many`, origin-retained `detach`, duplicate
  event-name error, declared handler/decode failures, backend/native failures.
- Scoped lifetime: `ScopeCleanupFailure`, `ScopedCompletion(a)`, and
  `with_attachments`, preserving ordinary work values separately from cleanup.
- Typed span shapes: prefix, start/stop/exception measurements and metadata,
  reserved-field validation, span event descriptors, and ordinary `Completion`.
  Scaffold the types and constructors; `run_span` may remain an explicit todo.

Do not promote laboratory-only `Backend`, `BackendAttachment`, symbolic layout
probes, exception testing helpers, or package-observation adapters merely because
they are public in the playground. Backend injection is an adapter seam; decide
its public constructor only from the design and a real consumer. If the current
prototype signature conflicts with native map/atom safety, document the mismatch
for review rather than inventing a wrapper API.

Compile-green means `gleam check` succeeds and every todo warning is named in the
checkpoint. It does not mean behavior tests pass or the package is implemented.

## Oracle harvest and provenance

The oracle is `beam-telemetry/telemetry` 1.4.2, especially `src/telemetry.erl`
and `test/telemetry_SUITE.erl`. Before porting a case, run the relevant upstream
suite unchanged at the pinned source revision in an isolated checkout/cache and
record its command and outcome. A failing upstream baseline blocks claims about
that case; do not normalize the expected result to fit Sinal.

Create a durable provenance table in the Sinal repository, for example
`test/oracle/telemetry-1.4.2.md`, with one row per adopted test:

| Sinal test | upstream file + case | source commit/license | normalization | matched semantic |
| ---------- | -------------------- | --------------------- | ------------- | ---------------- |

Normalization may replace native identifiers, clocks, or assertion syntax, but
must state what changed. It may not weaken callback order/identity, failure class,
exception fidelity, or map semantics. Keep upstream-source quotations minimal and
respect Apache-2.0 notices. Record unported cases as coverage backlog, not passing.

The eventual corpus must cover:

- synchronous same-process delivery and slow-handler blocking;
- unspecified handler order and concurrent calls from separate processes;
- duplicate handler IDs, multi-event attachment, detach, repeated detach, and
  already-selected callback behavior across detach;
- callback error/exit/throw removal plus `[telemetry, handler, failure]` contents;
- native maps, atom-list names, unexpected/missing/duplicate typed fields;
- `span/3` start/stop/exception names, native timing keys, context propagation,
  ordinary returned `Result.Error` taking the stop path, and exact re-raise;
- scoped cleanup on return and catchable exception, cleanup failure reporting,
  reporter failure not replacing the original exception, and race limitations.

No benchmark or parity claim may be made unless that benchmark/oracle was run.
Alongside the provenance table, keep a source-coverage ledger naming each
upstream case family as ported, planned, excluded with reason, or blocked. A
family is never “covered” merely because a nearby Sinal test passes.

## Focused first red cycle

After baseline and scaffold are recorded, add one test through public APIs for
the smallest native path: attach one typed handler to one trusted event, call
`emit`, and assert the handler ran synchronously in the emitter with decoded
measurement and metadata values. The test must reach the intended todo/native
gap and fail for that reason. Keep the legacy template test green or replace it
with a meaningful compile/smoke assertion.

Report baseline-green and new-behavior-red separately. Do not mark the red test
skipped, expected-failure, commented out, or always passing. If Gleeunit cannot
retain an intentional red test without obscuring the baseline, provide a focused
test module/command whose nonzero result is asserted in the report while the
full baseline command is separately green. The review checkpoint must be able to
reproduce both states.

Create an expected-red catalog for the checkpoint with: focused command, public
behavior, expected failure site/message, observed failure, and removal condition.
Todo warnings belong in a separate scaffold-warning inventory. Baseline failures
never enter the expected-red catalog.

Only if the scaffold, provenance table, upstream baseline, and red failure are
already captured may this run implement the minimum vertical path to green. That
path must call real `telemetry` 1.4.2 with native atom names/maps. Do not implement
an in-memory registry substitute.

## Gates and report

Run the oversight evidence without editing it:

```sh
cd /code/gleam-dream/oversight
nix develop --command python3 playground/interface_lab/check.py
```

In Sinal, report these separately:

```sh
nix develop --command gleam format --check src test
nix develop --command gleam check
nix develop --command gleam test
nix flake check
git diff --check
git status --short
```

An intentional focused red command is evidence, not a passing gate. State its
expected diagnostic and observed diagnostic. Do not commit unless the invoking
orchestrator explicitly requests it; never push or publish.

## Later roadmap, not this run

Proceed after review in thin TDD cycles: native fields and emission; native
attach/detach and failure forwarding; scoped lifetime/races; native spans;
package-owned descriptor consumers; fault/concurrency/stress; documentation and
release hardening. Each cycle ports only the upstream cases it needs and records
remaining source coverage. The full design scope remains retained even though
this checkpoint stops early.

## Exact cold start for the external agent

```text
Work in /code/gleam-dream/sinal. Read AGENTS.md and the complete work order at
/code/gleam-dream/oversight/docs/implementation/sinal-blueprint/sinal-work-order.md.
Use the progressive-implementation, lang-gleam, and tdd skills. Follow the
user-approved staged order in the work order even where generic TDD guidance
would normally start with one behavior before a complete signature scaffold.
Use Gleam LSP before edits and the project compiler as the final authority.
Complete only the first external-run checkpoint: baseline, compile-green honest
scaffold, traced telemetry 1.4.2 corpus, and the first focused red cycle (plus at
most its smallest real native green). Preserve user changes. Do not push,
publish, access secrets, broaden the API, or continue into broad implementation.
Stop and return the standard result report.
```

Launch mechanism selected by the user, from the Sinal working directory:
`/opt/homebrew/bin/agy --sandbox --dangerously-skip-permissions --add-dir /code/gleam-dream/oversight --print-timeout 0 --print <literal-prompt>`.
The orchestrator supplies the literal prompt above and does not select a model
here.

## Standard result report

```text
Checkpoint: scaffold / oracle corpus / first red [or first green]
Repository and HEAD:
Files changed:
Public modules and signatures added:
Named todos and why each is honest:
Upstream pin, commit, checksum, license, and baseline command/result:
Oracle rows added and exact normalization:
Compile-green commands/results:
Focused behavior command, expected red reason, actual result:
If green, smallest implementation and evidence it uses native telemetry:
Oversight gate result:
Design mismatches or decisions needed:
Unrelated user changes preserved:
Next smallest TDD slice:
```
