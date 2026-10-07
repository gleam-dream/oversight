# Financial recovery

- This executable consumer retains financial evidence across Saga execution and Grind delivery.
- The application owns payment intent, account reservations, provider evidence, and postings. Saga owns workflow checkpoints; Grind owns delivery and operator resolution.
- The [owning composition contract](../../docs/design/design.typ#financial-recovery) specifies these boundaries. [ADR 0010](../../docs/adr/0010-demonstrate-financial-recovery-through-public-contracts.md) records the decision.

## Run

- Run from this directory in the Oversight Nix shell:

  ```sh
  nix develop ../.. --command ../scripts/with-postgres.sh gleam test
  nix develop ../.. --command gleam build --warnings-as-errors
  nix develop ../.. --command gleam format --check src test
  ```

- `with-postgres.sh` creates and removes a PostgreSQL 16 cluster. The tests start a scripted TCP payment provider on loopback; they require no credentials or external services.
- The local dependencies require matching sibling checkouts. `gleam.toml` declares those paths; `manifest.toml` locks external dependencies; Oversight's application gate records checkout revisions and dirty state.
- Required CI checks use the committed sibling revisions in [the compatibility manifest](../../sibling-revisions.txt). Local commands qualify the working trees actually present, including any uncommitted changes; reproduce the manifest in separate clean checkouts when qualifying that exact set.
- The supported test runtime is the pinned Oversight Nix shell (Gleam, Erlang/OTP 28, and PostgreSQL 16). From the Oversight root, the application gate captures source provenance and runs the compiler, fixture, and database checks:

  ```sh
  nix develop --command python3 -B scripts/ci.py application financial_recovery
  ```

- The test entry is `financial_recovery_test.main`. This recipe has no web server or separate application daemon.

## Read the consumer

| Module                                                    | Responsibility                                                                          |
| --------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| `domain`                                                  | Native payment identity, request, financial state, and typed application failures       |
| `payments`                                                | Account locking, reservations, accepted evidence, and one posting per business identity |
| `provider`                                                | Payment submit/lookup protocol through an application-owned HTTP Gun client             |
| `coordinator`                                             | Transactional job admission and durable Saga execution with interrupted-step resolvers  |
| `test/support`                                            | Explicit startup, migrations, shared pool, and shutdown                                 |
| `test/scripted_provider` and `test/financial_fixture.erl` | Independent provider evidence, counters, and local transport failure controls           |

- Ordinary use constructs an application-native payment and admits it through a transaction:

  ```gleam
  let payment = Payment(OperationId("invoice-204"), "payer", "receiver", 250)
  let worker = coordinator.definition(deps)
  case coordinator.admit(jobs, worker, payment) {
    Ok(coordinator.Queued(handle)) -> inspect_delivery(handle)
    Ok(coordinator.Completed(reference)) -> return_retained_result(reference)
    Error(error) -> handle_admission_error(error)
  }
  ```

- `OperationId` identifies a business operation. `payment:<id>` identifies its Saga execution; `coordinate:<id>` identifies its queue submission.
- Provider lookup percent-encodes the business identity as one URL path segment. The identity in application records and the idempotency header remains unchanged; a native submit/lookup test covers `/`, `?`, and `%` in that identity.
- Reusing the business identity with changed intent returns `IdentityConflict`. Completed-operation admission returns the retained result before consulting Saga or creating another job.
- Direct Saga or raw Grind entry still checks the application record before the transfer effect. Missing or changed intent is refused; matching `Confirmed` or `Posted` evidence is reused without another provider submission.
- The coordinator conservatively holds every non-completed Saga outcome for inspection. A held Grind job can therefore carry a known `RefusedEffect` as well as an unknown effect; inspect the retained Saga outcome before selecting an operator decision.
- `TransactionUnconfirmed` preserves uncertainty about the application's outer transaction. Read the application record or retry admission with the same business identity; do not generate a replacement operation identity.

## Admission and account invariant

- The example transfers integer minor units between two existing accounts. Every account balance writer locks both rows in account-ID order.
- That locking protocol protects `balance >= reserved >= 0` for these known rows under READ COMMITTED. It does not establish correctness for arbitrary predicates, new account sets, or writers that bypass the protocol.
- The contention test holds an admitted 400-unit reservation on a 500-unit account in an open transaction. PostgreSQL reports the second 400-unit admission waiting for a lock before the first transaction commits; the second admission then returns `InsufficientFunds` without an operation or job.
- `coordinator.admit_in` reserves funds and calls `grind.submit_in` using the caller's transaction. A rollback after job insertion removes the reservation, operation, job, and submission receipt together.
- SERIALIZABLE transactions retain their isolation level and receive `TransactionIsolationUnsupported("serializable")`. The example does not lower the application's isolation level.
- An application requiring SERIALIZABLE can commit a dispatch record in an application-owned outbox with its financial transaction. A dispatcher can submit separately using a stable submission identity; the application must own dispatch retries and outbox retention.
- The outbox alternative is documented, not implemented or qualified by this consumer. Supporting SERIALIZABLE directly in Grind requires separate transaction/conflict tests.

## Interrupted external effect

- The scripted provider records a payment before withholding its reply. A deterministic notice proves that the effect boundary was crossed before the test terminates the Saga runner.
- The replacement coordinator uses the same Saga execution. Its transfer resolver queries the provider before permitting further work.
- A failed lookup leaves Saga `Suspended(RecoveryRequired(...))` and Grind `Uncertain`. The account reservation remains held; the provider submission count remains one.
- A missing payment lookup is also insufficient evidence under this provider contract. The consumer never interprets HTTP 404 as authoritative non-execution.
- Once provider evidence becomes available, an attributed resolution authorizes another coordinator delivery:

  ```gleam
  admin.resolve_uncertain(
    jobs,
    handle,
    admin.resolution(
      admin.AuthorizeReplay,
      id: "reconciliation-204",
      by: "operator-alice",
      details: "Resume the same coordinator and resolve the interrupted payment",
    ),
  )
  ```

- This authorization does not authorize another payment submission. Saga's resolver obtains the known payment, the application deduplicates its evidence, and the posting transaction executes once.
- Repeating the resolution ID returns `AlreadyApplied`. Repeating evidence or re-entering the completed operation does not create another posting.

## Lost response without process interruption

- A separate real TCP exchange closes the socket after recording the payment. HTTP Gun reports `MaybeSent`; the test does not infer whether an arbitrary real provider executed from that transport evidence alone.
- If the Saga callback returns an unknown effect normally, Saga stores a finished `Unresolved` outcome. That outcome is distinct from suspended interrupted-step recovery.
- Authorizing another delivery does not turn that finished outcome into an interrupted step. The test verifies that it remains uncertain without another payment or posting.
- Settling this finished outcome requires an explicit application reconciliation procedure with authoritative evidence. This recipe demonstrates the safe hold; it does not supply an operator interface or automatically rewrite Saga history.

## Local posting and cancellation

- The posting transaction updates both accounts and records its business identity atomically. The later Saga checkpoint is a separate commit, even on the same PostgreSQL pool.
- A synchronous `posting_committed` observation exposes the interval after SQL commit and before the callback returns. The test terminates the runner in that interval; recovery reads the posting record without repeating the callback.
- A synchronous `recovery_held` observation exposes the interval after Saga suspension and before Grind acknowledges `Uncertain`. Tests request cancellation before and after that acknowledgement.
- Both cancellation orderings retain the uncertainty description and reservation. `AuthorizeReplay` is refused while cancellation is pending; uncertain jobs remain outside finished-job pruning.
- These tests concern cancellation of unresolved work. They do not claim that cancelling a job reverses a provider effect or settles the financial operation.

## Ownership, migrations, and retention

- The application configures one Grind-owned pool. Its own queries and `saga_postgres` borrow that pool.
- `test/support` migrates application and Saga tables before starting queue consumers. Grind performs its startup migration before polling.
- The recipe's application schema is fresh-install test SQL. An existing production deployment needs versioned application migrations and reviewed changes to worker, workflow, and codec versions.
- Shutdown stops Grind consumers before HTTP Gun and the scripted provider. The borrowed Saga storage has no separate background process.
- Job pruning deletes queue receipts and submission deduplication records. Financial operation identity, evidence, and postings remain application-owned and are not pruned with jobs.
- The retention test actually prunes a completed job and re-enters its business identity. The application returns the retained result without another provider submission or posting.
- Business-record retention and account policy remain application decisions. This example is not a complete financial ledger, accounting specification, payment-product integration, or compliance assessment.

## Evidence limits

- The tests exercise public Gleam APIs, native BEAM process termination, real PostgreSQL transactions, and real loopback TCP exchanges. The scripted provider retains evidence independently of the terminated Saga runner.
- Process barriers establish effect/checkpoint ordering. Contention waits inspect PostgreSQL's reported lock state with bounded polling; a separate short sleep advances the retention age before invoking the public pruner.
- The tests do not restart the whole VM or payment-provider process. They do not test TLS, mTLS, a live BaaS provider, upstream behavioral parity, or lost PostgreSQL commit acknowledgements.
- Grind's package-level fault tests own cancellation acknowledgement loss. This consumer owns the financial composition and the two acknowledgement/cancellation orderings.
- The consumer fixture is authored locally. It contains no copied provider implementation or upstream oracle requiring separate version/license provenance.
