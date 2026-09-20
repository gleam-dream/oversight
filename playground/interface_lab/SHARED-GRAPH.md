<!-- THROWAWAY: Can typed references reuse one producer across a static diamond? -->

# Shared workflow dataflow

The subsequent [closed-choice experiment](CLOSED-CHOICE.md) addresses the conditional authoring question listed below.

## Decision

- Fan-out is reuse of one typed `Port(a)`. It needs no separate scheduling abstraction.
- `add` retains an existing Saga definition and returns a typed output port. `pair` records two dependencies and supplies a typed tuple to the next node.
- Each port retains its real codec. Node evaluators close over the actual child definition, rather than keeping only metadata.
- Stable caller-provided node IDs identify the eventual persisted structure. Fresh VM-local construction tokens validate port membership, including across copied builders with conflicting node IDs and output types.
- Construction tokens are not persisted or restored. They do not provide identity across BEAM nodes or restarts.
- Adding a node can only reference existing ports, so cycles cannot be constructed through this surface.
- `finish` rejects nodes outside the selected output's ancestry. A forgotten output cannot silently leave an orphan effect in the graph.
- Child step identities are scoped by graph node. The same reusable child definition can appear under distinct node IDs.

## Composition pressure

| Consumer                                            | Consequence                                                                                                |
| --------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Decode a batch once, validate and enrich, then join | Reuse one source port; preserve distinct result types at the join                                          |
| Provision a network before database and cache       | Express the diamond now; test cancellation and compensation order in the runner later                      |
| Compare current and prior revenue                   | Use domain types when swapping two same-typed values would be a bug                                        |
| Process a dynamic customer list                     | Static references are insufficient for bounded dynamic traversal; do not pretend the fixed graph solves it |
| Share a database snapshot across report queries     | A typed token expresses intended sharing, not resource lifetime or restartability                          |

## Review corrections

- Native child errors already have the graph's `e` and `u` types. Encoding with a child codec and decoding with a different graph codec would introduce a false wire-compatibility requirement, so those conversions were removed.
- Dependency inspection must resolve each reference against the full node collection, not the remaining recursion tail.
- A node-name-only membership check fails when a copied builder creates the same name with a different output type. The fresh-token check rejects that sibling port.

## Evidence

- The shared-order consumer constructs one producer, two checks, a join, and a summary: five nodes and six dependencies.
- Additional probes reject a sibling port from a copied builder, duplicate node IDs, and orphan nodes. Reusing the same child definition under distinct node IDs succeeds.
- `wrong_graph_edge` fails compilation when a source port does not match the child input type.
- The combined laboratory passed seventeen isolated consumers, eighteen intended compiler failures, and nine executable interface probe groups on Gleam 1.18.1.

## Limits and convergence

- This candidate extends the authoring experiment, not the runtime. It does not execute a scheduler, suspend an approval, restore a snapshot, or prove once-only effects.
- `Graph` is not yet accepted by `saga_checkpoint` or `saga_grind`. Do not publish both graph and sequential representations as final public APIs.
- The next integration experiment should lower this representation and sequential convenience functions into one Saga definition model. The provisional codec accessors expose the current factoring pressure.
- Conditional execution remains unproved. A closed choice should retain both branch definitions while exposing only the selected branch's common output; branch-local ports must not escape.
- The order/approval/decline flow still needs that choice representation before it can serve as the full durable-resume experiment.
- All queue admission, version compatibility, idempotency, compensation, and restart guarantees remain explicit runner obligations.
