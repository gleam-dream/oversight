# Build generated codecs with warnings as errors

Status: done
Category: enhancement

AI-assisted contribution.

## Problem

JSON Blueprint 2.1.1's typed generator ends each enum encoder with
`_ -> generated.unknown_enum_value()`, which an enum that names every
constructor makes unreachable. The extractor's generated job payload codec
therefore compiles with two `Unreachable pattern` warnings, and
`scripts/test-applications.sh` accepts exactly that warning in modules under
`src/**/generated/` while failing on any other.

## Blocked on

A JSON Blueprint release with the guarded enum arms of
lostbean/json_blueprint#7, which keeps the catch-all and guards the other
arms so the module compiles without warnings whether or not every
constructor is named.

## What to do

- Raise the extractor's `json_blueprint` floor to that release and
  reconcile its manifest through Gleam.
- Regenerate with `gleam run -m generate_codecs` and
  `gleam format src/extractor/generated`.
- Replace `strict_build` in `scripts/test-applications.sh` with
  `gleam build --warnings-as-errors` again.

## Done when

The application gate builds every application with `--warnings-as-errors`
and the extractor's generated module compiles without warnings.

## Comments

AI-assisted contribution. Done in the change that raised every application to
JSON Blueprint 2.2.0, whose typed generator guards its enum arms. The extractor's
module was regenerated, it compiles without warnings, and
`scripts/test-applications.sh` builds with `gleam build --warnings-as-errors`
again.
