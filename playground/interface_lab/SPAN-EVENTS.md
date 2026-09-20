# Typed span event shapes

## Question

- Can one span descriptor supply distinct typed start, stop, and exception events while composing with ordinary Sinal fields and handlers?
- The experiment constructs event shapes and an ordinary-completion value. It does not run work inside native telemetry, attach handlers, sample clocks, or catch and re-raise exceptions.

## Composition

- A span retains separate start-metadata, extra-stop-measurement, and stop-metadata field sets. Stop metadata does not implicitly inherit start metadata.
- Bidirectional field mapping expresses domain records without exposing nested tuples throughout the event API. Mapping preserves declared labels and codec failures; caller mappings still need their own inverse-law evidence.
- Empty fields represent the absence of application metadata or extra measurements. An empty field set ignores unowned incoming fields, consistent with the existing foreign-observation boundary.
- Each event descriptor carries its own measurement and metadata types. Start handlers, stop metadata, and extra stop measurements cannot substitute for the other event roles.
- Reserved native-owned labels are rejected where their eventual event would use them. This prevents a user field from replacing context, time, or exception fields.
- The logical event prefix introduces no new actor, registry, or arbitrary segment-count restriction. Binding labels to existing BEAM atoms remains native-adapter work.

## Ordinary completion and symbolic evidence

- `Completion` carries an ordinary result plus extra stop measurements and stop metadata. Its result may itself be `Result`; an ordinary `Error` remains on the stop-shaped path.
- Private symbolic stand-ins make the map-layout probe executable without public fake-native constructors. They do not represent real BEAM references, clock units, exception reasons, or stacktraces.
- The consumer checks descriptor construction, reserved labels, record and empty-field composition, and symbolic event shapes.
- This does not prove that a real crash selects the exception event, that the same exception is re-raised, or that native start and terminal events share one context.

## Remaining work

- Implement and compare the native bridge against the pinned telemetry oracle in the [Sinal lifetime contract](../../research/sinal-lifetime-contract.md).
- Exercise scoped attachment with a private registration identity and preserve the distinction between detachment and callback quiescence.
- Verify synchronous caller-process dispatch, foreign interoperability, exception classes and stacktraces, native timing, and cleanup under supported termination paths.
