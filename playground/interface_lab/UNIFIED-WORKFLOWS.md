# One workflow definition

## Question

- Can sequential workflows, shared DAG references, direct operations, and closed choices produce one definition accepted by both checkpoint and durable-admission interfaces?

## Representation

- Saga owns the opaque builder, typed ports, private nodes, and one `Definition` representation.
- The separate `saga_graph` representation is removed. Graph consumers use Saga directly.
- Singleton activity and approval definitions use the same builder and finalization path as shared graphs.
- `finish` accepts definition identity, version, and the laboratory structural signature and returns the canonical definition.
- Direct activities retain their typed callbacks and compensation. Approvals retain an explicit suspension outcome. Child nodes retain independent execution ownership.

## Composition

- Sequential composition clones construction tokens for each occurrence. Reusing one definition does not reuse its construction membership.
- Sequential composition adds a real decode-then-encode boundary between the first output codec and the second input codec.
- Sequential composition does not insert an independent child workflow around either operand.
- Stable addresses preserve sequence occurrence and nested choice scope structurally. Fresh construction tokens do not enter persisted identities.
- Name-only inspection rejects ambiguous repeated names instead of selecting an arbitrary occurrence.
- Metadata retains step and codec versions and identifies synthetic boundaries separately from application operations.
- Snapshot step references and completion order use structured step identities. Branch selections retain the choice address and typed branch side.

## Validation boundary

- The unified consumer and migrated graph consumers check the shared public type, repeated-definition composition, wire conversion, and structured metadata.
- The existing source-isolation and intended compiler-failure gate remains the acceptance boundary for this wave.
- No scheduler, child runner, queue admission, checkpoint serializer, or restart behavior is implemented by this representation change.

## Remaining obligations

- Structural signatures remain caller assertions in this laboratory. They are not computed fingerprints.
- Sequence grouping contributes to stable addresses. Reassociating a definition is a structural change for persisted state, even when its business result is equivalent.
- Synthetic node format versions are laboratory policy, not a production migration contract.
- Child attachment, compensation-receipt issuance, definition migration, and operational recovery remain subsequent experiments.

## Registration cleanup

- Activities retain one typed factory. Approvals retain their descriptor and codecs. Both lower into canonical nodes when attached to a builder.
- The unused erased registration callbacks and their obsolete public failure types are removed. Existing typed callback, compensation, approval, and codec probes remain the verification evidence.
