# Financial recovery

An executable consumer that retains financial evidence across Saga execution and
Grind delivery. The application owns payment intent, account reservations, provider
evidence and postings; Saga owns workflow checkpoints; Grind owns delivery and
operator resolution. It has no web server or daemon, and its test entry is
`financial_recovery_test.main`.

## Run

From this directory, inside the Oversight shell:

```sh
nix develop ../.. --command ../scripts/with-postgres.sh gleam test
nix develop ../.. --command gleam build --warnings-as-errors
nix develop ../.. --command gleam format --check src test
```

The helper creates and removes a PostgreSQL 16 cluster, and the tests start a scripted
TCP payment provider on loopback, so no credentials or external services are needed.
From the Oversight root, the application gate also records source provenance:

```sh
nix develop --command python3 -B scripts/ci.py application financial_recovery
```

## Read the consumer

- `domain`: native payment identity, request, financial state and typed failures.
- `payments`: account locking, reservations, accepted evidence and one posting per business identity.
- `provider`: payment submit and lookup through an application-owned HTTP Gun client.
- `coordinator`: transactional job admission and durable Saga execution with interrupted-step resolvers.
- `reconciliation`: attributed settlement of a finished unresolved operation and recoverable queue confirmation.
- `test/support`, `test/scripted_provider` and `test/financial_fixture.erl`: startup, migrations, shared pool, and independent provider evidence with transport-failure controls.

Ordinary use constructs a payment and admits it through a transaction:

```gleam
let payment = Payment(OperationId("invoice-204"), "payer", "receiver", 250)
let worker = coordinator.definition(deps)
case coordinator.admit(jobs, worker, payment) {
  Ok(coordinator.Queued(handle)) -> inspect_delivery(handle)
  Ok(coordinator.Completed(reference)) -> return_retained_result(reference)
  Error(error) -> handle_admission_error(error)
}
```

An operator authorizes redelivery of an uncertain job and settles a finished unresolved
operation through `admin.resolve_uncertain` and `reconciliation.reconcile`, each with a
stable decision identity and attribution.

The [composition contract](../../docs/design/applications/design.typ#financial-recovery)
states the invariants, recovery behavior and evidence limits. [ADR 0010](../../docs/adr/0010-demonstrate-financial-recovery-through-public-contracts.md),
[ADR 0011](../../docs/adr/0011-settle-finished-uncertainty-in-the-application.md) and
[ADR 0012](../../docs/adr/0012-commit-queue-resolution-with-application-acknowledgment.md)
record the decisions.
