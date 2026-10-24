# Treat a legacy decoder's accepted values separately from its emitted schema

<a id="adr-0025"></a>

## Decision

- The repository retains a compatibility experiment that adapts a published JSON Blueprint decoder into the laboratory codec boundary. The adapter takes the upstream decoder and an explicit native encoder for the same type.
- The adapted codec carries no schema description, so permissive legacy acceptance does not inherit an unverified closed-object schema.
- Schema validation is checked independently with a separate validator.

## Rationale and alternatives

- A decoder construction cannot supply its inverse, so encoding stays caller-owned.
- Findings against published releases 1.7.1 and 1.1.0: the record decoder accepts extra fields; the empty-constructor decoder accepts any object, scalar and null in 1.7.1 and rejects them in 1.1.0; independent Draft 7 validation rejects values the 1.7.1 decoder accepts; the tuple decoder rejects swapped element types while its emitted Draft 7 schema accepts them because the dialect lacks positional items. An upstream Draft 7 schema cannot enter the laboratory's Draft 2020-12 loader by association with a typed decoder.

## Consequences

- The experiment is a migration probe and not a production adapter. Floating-point values, recursive schemas, general schema conversion, resource bounds and error-path parity stay outside its corpus.
- The package that owns JSON Blueprint holds the compatibility contract and its migration guidance.
