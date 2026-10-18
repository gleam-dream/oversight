<!-- THROWAWAY: Can one typed workflow model compose agents, approval, and restore? -->

# Ecosystem interface playground

A laboratory of candidate typed APIs. Its `lab/` modules are sketches, not the production
packages, and must not be published. The main experiment combines an agent call, approval
suspension, a compensating child workflow and a restorable continuation in one typed workflow;
smaller consumers exercise the supporting interfaces independently.

## Run

From the repository root:

```sh
nix develop --command python3 playground/interface_lab/check.py
```

The command compiles the positive sources, compiles each consumer with only its transitive
source imports, checks each negative example in an isolated project (it passes only when the
compiler rejects it with the expected diagnostic) and executes the interface probe groups through
`stress_checks`. Named `todo` expressions mark unfinished runtime boundaries and produce expected
compiler warnings; warnings-as-errors is not this experiment's acceptance gate.

The [evidence design](../../docs/design/evidence/design.typ#interface-laboratory) states what the
experiment can and cannot establish. [ADR 0009](../../docs/adr/0009-retain-executable-evidence-with-scoped-claims.md)
records why these prototypes remain as scoped evidence. The [oracle reference](../../docs/ORACLE.md)
pins the MCP schema and the exact-number checker this command compares against.
