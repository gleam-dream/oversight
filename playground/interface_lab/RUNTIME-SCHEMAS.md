# Runtime schema values

## Question

- Can a runtime-selected finite schema validate values and preserve a reusable acceptance witness without manufacturing a native Gleam type?
- The experiment starts from Blueprint's existing schema algebra. Loading a JSON Schema document and generating Gleam source remain separate boundaries.

## Contract

- `RuntimeContract` retains a validated, normalized schema. Construction rejects duplicate schema properties, duplicate tags, and reversed integer bounds.
- Normalization converts a single-field schema into a required object property and orders object properties and complete tagged alternatives deterministically. It preserves tuple order, requiredness, bounds, and nested nullable structure.
- `ValidatedValue` retains its accepted immutable wire value and normalized schema. Retrieving the encoded value does not grant a native application type.
- Contracts reconstructed from equal normalized structures match existing witnesses. This is exact structural matching, not schema subtyping or general semantic equivalence.
- A static codec can supply a runtime contract through its retained schema. A custom codec with no schema cannot.
- A matching schema does not prove that caller-supplied codec mappings obey their laws. Recovering a native value still requires decoding through an existing `Codec(a)`.

## Validation

- Optional properties may be absent; present properties must validate. Nullable properties accept null independently of requiredness.
- Objects reject duplicate and unknown keys. Tagged values retain their closed tag-and-payload representation.
- Failures carry typed logical paths and reasons for consumers such as forms and graph editors. Tagged payload paths include the value property followed by a tagged-branch marker; they are not JSON pointers.
- The independent schema corpus compares static decoding, runtime validation, and validation of original and normalized schema documents.

## Remaining work

- Add strict document loading with explicit unsupported-keyword failures and limits.
- Generate and compile native types and codecs during development, then compare their schemas with runtime-loaded contracts.
- Use runtime contracts in external declarations and a runtime-authoring surface for Saga. Test whether that surface can share the canonical workflow execution model.
- Establish numeric normalization, recursive-schema policy, hostile-input limits, performance, migration, and a broader oracle corpus before treating this as a production validator.
