# Blueprint compatibility playground

## Question

- Can an existing JSON Blueprint decoder participate in the new codec boundary while preserving its wire format and exposing the limits of its schema?
- The experiment uses published upstream code in a separate Gleam project. Its dependencies do not enter the main interface laboratory.
- Source versions are pinned in the two manifests. The [JSON Blueprint design](../../../json_blueprint/docs/design/design.typ) owns the current compatibility contract; its ADRs retain the architectural rationale.

## Run the experiment

- From the repository root, run `nix develop --command python3 playground/blueprint_compatibility/scripts/check.py`.
- The lockfiles pin JSON Blueprint 1.7.1 with JSON 3.1.0 and stdlib 1.0.5, and a separate JSON Blueprint 1.1.0 project with JSON 2.3.0 and stdlib 0.51.0.
- The gate checks the upstream release checksums, runs both projects, validates actual emitted schemas independently, and requires each of two compiler negatives to fail with one intended diagnostic.

## Adapter contract

- `adapt` takes an upstream `Decoder(a)` and an explicit native encoder for the same `a`. It returns the laboratory's existing `Codec(a)` through `blueprint.new`.
- Decoding delegates to the actual upstream decoder. Encoding remains caller-owned; decoder construction cannot supply the inverse function automatically.
- The supplied message encoder preserves the legacy `type` and `data` envelope; the generic adapter imposes no envelope. The laboratory's `tag` and `value` envelope is a different wire contract.
- Both directions reject duplicate object keys in the laboratory value representation before JSON rendering. Numeric support remains limited to the laboratory's integer vocabulary.
- The adapted codec has no schema description. This prevents permissive legacy acceptance from inheriting an unverified closed-object schema.
- Legacy decode failures currently map to one adapter error. Detailed error-path compatibility remains untested.

## Acceptance findings

- The 1.7.1 record decoder accepts extra fields. Its adapted decoder preserves that behavior; missing or wrongly typed required fields remain failures.
- The 1.7.1 empty-constructor decoder accepts empty and nonempty objects, scalar input, and null. The adapter preserves that decoder behavior deliberately.
- The separately executed 1.1.0 empty-constructor decoder rejects nonempty objects, scalar input, and null. Updating the package therefore changes acceptance for these cases.
- Independent Draft 7 validation rejects the nonempty, scalar, and null empty-constructor examples accepted by 1.7.1. The tuple decoder rejects swapped element types, while its emitted Draft 7 schema accepts them because `prefixItems` belongs to a later dialect.
- Explicit encoders round-trip the exercised native constructors through the legacy decoder. These examples do not prove inverse laws for arbitrary supplied encoders.
- The upstream Draft 7 schema cannot enter the laboratory's Draft 2020-12 loader merely by being associated with a typed decoder. Dialect conversion remains a separate unsupported operation.

## Using the findings

A bidirectional codec needs an explicit encoder as well as a decoder. Schema
validation must be checked independently: a schema associated with a decoder
does not by itself describe every value that decoder accepts.

The 1.1.0 and 1.7.1 fixtures pin their respective acceptance behavior. Consult the
[package migration guide](../../../json_blueprint/docs/migration-2.0.md) for compatibility and upgrade details.

## Evidence boundaries

- This is a migration experiment, not a production adapter or a complete 1.x migration guarantee.
- Floating-point values, recursive schemas, general schema conversion, generation integration, resource bounds, and complete error-path parity remain outside this corpus.
- A source-copy script imports the current laboratory modules when checking this project. Generated copies and fetched dependency output are excluded from version control.
