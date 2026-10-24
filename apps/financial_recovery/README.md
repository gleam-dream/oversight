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
nix develop --command bash scripts/test-applications.sh financial_recovery
```

## Read the consumer

- `domain`: native payment identity, request, financial state and typed failures.
- `payments`: account locking, reservations, accepted evidence and one posting per business identity.
- `provider`: payment submit and lookup through an application-owned HTTP Gun client.
- `coordinator`: transactional job admission and durable Saga execution with interrupted-step resolvers.
- `reconciliation`: attributed settlement of a finished unresolved operation and recoverable queue confirmation.
- `test/support`, `test/scripted_provider` and `test/financial_fixture.erl`: startup, migrations, shared pool, and independent provider evidence with transport-failure controls.

The application test constructs a payment, admits it through a transaction and verifies its posting against a local scripted provider:

<!-- prettier-ignore-start -->

<!-- snips: test/financial_recovery_test.gleam#ordinary-payment -->
```gleam
pub fn ordinary_coordinator_posts_a_payment_test() {
  use f <- support.with_runtime("finance_ordinary", scripted_provider.Reply)
  let assert Ok(Nil) = payments.account(f.deps.connection, "alice", 1000)
  let assert Ok(Nil) = payments.account(f.deps.connection, "bob", 0)
  let payment = Payment(OperationId("ordinary"), "alice", "bob", 250)
  let assert Ok(coordinator.Queued(handle)) =
    coordinator.admit(f.jobs, coordinator.definition(f.deps), payment)
  assert grind.await(f.jobs, handle, within: duration.seconds(10))
    == Ok(grind.Succeeded("provider-ordinary"))
  assert payments.balance(f.deps.connection, "alice") == Ok(#(750, 0))
  assert scripted_provider.counts(f.peer.pid) == #(1, 0)
}

```

<!-- prettier-ignore-end -->

An operator authorizes redelivery of an uncertain job and settles a finished unresolved
operation through `admin.resolve_uncertain` and `reconciliation.reconcile`, each with a
stable decision identity and attribution.

The [composition contract](../../docs/design/design-layer.pdf)
states the invariants, recovery behavior and evidence limits. [ADR 0010](../../docs/adr/0010-demonstrate-financial-recovery-through-public-contracts.md),
[ADR 0011](../../docs/adr/0011-settle-finished-uncertainty-in-the-application.md) and
[ADR 0012](../../docs/adr/0012-commit-queue-resolution-with-application-acknowledgment.md)
record the decisions.
