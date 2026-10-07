# Embargoed archive release

## Question and expected outcomes (written before implementation)

Can independently owned authentication, protocol admission and durable approval bind a benign archive release to an exact document revision and current permission, while keeping application policy explicit?

The proposed composition uses Warden's local HTTPS fixture issuer and real JWT validation, Relay's public authorization admission, Fabric's typed tool and current-policy approval, and fabric_postgres over a disposable PostgreSQL cluster. JSON Blueprint encodes application-native document/revision values. A deterministic Fabric model requests one release; it is an application model port, not a simulated Fabric runtime. LLM Wire adds no useful behavior to this question and is excluded.

| Case | Expected outcome before implementation | Owner of the rule |
| --- | --- | --- |
| Public classification, authenticated native principal | Relay admits the token; Fabric allows the typed tool; exactly the specified revision is released | Warden token checks; Relay audience/scope admission; application classification and write |
| Embargoed classification, configurable policy | An explicit approval requirement suspends without a release; authorized approval releases the same revision | Application policy; Fabric suspension and approval |
| Content changes during approval | Fresh context rejects the old revision; replacement content is never released | Application revision comparison in policy and write |
| Permission revoked during approval | Fresh application permission state refuses release despite an otherwise valid JWT/proof | Application live permissions; Fabric policy recheck |
| Cancellation versus refusal | Cancellation is a terminal run state; authentication/authorization refusal remains an admission error; neither writes | Fabric cancellation; Warden/Relay refusal |
| Fresh durable driver | A stopped store and a new store reopen the pending approval; approval and subsequent reopen produce one release | Fabric/fabric_postgres persisted state; application effect identity |

The bounded experiment excludes arbitrary provider output, remote LLMs, browser login, full MCP HTTP transport, immediate issuer-side JWT revocation, crashes in the middle of an external effect, and cross-database atomicity. Relay admission is exercised directly through its public authorization API; it does not establish MCP transport conformance. Successful restart means an orderly store stop/reopen unless a stronger failure is explicitly added and executed.

## Execution and results

Expected outcomes above were recorded before implementation as hypotheses, not package guarantees. Observations follow below.

## Observed result

- The final consumer passes all eight tests. The first seven tests covered the planned matrix and an additional stale-context write guard. Review then found an application identity-binding bug and added an eighth regression.
- A rejected Fabric action can coexist with `Finished(Completed(answer))`: the model received a refusal and completed its conversation. Business release evidence is the action in `fabric.snapshot(handle).actions` plus the application release row. Treating `Completed` alone as permission or successful release would be an application bug.
- The requester-substitution regression failed before the fix: a separately authenticated principal with its own document permission replaced the original requester in fresh context, and the action succeeded. The original tool arguments retained only document and revision. The fix persists native `Principal(issuer, subject)` in `Release`, checks equality against fresh context in policy and the write handler, and advances the agent definition to version 2. No library changed.

| Executed case | Observed outcome |
| --- | --- |
| Ordinary public document | Native `Release(document, Revision(1), requester)` round-trips through Blueprint; action `Succeeded`; one exact-content row attributed to the admitted subject |
| Advanced approval configuration | `EveryRelease` suspends even public content; a five-second proof lifetime is accepted configuration; checked approval releases once and records reviewer subject, issuer and verifier |
| Replaced content | Revision 1 approval with current revision 2 context yields action `Denied("stale document revision")`; zero release rows |
| Revoked document permission | JWT admission and proof remain valid; fresh database context yields action `Denied("current permission revoked")`; zero rows |
| Refusal and cancellation | Missing scope, forged token and wrong audience preserve distinct Relay errors; insufficient approval scope preserves `NotAuthorized`; cancelling a pending run yields `Cancelled`, and later approval yields `RunEnded` |
| Fresh durable driver | An orderly stopped store is replaced; a fresh agent and approver instance reopen the same stored approval reference; approval succeeds; a third store reads completion with zero recorded replays and one release row |
| Stale supplied context | Reusing old permission in context allows Fabric admission, but the application's SQL recheck yields `ToolFailed` and zero rows |
| Substituted authenticated requester | Before fix: unexpected `Succeeded`. After fix: `Denied("requester identity changed")` and zero rows, although the substitute has a valid token and current document permission |

The deterministic classifier is the application function `domain.classify`: `public minutes` is Public and other fixture content is Embargoed. The scripted Fabric model only selects the tool and echoes its result. These tests establish classification-to-policy composition, not model classification accuracy.

## Run and evidence

Run from this consumer directory:

```sh
nix develop ../.. --command bash run.sh
```

`run.sh` checks Gleam formatting, builds with `--warnings-as-errors`, compiles the fixture FFI with `erlc -Werror`, and runs `gleam test` through `../../apps/scripts/with-postgres.sh`. The helper creates and removes a private cluster. No existing database or account is used. Tests fail if `DATABASE_URL` is absent; they do not silently skip database evidence.

- `evidence/verification.txt` is the retained final receipt.
- `evidence/requester-regression.txt` records the behavioral failure before the application fix and the passing regression after it.
- `evidence/provenance.txt` identifies toolchain, local checkout revisions, dirty state, manifest hash and consumer source hashes. `provenance.sh` prints a fresh receipt without overwriting the retained one.
- `.artifacts/` holds ignored development logs. Routine runs write stdout and do not overwrite retained evidence.
- The PostgreSQL adapter is the nested package in the recorded Fabric checkout. This experiment uses authored fixture content and the public `warden/testing` provider from that Apache-2.0-licensed checkout; it uses no external behavioral oracle and makes no upstream conformance claim.

