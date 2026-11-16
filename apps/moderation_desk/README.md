# moderation_desk

[![CI](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

Moderation at volume on the BEAM with no database. Posts arrive as triggers
for the `moderation` decision point of `decisions`, and the supervised runtime
of `decisions_otp` works them with a bounded pool of workers. A rule model and
a scripted classifier, each in a process of its own with a deadline, recommend
publishing, hiding or escalating a post. Versioned policies let the confident
answers through and ask moderators or seniors about the rest; a reviewer reviews
a sample. They work at a live desk of processes told about each change after
commit. Policy version 2 holds a confident hide of spam for five minutes before
it is applied, and a senior may take it back during that time. Admitting a post
records that a recommendation is expected for it, so an edit supersedes the
recommendation about the old text whether the model has not answered yet, the
recommendation waits for a person, or the hide is held. A replay across the
schedulers gates each new policy version. Sinal counts what an operator
watches. The classifier and the people are scripted; nothing leaves the VM.

## Run

From this directory, inside the Oversight shell:

```sh
gleam test
gleam run
```

`gleam run` moderates 600 posts under policy version 1, replays the
moderators' decisions against two candidates and publishes the one that
clears the gate, moderates 10 000 posts under version 2 with duplicate
deliveries and failing classifiers, then shows escalation and expiry with the
runtime stopped and started again, edits, the undo window, an appeal and a
stale card. It
prints the time, the machine and its scheduler count, the operator's numbers
and the result of the library's invariant check. The numbers are one run on
one machine, not a guarantee.

The [composition contract](../../docs/design/design-layer.pdf) describes the
moderation desk. [ADR 0036](../../docs/adr/0036-restart-the-in-memory-decision-store-empty.md)
records the supervision tree, why a restarted store starts empty and is seeded
again, and why a trigger is set aside after 3 attempts.
[ADR 0037](../../docs/adr/0037-expect-recommendations-at-admission-and-key-payouts-by-request.md)
records why admission records an expected recommendation.
[ADR 0034](../../docs/adr/0034-consume-the-decisions-packages-by-path-until-published.md)
records why the `decisions` packages resolve by path.
