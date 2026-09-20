# Durable child admission and cancellation

## Question

- Can an application submit a typed child, reconcile a lost acknowledgement against the original owner, and request cancellation without confusing intent with the child's outcome?
- The experiment extends the same durable owner used for attachment and observation. It introduces no second workflow definition or runner.

## Submission boundary

- Preparation encodes input once and retains the exact submission request with the actual output, error, and undo-error codecs.
- The request carries stable command identity, definition identity and version, structural signature, boundary codec versions, and retention configuration.
- A prepared request is not a run handle. Encoding success grants no authority to observe an admitted child.
- The configured owner supplies read, submit, and cancellation callbacks. The adapter owns atomic lookup, command deduplication, admission, and commit.
- A successful reply identifies new admission or replay and carries the exact accepted request with stored-run metadata. The public boundary checks request equality and compatibility before constructing a typed child.
- An ambiguous reply returns no child handle. Its recovery value retains the original owner route and exact prepared request.
- A success reply with an invalid receipt or incompatible stored metadata also retains that recovery value. An unusable reply does not prove that admission failed.
- Explicit retry rejects another owner route before invoking its callback. A replacement adapter with the same route can reconcile the request after reconnecting.
- A failed retry does not resolve an earlier uncertain commit. The caller retains its recovery value until an authoritative receipt or reconciliation establishes the original outcome.
- Matching owner identifiers are routing assertions, not authentication or proof that adapters share storage. A trusted adapter can still return false records.
- Prepared and recovery values are copyable. These types do not prevent a caller from deliberately submitting an original request to another independent owner.

## Cancellation boundary

- Cancellation uses the child's retained routing link and a stable command identity.
- Recorded intent, repeated intent, an already terminal child, and a missing target remain distinct.
- A recorded revision acknowledges the owner's decision. It does not mean that work stopped or that an external effect was rolled back.
- Unknown cancellation preserves the child and command for reconciliation. It does not manufacture a cancelled observation.
- A completed child's historical output remains observable after a cancellation request finds it already terminal.

## Acceptance boundary

- The consumer retains immutable submission receipts across a simulated lost acknowledgement. Replay and conflicts in input or retention follow from recorded requests; several commands retain their own receipts.
- The probe retries after unavailability, rejects another owner before its callback, and recovers the original child after an invalid successful reply.
- Cancellation probes map configured owner outcomes and preserve historical output. They do not establish cancellation races or durable cancellation-command deduplication.
- Compiler-negative consumers reject prepared and uncertain requests as admitted handles and preserve the prepared native output type.
- Owner callbacks remain a scripted trust boundary. The experiment cannot establish transactions, concurrent deduplication, outbox delivery, storage survival, or process recovery.
- The uncertainty value retains codec closures in memory. Persisting an unfinished submission and rebinding it after a process restart remain separate work.
- Compensation claim issuance, receipt rebinding, asynchronous compensation, and journal pruning remain separate experiments.
- Local execution, durable graph scheduling, snapshot codecs, definition migration, and parent recovery remain open even when this child boundary composes.
