# Preserve caller-owned values and decisions

<a id="adr-0002"></a>

## Decision

- Libraries accept native application values and typed failures. A nominal library value is justified by admission, identity, or ownership guarantees, not by a desire for identical records across packages.
- Definitions own their names and codecs. Callers do not reconstruct information already bound to a definition.
- Caller-built configuration uses opaque constructors and composable settings where it must grow without exposing construction details. Returned information remains inspectable through labelled fields or focused public accessors.
- Extensions vary declared behavior while retaining the library's shared admission and resource guarantees.

## Context and alternatives

- Earlier guidelines recommended public records for straightforward configuration. Subsequent public API work adopted opaque configuration across the packages to preserve defaults, validation, and evolution without positional constructor coupling.
- A universal configuration, failure, codec, or execution framework would merge values whose meanings differ. Mechanical consistency alone does not justify such a boundary.
- A family of wrappers that merely renames existing types would add conversions without relocating meaningful responsibility.

## Consequences

- A public accessor is appropriate when a consumer needs information the library owns. A new switch is justified only by a distinct caller decision.
- Runtime definitions retain a typed admission path. Programmer mistakes in static definitions follow the package's explicit check/failure contract, addressed in ADR 0007.
- API acceptance needs separate consumers exercising ordinary use, advanced configuration, caller types, and recovery. A compiling library-internal example is insufficient evidence of accessibility.

## Provenance

- This reconstructs the implemented convention rather than attributing a new API decision to this cleanup.
- Sources: the [original guidelines](https://github.com/gleam-dream/oversight/blob/3baff70/PUBLIC-API-GUIDELINES.md), [release review conventions](https://github.com/gleam-dream/oversight/blob/3baff70/docs/release-api/README.md), and public consumers in the package checkouts.
- The precise original acceptance date of every configuration conversion is not established here. Each package ADR records its own implementation references.
