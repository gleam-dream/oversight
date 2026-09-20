<!-- THROWAWAY: Can one graph distinguish parent-owned activities from independent children? -->

# Workflow execution ownership

## Decision

- `Activity` means a direct typed operation with an optional compensator owned by the enclosing workflow.
- `Child` means an independently executed workflow boundary. It is a separate opaque type and does not acquire automatic parent compensation.
- `saga.child` returns `Child`; `define_child` replaces using `define` for that wrapper.
- Graph registration now distinguishes `add_activity`, `add_approval`, and `add_child`.
- The former `add` was always implemented through `run_child`; renaming it exposes that existing ownership rather than silently flattening it.
- `choose_children` retains independently owned branch definitions. It does not claim that branch activities share the parent's journal.
- Direct approvals return `NodeAwaitingApproval`, distinct from waiting for a child run.

## Constructive representation

- An activity adapter retains the original typed execution function, compensation policy, descriptor, and versioned codecs.
- A graph activity node decodes the upstream input and checks that the activity's input codec can encode it before invoking the scripted callback.
- The callback receives that native input. Its native error does not pass through a potentially incompatible codec roundtrip.
- A retained compensator decodes the same upstream input representation and the activity's output representation. It receives the original native input and decoded successful output.
- The future journal must preserve the input representation and codec identity that this adapter expects; this prototype does not define a durable journal format.
- Activity and approval adapters are provisional factoring surfaces. No new public universal node type is introduced.

## Evidence

- `execution_ownership` uses different source and target input wires, checks the original input/output at compensation, and distinguishes direct approval waiting.
- Error and undo-error codecs intentionally cannot serialize values in that consumer. Native callback errors still arrive unchanged, demonstrating that the direct in-process path does not require error serialization.
- `child_as_activity` fails compilation. The scripted direct-execution probe also rejects a child node rather than reaching its unfinished runner.
- Existing child, shared graph, and closed-choice consumers still compile after the explicit naming change.

## Limits and next integration

- `probe_direct` and `probe_compensation` are laboratory inspection hooks that execute only the supplied scripted callbacks. They are not proposed production scheduling APIs.
- Real activity effects, compensation ordering, concurrent siblings, journal commits, and restart behavior remain unimplemented.
- An unserializable native error is acceptable to this local callback probe; durable execution still needs an explicit encoding-failure policy.
- A child's parent-compensation capability still requires a usable receipt-issuance and lifecycle contract. This split does not fabricate one.
- Graph and sequential definitions remain separate retained experiments. Their eventual common representation must preserve these ownership distinctions rather than perform a nominal conversion that changes recovery semantics.
