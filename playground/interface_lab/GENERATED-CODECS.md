# Native codecs from finite schema documents

## Question

- Can a runtime schema document produce source that compiles into a native Gleam record with a codec for the same contract?
- Loading a schema at runtime still produces only a runtime contract. Generation produces source; compiling that source creates the native type.

## Supported profile

- The root is a closed object. Its properties may contain text, integers, booleans, bounded integers, and recursively nullable values. Required and optional properties retain distinct native representations.
- The generated module exposes `Document` and `codec()`. Empty objects produce a nullary `Document` constructor.
- Normalized property order determines `field_0`, `field_1`, and later labels. These labels and the fixed module name are experimental conventions. They are not a settled naming or source-compatibility policy.
- Property names remain escaped string literals. Keywords, punctuation, controls, Unicode, and source-like text never become identifiers.
- Valid runtime schemas outside this generation profile return a located unsupported-generation error. They do not silently lose constraints.
- Generated codecs compose the ordinary Blueprint constructors and `imap`. Bounded integers therefore retain fallible encoding when a native `Int` is out of range.

## Evidence

- The pure consumer checks deterministic output after property reordering and located rejection of lists, nested objects, tuples, tagged alternatives, and unsupported shapes beneath nullable values.
- The generator corpus loads rendered schema documents before generating source. Fourteen emitted modules compile and execute separately authored native consumers in temporary projects.
- The downstream dependency closure explicitly rejects generator imports. Generated applications need the codec implementation, not the generator.
- Native consumers check missing versus null, nested nullable values, bounded encoding and decoding, wrong types, missing required fields, unknown fields, and empty objects.
- Eleven property-name cases check exact wire-name preservation. Expected names and schemas enter the test through independently encoded UTF-8 byte literals, rather than the generator's escaping function.
- Every generated codec's normalized schema equals the loaded source contract. Two compiler-negative cases reject a runtime validated value as a native record and a runtime contract as a native codec.

## Remaining work

- Choose application-facing module, record, and field naming, including stability when schemas evolve.
- Extend the supported generation profile only with matching native consumers and schema-agreement checks.
- Add a command-line workflow, committed-output policy, formatting, resource bounds, and compatibility fixtures for the existing JSON Blueprint 1.x API.
- Establish independent package builds and distribution boundaries. The temporary projects copy reachable laboratory modules; they are not published-package integration tests.
- General JSON Schema syntax, recursive references, byte parsing, and schema migration remain outside this finite experiment.