## Call sites and ownership

- Ordinary use is `ordinary_public_release_test`: admit the token with `auth.admit`, load native context with `archive.context`, build the agent, start a run, and inspect both its action and release rows.
- Advanced use is `configurable_approval_and_reviewer_attribution_test`: select `EveryRelease`, configure `approvers.with_proof_lifetime`, await the pending reference, obtain a proof from the shared approver instance, and call `fabric.approve` with current context.
- Durable use is `a_new_driver_resumes_durable_approval_without_duplicate_release_test`: rebuild current context and the definition, open the saved run id, read its pending reference, and answer using the new driver's configured approvers. Context is live and is not retained by Fabric.
- `Document`, `Revision`, `Principal`, `Release`, `ApprovalPolicy` and `Context` belong to this consumer. One Blueprint codec serves tool declaration, persisted arguments, output and native decoding. Only database rows and JWT claims need separate boundary decoding. No library-internal module is imported.
- Warden validates issuer, signature, time and audience. Relay checks endpoint scope and yields the application principal. The application maps checked claims to `(issuer, subject)` and owns document permission, classification, requester binding, revision comparison and the release write. Fabric stores approval/action evidence and reruns the configured policy using supplied context. `fabric_postgres` stores Fabric's records through an application-owned pool.
- The application must change revision whenever content changes. This fixture does not implement an immutable revision repository or enforce that invariant against arbitrary SQL updates.
- Fixture resource ownership is explicit: start provider, Warden client, pool, then store; stop each store before pool teardown, and stop client/provider in `finally` cleanup. Store restart preserves the pool and Warden client, so it establishes a fresh durable driver rather than a fresh operating-system process or machine.

## Ergonomics and configurability findings

- Keep typed Blueprint definitions and Fabric's separation of `Definition`, bound tool and policy. The same native `Release` reaches the handler and can be decoded for policy without an application-wide JSON union.
- Keep explicit context in `fabric.approve`. It made current permission changes straightforward to represent and exposed the stale-context mistake rather than implying that a stored proof refreshes application data.
- Keep instance-bound approvers and recorded issuer/subject. Constructing the approver once per driver and sharing it with both the agent and answer handler is an essential lifecycle decision. A newly constructed permissive verifier is not interchangeable with the configured one.
- The Warden→Relay recipe is discoverable in public documentation and composed without new adapters in any library. Endpoint scopes belong in Relay's protection; prechecking them in Warden would collapse the recipe's useful 403-style missing-scope distinction into bearer rejection.
- The application still owns two explicit authorization translations: claims→Relay attestation/principal and claims→Fabric reviewer/denial. They overlap in identity extraction, but answer different questions. This example supplies no evidence that a shared authentication framework would improve them.
- Fabric's `Completed` naming is easy to overread as business success. Smallest improvement hypothesis: add an ordinary approval example showing `await` followed by `snapshot.actions` and authoritative domain readback. Before: branch only on `Completed(answer)`. After: require `Succeeded` for the relevant action and confirm the release record. This is a documentation proposal, not a new facade implemented here.
- A second documentation improvement hypothesis is a delayed-approval checklist beside the fresh-context example: persist the business identity in typed action input and compare it with current context. Before: `Release(document, revision)` plus an arbitrary new principal. After: `Release(document, revision, requester)` and an explicit equality rule. The observed regression justifies this application recipe; it does not justify Fabric guessing which context fields are security-relevant.
- Compiler feedback was useful and local: the first attempt omitted `decode.field`'s success continuation; a later variable shadowed the `reviewer` module; the adversarial test initially used reserved identifier `delegate`. None was a missing package capability. Cold dependency compilation emitted Mist deprecation warnings; the completed application passes the strict build. Initial Nix sandbox access failure was setup evidence, not failed library behavior.

## Failure and evidence limits

- Await calls have ten-second waits. The advanced case configures a five-second proof lifetime, but does not test expiry timing. Native timeout, verifier outage and mid-write database fault injection are not executed here. Fabric and Warden retain their own configured/default callback and operation limits.
- Definite statement refusal maps to `tool.Explain`, which becomes a model-visible failure. A database query failure maps conservatively to `tool.Uncertain` because a lost reply may hide a committed write. That mapping is compiled; its fault path and subsequent reconciliation are untested.
- The SQL statement checks revision and permission in the state visible to that statement. No test establishes serialization against a concurrent revoke/content update. Classification and requester matching are application guards; Fabric cannot detect a caller supplying old business facts.
- The unique `(document, revision)` release key prevents another row. A duplicate insert currently returns `CurrentStateRefused`; there is no complete idempotent success readback or effect-crash recovery implementation. One row plus retained action evidence is the actual restart observation.
- Cancellation is tested while approval is pending, before the release body starts. It does not establish cancellation of an already executing database operation or reversal of an external effect.
- The model returns final text even after a denial. The tests deliberately inspect stored action state and database rows instead of inferring success from that text. No provider quality, browser login, remote transport, full MCP endpoint, power-loss durability or independent conformance certification is claimed.
