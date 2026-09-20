# Blueprint compatibility investigation

## Source pins

- The requested baseline is [`json_blueprint` 1.1.0](https://hex.pm/packages/json_blueprint/1.1.0). Its [release archive](https://repo.hex.pm/tarballs/json_blueprint-1.1.0.tar) has SHA-256 `879833acfaf7ef9fac1e90ef78e41e5d3cbb0fa718d63105efc597fe520930bf`.
- The current published release observed on 2026-09-20 is [`json_blueprint` 1.7.1](https://hex.pm/packages/json_blueprint/1.7.1). Its [release archive](https://repo.hex.pm/tarballs/json_blueprint-1.7.1.tar) has SHA-256 `6260f1e9a609a5ec3fbe638745744a3bbbd5fcec37b0792ac7ea631efa4d20d7`.
- Both archives were inspected as source. That initial source pass did not execute either release; the executable result is recorded below. The release archives omit the upstream test directory; a pinned repository checkout is still needed for test reuse.

## Existing compatibility

- Version 1.1.0 requires `gleam_json >= 2.0.0 and < 3.0.0`. Version 1.7.1 requires `gleam_json >= 3.0.0 and < 4.0.0` and `gleam_stdlib >= 0.60.0 and < 2.0.0`.
- In 1.7.1, `src/json/blueprint.gleam` parses through `gleam/dynamic/decode.dynamic`, invokes its vendored function decoder, and translates errors into the current JSON error type. The release therefore already addresses the removed `json.decode` entry point.
- Its public `Decoder(t)` retains a decoder, schema, and schema definitions. Encoding remains a separate operation. This differs from the laboratory's bidirectional `Codec(a)`.
- The [standard decoder documentation](https://gleam-stdlib.hexdocs.pm/1.0.5/gleam/dynamic/decode.html) describes an opaque, composable decoder and an LSP generation action. That decoder alone does not supply an encoder or schema description.

## Questions requiring executable evidence

- The 1.7.1 schema renderer declares Draft 7 while its tuple rendering uses `prefixItems`. A dialect-specific validator must determine the actual accepted language; changing the declaration alone is not a compatibility proof.
- The 1.7.1 `decode0` implementation returns its constructor for every input, while its schema describes a closed empty object. Compare `{}`, a nonempty object, and scalar input through both paths before deciding whether compatibility preserves this behavior or rejects it explicitly.
- Compare unknown fields, missing fields, explicit null, tuple lengths, enum envelopes, and tagged envelopes. Check decoder acceptance separately from encoder roundtrips and schema validation.
- The laboratory uses a finite schema vocabulary. Existing recursive decoders and references cannot be represented as supported migration paths merely because primitive records can be adapted.

## Bounded experiment contract

- Run a pinned upstream release beside one native laboratory record, one empty variant, and one tagged value. Retain original wire names and payload shapes.
- Supply an explicit encoder when adapting an existing decoder into a bidirectional contract. Reject unsupported schema conversion rather than attaching a guessed schema.
- Exercise existing runtime construction separately from generated native source. Source generation must produce the same codec contract; it must not introduce a second set of validation semantics.
- Record source compatibility, wire compatibility, and corrected schema behavior as separate results. A deliberate bug fix may preserve the intended contract while changing historical acceptance.
- Prefer evaluating an update to the existing package before creating a successor. Package replacement remains undecided until the compatibility experiment establishes which public breaks are necessary.

## Evidence boundary

- The source investigation alone establishes differences and a falsifiable experiment. The later executable result establishes only its named cases; complete migration, Draft 7 conformance, and upstream behavioral parity remain unproven.
- The [coverage inventory](../API-COVERAGE.md) keeps 1.x compatibility, number policy, broader enums, recursive schemas, and generation tooling unfinished.

## Executed compatibility result

- The [compatibility playground](../playground/blueprint_compatibility/README.md) now runs both published releases through their pinned dependencies. Its gate and lockfiles provide the executable evidence beyond the source investigation above.
- The 1.7.1 adapter requires an explicit encoder and reports an unknown schema. A separate 1.1.0 project checks historical decoding directly with its compatible dependency versions.
- Empty-constructor acceptance differs between the releases: 1.1.0 rejects the tested nonempty object, scalar, and null inputs; 1.7.1 accepts them. The 1.7.1 emitted empty-object schema rejects those inputs under Draft 7 validation.
- The actual 1.7.1 tuple schema accepts swapped element types under its declared Draft 7 dialect, while its decoder rejects them. A future schema correction must account for this observable difference.
- Prefer refining the existing package with explicit compatibility boundaries. This experiment does not establish a drop-in bidirectional API or decide the full migration and release strategy.
