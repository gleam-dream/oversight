# Collection and null codecs

## Question

- Can a consumer compose a closed field, a list, and explicit nullable values while retaining its native type, schema description, and error location?

## Result

- `list(codec)` retains the element codec and reports the failing element index.
- `nullable(codec)` uses `Null` and `NonNull(value)` as distinct native cases.
- A `NonNull` value that encodes to JSON null is rejected because decoding that wire value returns `Null`.
- Supported schemas compose into array items and a null-or-inner union. An unknown inner schema remains unknown.
- The consumer checks empty collections, nested field/index failures, encoded schema structure, and nested nullable ambiguity.

## Limits

- These checks use the laboratory Value algebra. They do not exercise a JSON parser or an independent JSON Schema validator.
- Missing object properties need a separate optional-property contract. Null is a present wire value.
- Recursive collection helpers establish interface behavior only. Stack usage and throughput remain unmeasured.
