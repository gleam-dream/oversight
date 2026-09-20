# Generated finite enum fields

## Question

- Can runtime schemas generate native finite enum fields while retaining the same accepted wire language and independent application compilation?
- This experiment extends the existing finite root-object generator. It does not add a second codec implementation.

## Representation

- Each enum field receives its own generated native type, `FieldNEnum`, with positional constructors such as `FieldNValueM`. Required fields use the enum directly; nullable and optional fields preserve the existing `blueprint.Nullable` and `blueprint.Optional` wrappers.
- Generated `string_enum` tables map every normalized wire label to exactly one constructor. Equivalent schemas with reordered properties or labels produce the same source.
- Labels remain data and are escaped as string literals. Empty strings, keyword text, quotes, newlines, backslashes, and Unicode do not become source identifiers.
- Type and constructor names follow normalized positional indices, consistent with the generated record fields. Adding an earlier property or label can rename later generated declarations; stable names across schema revisions remain open.
- Equal label sets in separate fields still produce distinct native types. Reuse requires an explicit named definition or reference contract rather than inference from equal labels.

## Evidence

- The generation corpus compiles and runs sixteen downstream modules without importing the generator. Four compiler-negative cases reject runtime values in native type slots, runtime contracts as codecs, unrestricted strings as enum fields, and one generated field's enum as another field's type.
- The schema-generation consumer confirms normalized input ordering produces deterministic source and checks the exact generated declarations and codec wiring.
- The generated consumer constructs and round-trips every constructor against its wire label. It covers required, nullable, and optional fields, a singleton empty-string enum, unknown and nonstring labels, missing required properties, and invalid nulls.
- Awkward labels include an empty string, keyword text, quotes, a newline, a backslash, and Unicode. They remain exact wire data in generated source.

## Remaining scope

- Stable user-selected names, shared named definitions, recursive schemas, aliases, nested objects, collections, numeric enums, and broader published Blueprint migration remain separate experiments.
