# Composable object properties

## Question

- Can independently reusable property groups form a typed record that serves both decoding and tool discovery, while distinguishing absence from explicit null?

## Result

- `Properties(a)` retains typed encoding, decoding, declared names, and supported schemas.
- `required` and `optional` create one property. `combine` rejects overlapping names and preserves both native types in a pair.
- `object` closes the assembled property set and validates unknown and duplicate raw keys before decoding properties. Input key order does not matter.
- `empty` supports zero-argument tools. `imap` maps the finished object codec into a domain record.
- `Optional` distinguishes `Missing` from `Present`. Combining it with `Nullable` represents absence, explicit null, and a present non-null value separately.
- Relay derives a general object declaration from the same codec that invokes the tool.
- Arbitrary inner codecs preserve `UnknownSchema`, including when their property is optional.

## Evidence

- `object_codec` covers reordered input, missing/null/value cases, omitted output fields, duplicate declarations, duplicate raw keys, unknown keys, required fields, empty objects, unknown nested schemas, and Relay invocation.
- `missing_is_not_null` fails compilation because nullable values do not substitute for optional properties.
- [JSON Schema object guidance](https://json-schema.org/understanding-json-schema/reference/object) informs the emitted properties, required names, and closed-object declaration. An independent validator has not yet checked the generated schemas.

## Compatibility and limits

- `field` delegates actual encoding and decoding to the general object implementation. Its legacy `FieldSchema` description remains supported alongside `ObjectSchema`.
- Non-object input to `field` now reports a root decoding error. The old implementation wrapped that failure in a field location.
- Duplicate raw keys are rejected by the laboratory decoder. JSON parser duplicate-key behavior still needs a separate boundary policy.
- Tagged unions, constrained values, runtime-loaded schemas, recursive schemas, and code generation remain subsequent experiments.
- These combinators do not prove caller-supplied mapping laws or production performance.
