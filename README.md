# Gleam Dream oversight

- This repository coordinates a proposed ecosystem of production Gleam libraries. Production execution targets Erlang/OTP first.
- Start with the [ecosystem creation plan](ECOSYSTEM-PLAN.md) for recommended responsibilities, sequencing, and acceptance evidence. It is a planning proposal, not evidence that the APIs compile or the libraries are implemented.
- The [exploration inventory](EXPLORATION.md) records the original intent and questions. The [research directory](research/) records source-backed findings and the limits of the inspection.
- The package documents (`grind-design.md`, `sinal-design.md`, `saga-design.md`, `relay-design.md`, `warden-design.md`, `fabric-design.md`) are rough design inputs. Their claims and pseudocode need refinement against the creation plan before implementation.
- The [interface stress exploration](playground/interface_lab/STRESS-TESTS.md) maps independent and combined use cases to compiler probes, small API corrections, and remaining design gaps.
- Use the [repository instructions](AGENTS.md) for the Nix toolchain. The retained [interface playground](playground/interface_lab/README.md) explores the proposed contracts with positive and negative compiler examples; it does not implement the production libraries.
