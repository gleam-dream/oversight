# Blueprint schema materialization review

**Recommendation:** accept the experiment as evidence for the narrow test/dev
materialization question. It does not promote a public generator API or change
the Wave 4 release surface.

The implementation derives each heterogeneous `Codec(a)` separately through
`codec.schema`, then stores only the accessor name and existing `codec.Schema`.
No native values pass through `Dynamic`. The emitter reconstructs every current
schema constructor except `NumberRangeSchema`; that constructor returns a typed
`UnsupportedConstructor` with its exact tree path instead of inspecting opaque
`Number` bounds or introducing a runtime parser.

The generated module is independent source. It imports only
`json/blueprint/codec`, exports `order_schema` and `decision_schema`, and has no
emitter, runner, dynamic, or runtime-generator dependency. Its accessors build
the existing public `codec.Schema` representation. The experiment correctly
states that `codec.schema(codec)` already retrieves a cached field in O(1), and
that generated accessors still evaluate and allocate schema values when called.

The initial review found that public `SchemaExport` construction could bypass
`from_codec` validation and that the reserved word `else` was missing. The final
boundary now revalidates every accessor before duplicate checking or source
emission, rejects direct injection and malformed-name constructions, and rejects
`else` for both accessors and module segments. Module paths remain relative,
slash-separated lowercase identifiers, so unchecked names cannot reach source
or filesystem paths.

Escaping and structural fidelity are exercised with quotes, backslashes,
newline, carriage return, form feed, tab, Unicode, keyword text, and source-like
text in property names, enum labels, and union tags. The independently compiled
fixture rebuilds the two heterogeneous runtime codecs and compares each
generated accessor directly with `codec.schema(runtime_codec)`. This is
structural equality against live cached schemas rather than a second hard-coded
expected tree.

Determinism evidence emits identical inputs twice and also reverses the caller
export order. Both yield the same path and source bytes under the declared
alphabetical-accessor rule. `UnknownSchema`, duplicate accessors, malformed and
reserved names, invalid module paths, and root and nested number ranges have
typed negative evidence.

Independent validation passed:

- `gleam format --check src test`
- `gleam check`
- `gleam test --target erlang`: 110 passed
- `gleam test --target javascript`: 110 passed
- clean removal and regeneration of `build/schema-materialization/`
- generated fixture `gleam check`
- generated fixture Erlang tests: 2 passed
- generated fixture JavaScript tests: 2 passed
- `git diff --check`

All package changes are test-only; `src/` is unchanged from
`8f2d46c5a4174a3700e0f214e37e612b0c65316a`. The generated fixture remains an
ignored, reproducible artifact. This review does not establish automatic CI
integration, stale tracked-artifact detection, compile-time constants, native
type or codec generation, recursive reference support, a CLI, browser support,
publication, or a production API.
