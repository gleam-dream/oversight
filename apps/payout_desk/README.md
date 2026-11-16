# payout_desk

[![CI](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

A marketplace pays its sellers. A Fabric support agent investigates a seller's
request after a disputed order and proposes a payout. Its policy hands the
`propose_payout` call over to a `decisions` decision point and the run ends: the call
pays nothing, and no approval is left to expire. The request is expected
at the `payout` point under its own key when it is admitted, and the call is admitted
under that key, with the reads the model received. A versioned policy lets a small
payout the seller's dispute won proceed after an undo window stated in the policy rule,
during which finance may withdraw it; asks someone in finance other than the
person who asked for the rest; asks two from finance from 500.00, and after an hour two
from finance or one from the head of finance; and consults a second point, `risk`, for a
seller with recent chargebacks. Suspending a seller's account supersedes every payout to
them not yet released: expected, waiting for finance, or held. A release check compares the amount with the seller's
balance and records the balance it compared.
Finance decides from its own assistant through three typed MCP tools served by Relay
behind Hellhound bearer verification; the card they open is `decisions/view`'s
document, served with its own codec. The released payout runs as a durable Saga
(reserve, pay, post) delivered by Grind, and the provider's answer is reported to the
record. A follow-on agent run then continues the conversation from what really happened
as the call's result, and the seller hears its reply only when it matches the record. A
payout superseded before the agent proposed is not filed: its agent is not driven, or,
if it was already working, its proposal is refused and its run has already ended; the
seller is told it was stopped.

The model is a scripted Fabric model and the payment provider is a scripted actor,
both in process. Fabric and its PostgreSQL adapter come from one unreleased Fabric
commit until Fabric 0.3.0 is on Hex. The decision record (`decisions_postgres`), Grind, Saga and Fabric
(`fabric_postgres`) share one PostgreSQL pool the application owns.

## Run

From this directory, inside the Oversight shell:

```sh
../scripts/with-postgres.sh gleam test
../scripts/with-postgres.sh gleam run
```

`gleam run` walks Dora's payout from her request to the provider's receipt and prints
the card as finance sees it. The tests cover the failure paths: a request's agent job
driven twice at once and the request submitted again, admitting one payout, two validators approving at once, a card shown before a correction, a worker
killed after the provider answered, a guard that lost its connection at a hold's
wake-up, a restart after a wake-up's job was lost, a restart with an escalation
pending, a provider that times out, withdrawing during the hold and after it, a
suspension before and after the agent proposed, a failed agent run retried under the
same record, a request named like another request's retry, a handed-over run that takes
no turn before the decision, a follow-on model that proposes again, a job killed
between the handover and the filing, and a settlement notice delivered twice.

The [composition contract](../../docs/design/design-layer.pdf) describes the
payout desk. [ADR 0039](../../docs/adr/0039-hand-the-payout-call-over-and-tell-it-in-a-follow-on-run.md)
records why the agent hands its call over and a follow-on run tells the outcome, and
the temporary Fabric pin;
[ADR 0035](../../docs/adr/0035-answer-a-gated-agent-call-from-the-decision-point.md)
why the decision point, not Fabric's approval expiry, answers the agent's call;
[ADR 0038](../../docs/adr/0038-pin-the-decisions-packages-to-a-git-commit.md)
which commit of the `decisions` packages it uses, and
[ADR 0037](../../docs/adr/0037-expect-recommendations-at-admission-and-key-payouts-by-request.md)
why a payout is expected when its request is admitted and keyed by the request, why a
failed agent run is retried in a fresh run, and how a suspension supersedes it.
