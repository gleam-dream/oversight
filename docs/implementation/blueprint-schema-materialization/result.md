# Schema materialization experiment record

- Status: complete and [accepted by Sol Medium](review.md) as a test/dev experiment.
- Accepted package commit: `cbbea2683dd9bfc020cf236a3569d387957fc53d`.
- Work order: [work-order.md](work-order.md).
- Package baseline: `8f2d46c5a4174a3700e0f214e37e612b0c65316a` on
  `implementation/schema-aware-core` in `/code/gleam-dream/json_blueprint`.
- External session: `99819`, using the requested sandbox flags and configured
  default model without an override.
- Output: `/private/tmp/gleam-dream-blueprint-materialization.log` and
  `/private/tmp/gleam-dream-blueprint-materialization.stderr`.
- Question: can two heterogeneous codecs materialize their existing Schema
  values into deterministic, independently compilable Gleam source with exact
  structural equality and no runtime generator dependency?
- Answer: yes. Two heterogeneous codecs yield deterministic Gleam accessors
  returning the existing Schema type, with exact structural equality against
  the schemas retrieved from those codecs.
- Independent evidence: 110 package tests pass on each target; clean fixture
  regeneration and compilation pass; two generated-schema equality tests pass
  on Erlang and JavaScript. Final-boundary name validation, reserved words,
  injection attempts, adversarial string controls, UnknownSchema and located
  unsupported-number-range errors are exercised.
- Scope: test/dev experiment; no promoted public generation API, no native
  domain types generated from external schemas, and no change to runtime codecs.

## Reproduce

From `/code/gleam-dream/json_blueprint`, remove only the ignored experiment
output directory for a clean run, then execute:

```sh
nix develop --command gleam run -m schema_materialization_runner
nix develop --command sh -c 'cd build/schema-materialization/fixture && gleam check && gleam test && gleam test --target javascript'
```

The generated module is
`build/schema-materialization/fixture/src/generated/schema_catalog.gleam`.
It imports only `json/blueprint/codec`, not the emitter or runner. Generated
artifacts remain ignored; the emitter, source fixtures and tests are committed.

## Interpretation and limits

- `codec.schema` already reads a cached Result. Materialization avoids creating
  application codecs and closures for schema-only consumers; it does not remove
  a traversal from the existing accessor.
- Generated accessors may allocate Schema trees. This is ordinary build-time
  execution and source generation, not compiler evaluation or a performance
  measurement.
- `NumberRangeSchema` remains a located unsupported result because its Number
  bounds are opaque. Unbounded NumberSchema is supported.
- Repeat-byte equality proves determinism. Clean regeneration proves the fixture
  can be rebuilt; no automatic CI integration or ignored-artifact staleness
  detection was added or claimed.
- External-schema-to-domain-types/codecs generation and recursion remain
  deferred. The experiment does not promote a stable public generation API.
