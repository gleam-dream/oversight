# Email portal

[![CI](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

A separately compiled application that composes Correio delivery, development
mailbox inspection, intentional verification and application-owned session
publication. `AccountId`, `Principal` and the opaque `Session` are
application-native types; an email-verified principal does not claim Hellhound OIDC
evidence.

## Run

From Oversight's root:

```sh
nix develop -c sh -c 'cd apps/email_portal && gleam test && gleam run'
```

The executable owns a bounded memory store and capture, prints one result line
without authentication secrets, and needs no database, credentials, HTTP listener or
live mail provider.

The [composition contract](../../docs/design/design-layer.pdf)
describes the flow, policy and limits.
