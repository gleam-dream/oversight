# Synthetic data erasure campaign

## Hypothesis recorded before implementation

Can Saga, Grind and HTTP Gun express reversible preparation followed by irreversible effects while preserving uncertainty, resumability and cancellation truth? Prediction: Saga belongs in preparation; final deletion needs forward reconciliation and application evidence rather than invented compensation.

| Case                                           | Predicted observable outcome                                                                                                                                    |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Ordinary campaign and native identities        | Freeze and plan preparation succeed; subject/operation/target records survive Grind codecs; every target has one deletion and an application receipt.           |
| Known preparation failure                      | Only the completed freeze is undone; no deletion is admitted.                                                                                                   |
| Lost deletion reply                            | Grind reports Uncertain; another delivery cannot blindly repeat DELETE; authoritative lookup supplies the receipt before queue confirmation and remaining work. |
| Cancellation after one deletion                | Campaign retains partial erasure; remaining targets stay present; cancellation does not reverse the first deletion.                                             |
| Fresh coordinator and queue pruning            | A new runtime delivers the same domain operation; retained application evidence prevents another DELETE even after old queue history is pruned.                 |
| Advanced target policy and bounded concurrency | Stop/continue policy is explicit application choice; queue concurrency two permits two blocked handlers and excludes a third until release.                     |

## Proposed ownership

- Saga owns local freeze→stage-plan execution and undo of reversible preparation.
- Grind owns durable target-job delivery, cancellation intent, uncertainty and attributed queue resolution.
- HTTP Gun owns local HTTP transport; a dropped reply supplies no domain completion proof.
- The application owns native identities, target policy, operation receipts, forward reconciliation and retention.
- The runner owns a disposable PostgreSQL cluster and a synthetic loopback service. The script owns Grind and HTTP clients and stops both. No live provider or real subject data is used.
- Saga durability, host/VM loss, concurrent campaign coordinators, provider certification and legal guarantees are outside this experiment.

Implementation and observations follow after execution.

## Run and evidence

From this directory:

```sh
nix develop ../.. --command bash run.sh
```

The runner checks formatting of `src` and `test`, builds with warnings as errors,
starts a loopback HTTP fixture, and runs one integration test with seven named
behavioral checks against the disposable PostgreSQL helper. It removes the fixture
and database on success or failure. Each run writes `.artifacts/latest.log` and
`.artifacts/provenance.txt`; these files are ignored. The accepted snapshot is
[evidence/accepted.log](evidence/accepted.log), with revisions, dirty status,
manifest hashes and toolchain in [evidence/provenance.txt](evidence/provenance.txt).
There is no handwritten Erlang and no native FFI compilation step.

The fixture and assertions are original consumer evidence. No external oracle
or copyrighted fixture was imported. The consumer manifest declares Apache-2.0;
the lockfile records package identities. These checks establish native OTP,
loopback HTTP and disposable PostgreSQL behavior, not upstream conformance,
provider qualification, machine restart or database failover.

## Expectations compared with observations

| Case                                    | Observed result                                                                                                                                                                                                                                                                                                                                                                                                                     |
| --------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Ordinary campaign and native identities | Passed. Saga froze and staged the plan; Grind round-tripped `Command(SubjectId, OperationId, Target)` and returned native `Receipt`; both targets received exactly one DELETE. Application cleanup released temporary preparation.                                                                                                                                                                                                  |
| Known preparation failure               | Passed. `StepFailed(PlanRejected)` retained no unknown effects. Database readback showed `frozen=false`, `staged=false`, and exactly one undo. No deletion was admitted.                                                                                                                                                                                                                                                            |
| Lost deletion reply                     | Passed. The service recorded deletion and closed the TCP connection before response headers. HTTP Gun's persisted failure had `MaybeSent`, `Network`, no HTTP status, and description `Request failed: peer closed; request may have been sent`. Two distinct job deliveries stayed uncertain while the fixture counted one DELETE. Authoritative lookup confirmed the exact operation; attributed queue resolution was repeatable. |
| Partial cancellation                    | Passed. A dropped-reply target remained uncertain after cancellation. Replay was rejected with `CancellationPending`. Lookup then proved its deletion, allowing terminal confirmation. The second target was scheduled one hour ahead and returned `CancelledBeforeRun`; its DELETE count remained zero. The campaign remained partially erased.                                                                                    |
| Fresh coordinator and pruning           | Passed. Public pruning removed the old successful job; both old outcome lookup and binding in the replacement runtime returned precisely `JobNotFound`. A new delivery used application evidence without another DELETE. The replacement runtime completed the target deliberately left unfinished after reconciliation.                                                                                                            |
| Target failure policy                   | Passed. `StopOnRejection` retained the rejected target and untouched remainder. `ContinueOnRejection` completed the independent target. Under either policy, a successful target followed by a dropped-reply target returned typed `NeedsInvestigation`, preserved the prior result and job handle, and sent no request to the remaining target.                                                                                    |
| Bounded concurrency                     | Passed. With concurrency two, two handlers reached application barriers, administration showed two executing jobs and one queued job, and the third entered after a release. The barrier check also used a finite 100 ms absence observation; it is not a throughput or cluster-wide capacity claim.                                                                                                                                |

