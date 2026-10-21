# Retire interface probes covered by production packages

<a id="adr-0030"></a>

## Decision

- Remove the duplicate schema corpus and the unreferenced workflow and checkpoint examples from the interface laboratory.
- Move the independent exact-number oracle to JSON Blueprint, where it executes the public number API. Preserve its 62 Erlang cases and the both-target refusal to use an exact Number as a native Float. Retire the prototype's separate projection-limit type proposal.
- Preserve telemetry assertions in the owning production tests, then remove the laboratory's Sinal implementation, adapters, consumers and associated compiler negatives. Keep the scripted Erlang backend still used by job and activity probes.
- Keep the remaining laboratory, including native enum generation and cross-owner child compensation, as scoped experiments. Production coverage for a different contract does not supersede those questions.

## Alternatives and consequences

- The 61 schema-corpus cases have exact production counterparts, including inputs, emitted and normalized schemas, decoder outcomes and runtime acceptance. JSON Blueprint's independent schema validator owns that evidence.
- Compiling examples that call unfinished runtime functions does not validate workflow execution. The retired checkpoint and workflow examples have no callers; retained production Saga and application tests exercise actual recovery and cancellation.
- The independent numerical calculation remains useful even though expected values were already ported to unit tests. Moving it preserves that independent check while removing a second numerical implementation.
- Sinal's native tests preserve stale-handle detachment and the complete exception triple across cleanup. Fabric tests observe a dispatched tool's host failure; Saga tests observe numeric undo-failure counts for success, failure and cancellation. Existing production tests retain failure isolation, cancellation and cross-package correlation.
- Historical event names, field layouts and rejectable-emitter return types were proposals for the sketches, not compatibility contracts of the production packages. Each package owns its actual event contract; no old event or API is reintroduced to retain a prototype test.
- This narrows [ADR 0009](0009-retain-executable-evidence-with-scoped-claims.md#adr-0009): useful evidence belongs with the implementation it validates. Superseded sketches remain available in Git history.

## Provenance

- The [laboratory before retirement](https://github.com/gleam-dream/oversight/tree/ae000e0/playground/interface_lab) records the original inputs and assertions.
- Production owners are [JSON Blueprint](https://github.com/lostbean/json_blueprint/tree/main/test), [Sinal](https://github.com/gleam-dream/sinal/tree/main/test), [Fabric](https://github.com/gleam-dream/fabric/tree/main/test/fabric), [Saga](https://github.com/gleam-dream/saga/tree/main/test) and [Grind](https://github.com/gleam-dream/grind/tree/main/test/grind/observations).
