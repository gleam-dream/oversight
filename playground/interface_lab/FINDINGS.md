<!-- THROWAWAY: Findings from the shared typed workflow interface experiment. -->

# Interface findings

## Question

Can one typed workflow authoring surface connect a bounded agent operation, approval, and a compensating child, while exposing local execution, durable submission, and snapshot restoration as different capabilities?

## Candidate conclusion

Keep Saga as the outer workflow authoring surface for this bounded case. Let Fabric provide an agent-shaped operation and let the durable runner provide persistence and delivery. A second Fabric graph engine is not required by this particular composition; richer agent cycles and mid-turn interruption remain unresolved.

Expose freeze/thaw as a separate checkpoint boundary around execution state. A snapshot contains data, while a fresh definition provides executable code and codecs. Restore must validate the snapshot before it can recover typed results. The type shape is plausible, but the runtime protocol remains unimplemented.

## Evidence interpretation

Verified on 2026-09-19 with Gleam 1.18.1: the complete source set and all seven source-isolated consumers compile. All ten negative fixtures fail with their intended type diagnostic. `agent-lsp` startup, capability discovery, and symbol inspection succeeded against this playground. The repository's host-system `nix flake check` passed.

The seven consumers cover shared adapters, checkpoint/restore, differing codecs across connections, standalone login, standalone model calls, observation, and the combined workflow. The ten rejected cases cover approval answers, event metadata, run handles used as outputs, local plans submitted durably, plain completion used as a compensation receipt, freezing a running execution, tool codec mismatches, unverified identities, worker inputs, and incompatible workflow connections.

- Positive compilation shows that the selected consumer interfaces compose in Gleam. Constructive codec and registration wrappers demonstrate storage of heterogeneous handlers without `Dynamic`.
- Negative examples check that consumer mistakes are rejected for the intended compiler error. They do not check runtime rejection of stale revisions, wrong definition versions, corrupt snapshots, or unauthorized signals.
- Source-isolated consumer builds show which modules a caller needs. They do not establish package release compatibility or prove an optional dependency is optional after publishing.
- Runtime `todo` boundaries are intentional. No scheduler, persistence, remote service, approval delivery, or restart behavior is executed by this experiment.

## Representation corrections found during review

Two steps can share the same Gleam type while using incompatible encoded forms. A string might be encoded directly as `Text("Ada")` or inside `Object([#("name", Text("Ada"))])`. The revised definition retains an executable edge adapter that decodes the producer's output and encodes the consumer's input. Matching type parameters alone would have missed this requirement.

Each node also retains its own error and compensation-error codecs, together with erased input/output validators. Keeping only the outer definition's codecs would lose the ability to validate intermediate approval decisions or decode a later node's error after restoration.

The structural signature is caller-asserted metadata in this playground. It is not a computed fingerprint and does not establish definition compatibility. The checkpoint capability is copyable; it is not proof of single-writer ownership.

## Approaches excluded by this interface direction

- Arbitrary local closure plans cannot be passed to durable submission as though their execution state were serializable.
- A live execution cannot be passed directly to freeze without first obtaining the checkpoint capability.
- A snapshot cannot manufacture trusted native output types merely by carrying a phantom type parameter.
- A submitted run handle cannot stand in for the workflow's completed output.
- A normal child result does not automatically grant authority or capability to compensate that child.

These exclusions apply to the proposed API and its checked examples. Gleam does not prove workflow identity uniqueness, codec laws, effect determinism, or exactly-once execution.

## Implications for the package plan

The proposed dependency direction remains useful: Saga owns workflow meaning; a checkpoint module describes execution-state persistence; `saga_grind` combines Saga with Grind's delivery; Fabric and external consumers adapt their operations into this surface. Decide whether checkpointing belongs in Saga's initial distribution only after the executable recovery experiment establishes the required representation.

Keep operation adaptation local to each integration for now. The typed function and codecs are shared; Relay, Fabric, and Grind retain their own error and lifecycle contracts. A universal task package has not earned its own boundary from this experiment.

The next evidence is the fixed-flow restart experiment described in the [playground guide](README.md#next-executable-question). Production package extraction remains premature.