## Public call sites and caller concepts

- [src/campaign.gleam](src/campaign.gleam) contains ordinary public calls:
  `saga.step`, `saga.undo`, `saga.define`, `execution.run`,
  `worker.responding`, `worker.codec`, `grind.submit`, `grind.await`, and
  `http_gun.send`. All imports use public modules.
- [test/erasure_campaign_test.gleam](test/erasure_campaign_test.gleam) contains
  runtime startup, explicit loopback admission, advanced queue configuration,
  exact outcome assertions, cancellation, attributed resolution and pruning.
- Advanced configuration changes existing package settings and native application
  policy. It adds no package option:

```gleam
queue.new("erasure")
|> queue.with_concurrency(2)
|> queue.with_poll_interval(duration.milliseconds(10))

campaign.execute_targets(
  jobs,
  worker,
  [rejected_target, independent_target],
  domain.ContinueOnRejection,
)
```

- `SubjectId`, `OperationId`, `Target`, `Command`, `Receipt`, `Policy` and
  `PreparationError` belong to the application. Only boundary codecs convert
  them to JSON. The fixture uses fixed slash-free synthetic identity strings;
  its path encoding is not an arbitrary user-identifier codec.
- Three identities remain distinct: the domain subject/operation/target tuple,
  Grind's integer job ID, and the attributed resolution command ID. Two distinct
  jobs can deliver the same domain operation. Queue IDs and pruning cannot decide
  whether that domain operation has already happened.
- The caller supplies input/output codecs, queue name and capacity, destination
  access, receipt validation, known-rejection policy, uncertainty handling,
  evidence retention and reconciliation attribution. The compiler checks native
  composition without a universal context or error type.

## Recovery, cancellation and cleanup

- Before DELETE, the application commits a `pending` evidence row with a unique
  domain identity. Only the insertion winner can send. A fresh delivery reads
  `confirmed` and returns its receipt, reads `rejected` and declines, or reads
  `pending` and reports uncertainty. This remains useful after queue pruning.
- The fixture also deduplicates its operation identity. The tests count incoming
  DELETE calls as well as effects, so fixture deduplication cannot hide a blind
  duplicate request from the consumer.
- A successful authoritative lookup must return the exact expected receipt.
  `404`, malformed receipt or failed lookup does not authorize replay. A pending
  marker can precede the actual send; distinguishing that condition from an
  in-flight effect requires additional provider evidence and remains unresolved.
- Application confirmation precedes attributed queue resolution. The original
  queue uncertainty and subsequent resolution are distinct facts. This example
  has no local queue-acknowledgment table and does not claim atomic settlement of
  an outer database transaction or lost COMMIT reply. No borrowed resolution
  transaction, archive or deletion hook was needed for the demonstrated obligation.
- Cancellation stops future work when the queue confirms `CancelledBeforeRun`.
  It cannot restore already deleted fixture data. The test retains cancellation
  intent while uncertain and permits later terminal confirmation without replay.
- A replacement runtime means fresh Grind owner, pool and queue processes in the
  same Erlang VM. Application tables and the separate provider process survive.
  It is not an abrupt coordinator-death or whole-VM-restart experiment.
- The script owns the HTTP client and Grind runtime. Exception-safe cleanup stops
  both; borrowed connections are used only within their runtime lifetime. Shell
  cleanup terminates the fixture and deletes its temporary directory. The shared
  PostgreSQL helper owns cluster removal. Successful preparation is released by
  explicit application cleanup; Saga only invokes undo on its failure path.

