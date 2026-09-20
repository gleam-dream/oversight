# Durable child attachment

## Question

- Can an application persist a child reference, reconstruct its native contract after a deployment, and recover a typed observation without persisting closures?
- This experiment covers attachment and observation through an injected owner. It does not submit jobs, resume execution, claim compensation, or demonstrate persistence across a real process restart.

## Public boundary

- Saga retains the definition and its actual input, output, error, and undo-error codecs in `ChildContract(i, o, e, u)`.
- The contract records all four boundary versions. Definition identity, definition version, and the caller-supplied structural signature remain separate compatibility assertions.
- `DurableOwner` supplies a namespace and a read operation. A configured owner is a trusted adapter; matching its namespace is not authentication or proof that two adapters share a database.
- `attach_child` binds a stored run to a contract only after checking the requested run, owner, definition, signature, and all boundary versions.
- `DurableChild(o, e, u)` retains the actual codecs needed for later observations. Callers do not supply replacement decoders to `observe_child`.
- `ChildLink` contains routing and compatibility data without native type parameters or closures. Encoding a link does not grant access to the run.
- `reattach_child` requires a fresh contract and configured owner. It checks link compatibility before reading the run, then checks the stored record before constructing the typed handle.
- `observe_child` rechecks stored metadata before decoding a terminal payload. A handle cannot silently reinterpret a record whose declared contract changed.

## Recovery and compensation

- A completed child's historical output remains separate from its compensation view. Later compensation does not rewrite the historical result.
- Undo failures decode through the retained native undo-error codec. Reconciliation evidence remains an explicit raw-value boundary.
- Missing runs, unavailable owners, unavailable retained results, and corrupt encoded results are different outcomes.
- The prototype does not prove that equal version labels describe equal codecs. Applications must change their compatibility assertions when their encoding contracts change.
- The prototype does not prove monotonically increasing revisions, retention, authorization, concurrent ownership, or linear use of a handle.

## Remaining experiments

- Submit a child idempotently and recover the command-to-run association after an ambiguous response.
- Claim compensation ownership, persist a receipt reference, and rebind its undo-error codec after recovery.
- Separate compensation request acceptance from eventual completion and reconciliation.
- Connect a parent checkpoint to a child link without making child recovery stand in for parent recovery.
- Verify retention, command deduplication, journal transactions, and actual restart behavior with a durable runner.
