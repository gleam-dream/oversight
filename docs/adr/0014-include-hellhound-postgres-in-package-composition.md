# Include Hellhound's PostgreSQL adapter in package composition

<a id="adr-0014"></a>

## Decision

The ecosystem contains nine core libraries and three optional PostgreSQL adapters:
`saga_postgres`, `fabric_postgres` and `hellhound_postgres`. Each adapter remains owned
by its package repository and borrows application-owned database resources.

This supersedes the package count and adapter inventory in
[ADR 0003](0003-use-core-ports-and-compiled-recipes.md#adr-0003). Its decision to use
public ports and compiled recipes for small cross-package translations remains.

## Rationale and consequences

Hellhound's adapter implements conditional sealed-record persistence, schema
compatibility and protected deadline decisions. These database obligations justify
an optional package under the same rule as Saga's and Fabric's adapters. Keeping
it separate preserves Hellhound core's independence from PostgreSQL.

The application owns pool lifetime, sealing keys and deployment policy. Hellhound
owns the record and authentication contracts; Oversight records their composition
boundary without duplicating the adapter's detailed design or claiming production
qualification.

## Provenance

Accepted during the ecosystem contribution review on 13 October 2026, following
[Hellhound PR 2](https://github.com/gleam-dream/hellhound/pull/2).
