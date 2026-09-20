<!-- THROWAWAY: Can one typed handler distinguish several event descriptors without owning application configuration? -->

# Descriptor-aware observation

## Callback boundary

- A handler receives the exact typed event descriptor used to decode its measurements and metadata.
- `event_name` exposes the logical name without comparing decoder closures or claiming a native atom binding.
- Application configuration remains ordinary data captured by the handler closure.
- Measurement and metadata failures return before the handler runs. A declared handler error remains distinct from those decode failures.
- The attachment failure callback accepts the selected descriptor and its typed failure. Native invocation of that callback remains unimplemented.

## Attachment admission

- `attach_many` takes one first event and a list of further events. The type parameters require one shared measurement shape and one shared metadata shape.
- `validate_event_names` rejects repeated logical names, including same-shaped descriptors with different codecs.
- A native event name cannot disambiguate those codecs, so both global and scoped attachment validate the set before reaching their runtime boundary.
- `attach` delegates the single-event case to the same global attachment path.
- Logical names remain lists of strings. The native adapter must bind distinct names injectively to trusted existing atoms.

## Scoped signature

- `with_attachments` accepts no caller-owned handler identifier and returns no attachment handle.
- The work callback retains its ordinary result type. A work result of `Result(value, error)` therefore appears inside the separate attachment result.
- The future runtime implementation must allocate a private identifier and detach on ordinary return or catchable failure.
- The signature does not prove identifier freshness, cleanup, or preservation of a thrown exception.
- Scope exit does not establish that a callback already selected by another emitter has finished.

## Evidence

- The consumer delivers two same-shaped descriptors through one configured handler and checks which descriptor arrived.
- Application metadata, extra foreign fields, malformed inputs, and a declared handler error exercise the existing field boundary.
- Duplicate-name cases use different descriptors and codecs to test ambiguous admission.
- Global and scoped attachment examples compile without executing their runtime paths.
- Compiler-negative fixtures reject mixed measurement and metadata shapes while preserving the existing span-handler distinctions.

## Remaining obligations

- This wave implements pure delivery and admission, not a handler registry or cleanup runtime.
- The pinned telemetry oracle must establish synchronous emission, callback failure reporting, duplicate identifiers, repeated detach, scoped cleanup, and callbacks still running across detachment.
- Captured application data may appear in native handler configuration and failure observations. The FFI must establish its exposure before making any confidentiality claim.
- The [Sinal lifetime contract](../../research/sinal-lifetime-contract.md) retains those obligations and the span-runtime work.