## Ergonomic findings and corrections

| Classification                                     | Evidence and conclusion                                                                                                                                                                                                                                                                                                                                                                                                                         |
| -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Compiler setup mistake                             | The receipt encoder callback needed `fn(receipt: Receipt)` for record field inference. A barrier branch needed an explicit final `Nil`, because ending with `let assert Ok(Nil) = ...` retained a `Result` expression. Both were local fixes; no package API changed.                                                                                                                                                                           |
| Consumer defect, corrected with red→green evidence | The first policy helper panicked on uncertainty. A real DropReply input reproduced that panic in [policy-red.log](evidence/policy-red.log). The corrected `CampaignResult` retains previous results, the job handle, exact observed outcome/read error and unadmitted remainder. Admission failure similarly retains Grind's typed error, including its pending submission capability. Both policies now halt without panic after a lost reply. |
| Usability friction                                 | Reusing resolution ID `lookup-confirmed` for two different jobs produced `ResolutionConflict`. The public `resolution` signature describes a decision ID but does not make its installation-wide scope obvious at the call site. The consumer now derives a stable command ID using the job ID. This was incorrect caller identity reuse, not a reproduced Grind defect.                                                                        |
| Successful API behavior                            | `MaybeSent` plus absent status was readable and serializable through public HTTP Gun APIs. Grind preserved explicit uncertainty, rejected replay after cancellation, accepted attributed terminal confirmation, and returned precise missing-job errors after pruning. Native Saga error and undo types needed no adapter.                                                                                                                      |
| Tested package defects                             | None found in this experiment.                                                                                                                                                                                                                                                                                                                                                                                                                  |

## Workaround cost and keep-as-is decisions

- The evidence ledger is necessary domain policy, not a workaround for missing
  queue functionality. It costs one small application table, one commit before
  each first DELETE, one receipt update after confirmation, and a lookup on every
  delivery. A second table holds synthetic reversible preparation state.
- The local service implements receipt lookup, stable operation identity,
  rejection and deterministic reply loss. The application's adapter validates
  receipt content instead of treating every 2xx response as erasure proof.
- `CampaignResult` and the explicit stop/continue policy are application concepts.
  Tests keep fixture setup and database assertions fail-fast; this consumer is
  not a production migration, reconciliation scheduler or operations service.
- Keep Saga only in reversible preparation. Putting final deletion in an undo
  journal would add concepts without restoring data. Saga PostgreSQL checkpoints
  are unnecessary for this chosen final-effect phase; recovery is represented by
  the application ledger and Grind deliveries. Interrupted preparation recovery
  remains outside the demonstrated scope.
- Keep Grind delivery uncertainty and HTTP transport evidence separate. Keep
  application evidence beyond queue retention. Keep concurrency a per-runtime
  queue setting and stop/continue an application policy. No generic workflow,
  framework runtime, deletion hook, archive or core option is proposed.

## Resolution identity guidance

- Grind's [resolution guidance](https://github.com/gleam-dream/grind/blob/master/docs/USAGE.md#resolve-an-uncertain-job) documents the installation scope, saved command identity and exact retry rules.
- Reusing a constant for different jobs produced `ResolutionConflict` on the
  second job. The public guide now shows a saved application decision ID
  qualified by the job ID and explains exact-command retry. The observed
  incorrect call supports clearer documentation; it supplies no evidence that
  a new constructor, namespace API or runtime behavior is needed.

## Limits

- Only synthetic data is erased. This is not a legal compliance guarantee.
- A worker that crashes before sending but after the pending commit requires
  investigation; this conservative protocol deliberately sacrifices automatic
  progress rather than inferring nonexecution from absence.
- Database assertion failures, abrupt process loss during preparation, live
  cancellation racing with an admitted HTTP send, concurrent campaign
  coordinators, stale provider reads, schema upgrades, database failover, receipt
  retention policy and operator authentication are not exercised.
- `Finished` means the selected target list was processed; callers inspect each
  `Erased` or `Refused` value. `StoppedAfterRejection` and `NeedsInvestigation`
  preserve the unprocessed remainder. Neither means all target data is erased.
- Sinal observation adapters and Blueprint runtime schema contracts were not
  needed for these static native values. No claim about those surfaces is made.
