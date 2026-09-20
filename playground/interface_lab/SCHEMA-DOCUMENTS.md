# Finite schema documents

## Question

- Can an external schema document enter Blueprint's runtime-validation boundary without silently losing constraints?
- The loader accepts an already parsed `Value`. JSON byte parsing, numeric normalization, and preservation of duplicate keys before that boundary remain separate work.

## Accepted language

- The first profile accepts the finite Draft 2020-12 forms rendered by Blueprint: primitives, bounded integers, closed objects, lists, exact pairs, nullable alternatives, and tagged alternatives.
- The root document must declare the selected dialect. Nested dialect declarations and unsupported keywords return explicit errors.
- Object requiredness, tuple cardinality, closed-object policy, tags, bounds, and nullable alternatives remain constraints. The loader does not discard a constraint to make a document fit the supported subset.
- Property names remain data. They are not interpreted as schema keywords or Gleam identifiers.
- Parsed schema objects reject duplicate keys before interpreting their fields. Malformed supported syntax, unsupported forms, dialect failures, and schema-invariant failures remain distinguishable and located.

## Composition

- Loading produces a `RuntimeContract` through the existing invariant and normalization boundary.
- A loaded document can validate wire values and match a codec-derived normalized contract. It cannot produce a new native Gleam type.
- The schema corpus reloads actual emitted documents rather than hand-copying an expected schema. Its independent validator still checks representative wire acceptance.
- Source generation is a separate development-time step. A valid runtime contract may be unsupported by a particular generation profile.

## Remaining work

- Add byte parsing with explicit duplicate-key, Unicode, numeric, and size policies.
- Generate and compile one native record and codec from a loaded document.
- Expand supported forms only with located rejection behavior and independent schema-agreement evidence.
- Establish resource limits, recursive-reference policy, migration, and performance before treating the loader as a production JSON Schema implementation.
