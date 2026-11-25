# clinic_registration

[![CI](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

Patient registration from a conversation, built on the `decisions` decision
point with `decisions_postgres`, `decisions_otp`, LLM Wire, Grind, Wisp and
Sinal on PostgreSQL. A message from a contact on a messaging channel is the
trigger. The transaction that admits it supersedes what the contact's earlier
messages started and records that a recommendation is expected for this
message, so a model call for an older message that finishes later writes
nothing ([ADR 0037](../../docs/adr/0037-expect-recommendations-at-admission-and-key-payouts-by-request.md)).
The library serialises admissions about one contact; an admission that waits
too long for another is answered `503 try_again`, and the channel delivers it
again. A single LLM call with structured output recommends a patient record.

A stored, versioned policy decides what happens next. Version 1 asks
reception. Version 2 lets a sure registration proceed after a ten-minute undo
window, during which reception may take it back
(`POST /cards/:id/withdraw`) and a newer message supersedes it; it asks the
manager about a possible duplicate and reception about anything else. A
receptionist approves, rejects or corrects a record through a JSON desk API.
The gated tool inserts the patient row exactly once, and a Grind job sends the
contact a confirmation under the release key. The manager reviews the sampled
registrations that version 2 let proceed. `GET /pending` lists the messages
still waiting for a recommendation, and since when. The LLM provider and the
messaging provider are scripted servers on loopback.

Nothing a request says about its sender is taken as identity
(`clinic_registration/access`). A desk request carries
`Authorization: Bearer <token>`, and the application's configured staff table
resolves the token to a validator and the decision sets that validator holds. A
webhook delivery carries `x-channel-signature: sha256=<hex>`, the HMAC-SHA256 of
its body under the secret the clinic shares with the channel, checked before the
body is parsed. Both are unset by default, and unset means closed: with no staff
every desk route answers 401, and with no channel secret so does the webhook.
The staff table stands in for the clinic's sign-in: an application with one
verifies its session or access token in `access.authenticate` and looks the
decision sets up by the verified subject.

`decisions` resolves from Hex. `decisions_otp` and `decisions_postgres` resolve
from their release tags in the
[decisions repository](https://github.com/gleam-dream/decisions)
([ADR 0040](../../docs/adr/0040-pin-integration-packages-to-their-release-tags.md)).

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
