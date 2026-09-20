# Injected observation backend

## Question

- Can independent producers and subscribers share typed event descriptors while a configured backend owns registration and emission?
- This experiment uses logical field maps and scripted callbacks. It does not implement the native telemetry bridge.

## Configured boundary

- One backend supplies emission and attachment callbacks. Application configuration stays in ordinary closures.
- Emission encodes measurements and metadata before calling the backend. Its result does not carry subscriber-specific handler errors.
- Attachment rejects duplicate event names before registration. A selected callback resolves the exact retained descriptor before decoding and invoking its handler.
- A declared callback failure invokes the typed failure observer and returns a closed failure disposition to the backend. The backend owns removal policy.
- An attachment retains its originating detach callback. Detachment needs no replacement backend argument.

## Lifetime limits

- A callback selected before detachment may run afterward. Detachment does not establish callback quiescence.
- Copied attachments retain the same backend operation. Repeated detachment follows that backend's documented result.
- Native telemetry removes registrations by identifier. Reusing an identifier does not grant an older attachment a generation-safe removal guarantee.
- An independently keyed process-local test registry exposes selection and removal causality. A small Erlang test helper stores its records; it does not implement telemetry or establish concurrent registry behavior.

## Consumer evidence

- Independent producer and subscriber functions reuse one descriptor through the public backend.
- Invalid encoding reaches no backend callback; malformed incoming fields reach no typed handler.
- Late delivery, repeated detachment, identifier replacement, callback failure isolation, and independence between configured backends have explicit outcomes.
- Compiler negatives reject incompatible measurements, metadata, and an event used as an attachment.

## Remaining scope

- Scoped exception cleanup, native span execution, atom and map conversion, synchronous emitter process behavior, and upstream handler failure events require the [pinned native oracle](../../research/sinal-lifetime-contract.md).
- Ordinary span work returning `Result.Error` remains normal completion. It does not become a handler failure or a BEAM exception.
- The source-isolated consumer and compiler negatives pass. The executable probe uses the explicit test helper; it does not claim native telemetry behavior.
