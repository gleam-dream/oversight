# clinic_registration

[![CI](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

Patient registration from a conversation, built on the `decisions` decision
point with `decisions_postgres`, `decisions_otp`, LLM Wire, Grind, Wisp and
Sinal on PostgreSQL. A message from a contact on a messaging channel is the
trigger. A single LLM call with structured output recommends a patient
record; a stored, versioned policy proceeds or asks reception or the
manager; a receptionist approves, rejects or corrects the record through a
JSON desk API; the patient row is inserted exactly once by the gated tool;
a Grind job sends the contact a confirmation under the release key; and the
manager reviews the registrations policy version 2 let proceed and sampled. The
LLM provider and the messaging provider are scripted servers on loopback.

The desk identifies the validator from one header,
`x-clinic-validator: <name>; <set>,<set>`, read by `web.authenticate`. It
stands in for identity in this example: a real application puts its own
sign-in there and resolves the decision sets a person holds from it.

`decisions`, `decisions_otp` and `decisions_postgres` are unpublished. They
resolve through the path `../../../../decisions` from this directory
([ADR 0034](../../docs/adr/0034-consume-the-decisions-packages-by-path-until-published.md)).

## Run

From this directory, inside the Oversight shell:

```sh
../scripts/with-postgres.sh gleam test
../scripts/with-postgres.sh gleam run
```

`gleam run` delivers Ana's message twice through the webhook, prints the
card as Felipe sees it at reception, corrects the birth date, and prints the
patient row, the confirmation Ana receives, the occurrence's record and the
telemetry. Each test creates its own database in the disposable cluster.

The [composition contract](../../docs/design/design-layer.pdf) describes the
registration, its desk and its confirmation.
