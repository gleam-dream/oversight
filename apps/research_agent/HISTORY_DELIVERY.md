# History-aware invocation and durable delivery

## Run the consumer

- Enter `nix develop` from the Oversight root, then run the following commands. The sibling Fabric checkout must provide `fabric/input` and `invoke.agent_with_history`.

  ```sh
  cd apps/research_agent
  ../scripts/with-postgres.sh gleam test
  ```

- `test/history_delivery_test.gleam` exercises the additional history-turn recipe in `test/history_delivery.gleam`. The existing research and Saga publication pipeline keeps its own scenarios.
- Grind, application transactions, Fabric records, leases and the Fabric sweeper use real disposable PostgreSQL. The model callback is deterministic. This is local process-recovery evidence, not live-provider or database power-loss evidence.

## Keep the two commit intervals explicit

- Acceptance inserts the application turn and calls `grind.submit_in` inside the same application transaction. Rollback removes both. The handler can run only after that transaction commits; no Fabric model or tool call occurs during admission.
- Delivery loads the accepted application history, validates it with `input.new`, and invokes `invoke.agent_with_history` with a stable principal and turn key. Authentication belongs to the application; `with_principal` only selects the execution identity scope.
- Fabric owns admitted execution. The registered sweeper resumes it after a forced bounded store drain. The application adds no lease-renewal loop, abandoned-run scanner or separate execution queue.
- Fabric completion can precede application incorporation. The consumer reopens the same keyed outcome, obtains its typed answer through `invoke.answer`, and obtains the generated messages through `fabric.generated_messages`.
- Incorporation locks the application turn and commits the answer, encoded generated messages and applied marker together. Repeating the transaction reads the applied result. The test rolls back a write, then simulates loss of the delivery caller's reply after a real commit; that simulation is not a PostgreSQL network-fault test.
- `fabric/history.codec()` stores and restores the complete native message values. The consumer owns the transaction and applied marker; Fabric owns the lossless message representation. Assertions compare restored messages before and after pruning without depending on the encoded field layout.
- Pruning remains disabled until incorporation commits. The application applied marker survives deliberate Fabric pruning, so later Grind delivery returns the applied answer without invoking Fabric again. An age threshold alone cannot guarantee retention while incorporation is delayed indefinitely.

## Preserve observations and recovery choices

- The application saves the original invocation kind and response code before selecting a delivery outcome. Working and unattended observations snooze the existing delivery. Ended failures and definite refusals retain different outcomes.
- Approval/input suspension and uncertain execution require application continuation or investigation. Grind's `Uncertain` delivery state quarantines both cases; the saved Fabric observation distinguishes them. It does not classify suspension as an unknown external effect.
- An application-authored graph can retain incorporation as an explicit operation. Its stable application idempotency key and interrupted-effect contract must resolve a possible commit before replay. This alternative still needs transactional delivery before graph admission; a shared pool or borrowed connection does not make that admission atomic with application acceptance.
