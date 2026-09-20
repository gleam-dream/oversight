<!-- THROWAWAY: Can durable codec metadata be reused without positional version drift? -->

# Typed activity contracts

## Decision

- `activity` accepts five arguments: step identity, step version, a typed contract, execution function, and compensation policy.
- `ActivityContract(input, output, error, undo_error)` groups the four persisted boundaries.
- Each boundary is a `VersionedCodec(version, codec)`, so the revision sits beside the codec it describes.
- Public immutable records suffice because `Version` and `Codec` already enforce their constructor invariants.
- A caller can reuse a contract across activities with the same boundary types while giving each activity its own identity, version, function, and compensation.
- Blueprint remains version-free. These versions describe Saga's persisted operation boundary rather than a universal JSON Schema revision.

```gleam
let contract = saga.ActivityContract(
  input: saga.VersionedCodec(v1, request_codec),
  output: saga.VersionedCodec(v2, response_codec),
  error: saga.VersionedCodec(v1, failure_codec),
  undo_error: saga.VersionedCodec(v3, undo_failure_codec),
)
saga.activity(step_id, operation_version, contract, execute, compensation)
```

## Evidence

- All previous activity consumers use the new signature; no compatibility wrapper retains the old twelve-argument API.
- `activity_contract` uses four different codec versions and a separate step version, then inspects the stored descriptor to catch slot swaps.
- `contract_output` fails compilation when the handler's output disagrees with the contract's output codec.
- The underlying node evaluator and compensation adapter retain their previous behavior.

- The combined laboratory passed nineteen isolated consumers, twenty intended compiler failures, and eleven executable probe groups on Gleam 1.18.1.

## Remaining boundaries

- Types bind a version to a codec value; they do not prove migration compatibility or that callers increment versions when wire formats change.
- Approval needs a separate contract because an answer is not the same boundary as the eventual retained-input result.
- Child registration still repeats codec versions. It should inherit a complete boundary contract from the definition once the common definition representation exists.
- Graph construction still needs an explicit distinction between direct activities in a parent journal and independently managed children. A nominal conversion between graph types cannot establish those semantics.
- This refinement changes authoring ergonomics, not execution, durability, or compensation guarantees.
