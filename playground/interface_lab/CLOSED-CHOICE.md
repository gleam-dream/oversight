<!-- THROWAWAY: Can approval decline be a normal branch without leaking branch-local ports? -->

# Closed workflow choices

The later [ownership refinement](EXECUTION-OWNERSHIP.md) makes independent child execution explicit in these entry-point names.

## Decision

- `Choice(left, right)` carries one typed branch input.
- A selector definition can map `ApprovalResult(input, answer)` into that choice while preserving the original input.
- `choose_children` retains two existing Saga definitions and exposes only their common output port. Branch-local steps remain inside their child definition.
- Both branches must have the same native output, failure, and compensation-error types. A compiler-negative consumer checks the output requirement.
- The caller supplies the output codec explicitly. Equal native output types do not imply identical wire encodings or refinements.
- Each branch's internal step identity includes the graph node, branch side, and step ID as separate structural values.
- A normal declined result is an application outcome. It need not trigger the Saga failure and compensation path.

## Constructive boundary

- The choice node stores both branch evaluators and one routing closure.
- Routing decodes the source port's codec, selects one tagged input, and encodes that input using the selected child's codec.
- The evaluator uses that same routing closure, then calls only the selected child evaluator. Both branches encode their typed output through the caller's explicit output codec.
- `inspect_choice` exercises the stored routing closure without calling the child. It checks routing and codec adaptation; it cannot authorize a run or persist a branch selection.
- The local tagged choice codec reports malformed choices explicitly. Its schema remains unavailable because Blueprint's current schema vocabulary does not include tagged unions.

## Evidence

- `conditional_graph` constructs approval, selection, and a closed choice with three exact dependencies.
- The routing probe preserves the original order on approval, explicit false answers, and denial. It adapts the selected child input to a different wire layout and rejects an unknown choice tag.
- Branch step identities remain structural. `choice_output` rejects incompatible branch result types at compilation.
- The combined laboratory passed eighteen isolated consumers, nineteen intended compiler failures, and ten executable probe groups on Gleam 1.18.1.

## Limits

- No scheduler or child executor runs in these probes. Representation of exclusive choice does not prove exclusive effects, recovery, or cancellation behavior.
- A runner must commit selected branches and trustworthy approval state before admitting their effects.
- Inspection accepts raw values for a boundary probe. A fabricated approved value is not an approval credential.
- Snapshot compatibility, branch changes across versions, durable child handles, compensation receipts, and deduplicated signals remain runtime/lifecycle work.
- General loops and dynamic traversal remain separate requirements.
- The next structural task is to consolidate the successful sequential, shared-reference, and choice authoring shapes into one Saga definition model before promoting any package API.
