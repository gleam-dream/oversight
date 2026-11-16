# Hand the payout call over, and tell its outcome in a follow-on run

<a id="adr-0039"></a>

Recorded on 2026-11-16. Supersedes the mechanism of
[ADR 0035](0035-answer-a-gated-agent-call-from-the-decision-point.md#adr-0035)
(the approval that never expires, the approver that refuses until the record
states an outcome, and the resumed parked run) and the cancellation of a
parked run in
[ADR 0037](0037-expect-recommendations-at-admission-and-key-payouts-by-request.md#adr-0037).
Departs from [ADR 0031](0031-consume-published-ecosystem-packages-from-hex.md#adr-0031)
for `payout_desk` until the condition below.

## Decision

- **The handover.** In `payout_desk`, the agent's policy answers
  `propose_payout` with `policy.HandOver(reason)`. The tool never runs, the
  model takes no further turn, and the run ends as
  `run.Finished(run.HandedOver(action, tool, arguments_json, reason))`. No
  approval exists, so nothing can expire and answer the model.
- **Filing.** The `payout.agent` job reads the `HandedOver` outcome and admits
  the call at the `payout` point with `recommend_once` under the request's key
  (`payout:` and the request id, as ADR 0037 states). The handed-over action
  (run id and `turn.call_id`) is the occurrence's trigger and explanation. A
  job delivered again, or replayed after it died between the handover and the
  filing, starts the same run id, finds the ended run (`AlreadyStarted`, then
  `recover`), reads the same outcome and files nothing twice. The model is not
  called again.
- **Telling.** When the occurrence settles and its outcome is known, the
  `payout.tell` job builds the follow-on input with
  `fabric.handover_history(snapshot, result:)`. The result is the recorded
  outcome encoded by `tool.reconciliation(propose_definition(), Ok(truth))`.
  Every outcome (paid, not paid, rejected, expired, superseded, withdrawn,
  refused) is a value of the tool's output type, so no outcome is sent as a
  rejection. The input adds one user prompt after the result, and the job
  starts the follow-on run with `fabric.start_with_input`. The handed-over run
  never continues.
- **The follow-on run's identity.** The follow-on run's id is
  `run.id_from_parts("payouttold", [request])`. A request is one payout and
  hands one call over, so the request names its follow-on run. The prefix
  differs from the proposing runs' `payout` prefix, so the two never collide.
  A telling delivered again, at once or later, gets `AlreadyStarted`, recovers
  the run, waits for it and reads its answer. The seller is told once per
  occurrence (`db.tell`), as before.
- **The follow-on policy.** The follow-on run's context carries the recorded
  outcome. The policy denies a second `propose_payout` there, so a model that
  proposes again is told the payout is already decided and answers from the
  result. It is not handed over a second time.
- **What the seller hears.** Unchanged from ADR 0035. A reply reaches the
  seller only when its outcome and amount equal the record's. Otherwise the
  application sends its own message from the record and keeps the agent's
  text. When the follow-on run ends without an answer, or the run named by
  the record has no handover to continue from, the application sends its own
  message.
- **Supersession.** A payout superseded before its agent ran is not driven
  (ADR 0037). A payout superseded while the agent worked is refused at
  admission (`SupersededBefore`). Its run has already ended with the
  handover, so the application cancels nothing, and the settlement follower
  tells the seller from the record. A payout superseded after admission
  lapses, and its follow-on run tells the seller.
- **Retries of a failed agent attempt.** Unchanged: a run that fails (for
  example, the model's provider refuses) has ended, and a failed run cannot
  continue. The failure is recorded as an attempt under the request's key,
  and the retried job starts a fresh run whose id adds the attempt number.
- **No Fabric approval.** `payout_desk` registers no approvers, sets no
  approval expiry and has no approval requirement.
- **A temporary Git pin.** `apps/payout_desk/gleam.toml` takes `fabric` and
  `fabric_postgres` from [gleam-dream/fabric](https://github.com/gleam-dream/fabric)
  at commit `650e962cad6dac3c26113a2c1f951b53ea7e9176`: `fabric` at the
  repository root, `fabric_postgres` at `integrations/fabric_postgres`. At
  that commit the adapter depends on `fabric` by path (`../..`), which
  resolves inside the same Git source. `nix/git-sources.nix` registers the
  commit's source hash, `sha256-BUZ7uW8FN3cjPpsJM+gaQSPpqym4PgBW52zBD2OiLoY=`.
  The other applications keep `fabric` 0.2.0 from Hex and the earlier adapter
  commit.

## Rationale and consequences

- **Why the handover.** An approval that no approver can give was the only
  way to keep the run from performing the call, and an expired approval is a
  rejection that the model reads as its next turn. The application avoided
  that trap only by setting `run.Infinity` and refusing every approval until
  the record stated an outcome. The handover removes the approval, so the
  trap cannot occur: there is nothing to expire, and no turn happens between
  the handover and the decision. `truth_test.gleam` shows the ended run, its
  two model turns, and no pending approval after the one-second wait that the
  trap needed.
- **What was removed.** The approver (`jobs.approvers`), the approval
  requirement, the approval expiry setting, the resumption that approved or
  rejected the parked call (`jobs.resume`), the cancellation of a parked run
  (`jobs.cancel_run`), the decoding of an outcome from a rejection's reason,
  and `domain.lets_call_through`.
- **What stays.** The fresh run per failed attempt stays, for the reason
  above. The `decisions` tracker issue 26 names it beside the cancellation as
  work the handover would make unnecessary; only the cancellation is
  removed. Fabric runs stay in `fabric_postgres`: the follow-on run needs the
  handed-over run's transcript after hours or days, across restarts and on
  any node.
- **Why the pin departs from ADR 0031, and when it ends.** The handover is
  not released: it is on the Fabric branch `feat/tool-outcome-ends-run`. The
  owner chose to convert `payout_desk` before the release, so that a real
  application uses the API before it is published. The pin ends when
  `fabric` 0.3.0 is on Hex. `payout_desk` then requires
  `fabric >= 0.3.0 and < 0.4.0` from Hex and moves `fabric_postgres` to a
  commit that requires it, and the registered hash for this commit is
  removed if nothing else uses it. Until then, `payout_desk` is the one
  application whose `fabric` does not come from Hex. Its manifest locks
  `fabric` as version 0.2.0 from Git, because the commit has not raised the
  package version. If the branch is rewritten before the release, the commit
  can become unreachable, and the pin, the manifest and the registered hash
  must move together.
- **Records.** At this commit every Fabric record is written as version 10.
  A store that this application shares with a node on the published
  `fabric` 0.2.0 cannot read those records. A run parked on an approval by
  the earlier mechanism has no handover, so `fabric.handover_history` refuses
  it (`NotHandedOver`) and the new code cannot continue it; it stays parked
  until it is cancelled with `fabric.cancel` or `fabric.cancel_stored`. The
  application has no deployed store, so it migrates nothing, and no test
  covers a run left by the earlier mechanism.
