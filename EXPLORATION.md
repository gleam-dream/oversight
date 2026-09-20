# Ecosystem refinement

## Purpose and current status

- The coordinated research now has a consolidated [ecosystem creation plan](ECOSYSTEM-PLAN.md). Use that plan for recommended boundaries, build/reuse choices, ordered work, and the checks that can change those recommendations; this document retains the initial inventory and exploration method.
- `oversight` coordinates the design and validation of production Gleam libraries. The existing package designs are proposals, not accepted specifications or working APIs.
- Production execution targets Erlang/OTP first, as confirmed on 2026-09-19. Pure components should remain portable where practical; JavaScript support is not a requirement for every package.
- This cycle produces an inventory, research findings, and a proposed sequence of interface experiments. Package boundaries remain open until consumer examples and compiler evidence support them.
- Production implementations follow design refinement. Type-only experiments may use explicitly unfinished bodies, but their results must not be reported as evidence of runtime correctness.

## Working principles

- A library must solve a useful problem independently. Composition must use public contracts rather than knowledge of another library's internals.
- Reuse an existing Gleam library or an Erlang/Elixir implementation when evidence supports its contract and operational requirements. A new implementation needs a specific reason beyond matching this organization's naming or coding style.
- Represent domain distinctions with custom types and validated opaque types. Strings remain appropriate for text and open protocol vocabularies; encoding and `Dynamic` belong at explicit external boundaries.
- Distinguish expected failures from process crashes and foreign exceptions. Typed errors describe recoverable outcomes; supervision and boundary handling address failures that the type checker cannot exclude.
- Define observability, cancellation, timeouts, resource ownership, and recovery alongside successful operation. Define benchmarks from the workload and operational budget rather than adding an unqualified performance claim.
- Use upstream behavior and tests as evidence. Add independent tests for the Gleam API, deliberate semantic differences, and integration failures that upstream tests cannot cover.

## Inventory

| Candidate                                                  | Intended responsibility                                                              | Starting reference                              | First unresolved question                                                                               |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------ | ----------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| [Grind](grind-design.md)                                   | Persistent jobs and queue execution                                                  | Oban; proposed scope also includes Pro features | Which exact edition, version, features, and observable behaviors define parity?                         |
| [Sinal](sinal-design.md)                                   | Typed instrumentation and BEAM telemetry interoperability                            | `:telemetry`                                    | Does typed instrumentation wrap existing execution semantics or introduce an asynchronous event system? |
| [Saga](saga-design.md)                                     | Typed dependencies, execution, compensation, and undo                                | Reactor                                         | Are static plans and runtime-authored graphs separate interfaces or separate systems?                   |
| [Relay](relay-design.md)                                   | MCP client/server behavior and transports                                            | MCP specification, conformance suite, and SDKs  | Which protocol revision and capability set form the first accepted scope?                               |
| [Warden](warden-design.md)                                 | Typed OIDC relying-party and OAuth client interface                                  | `oidcc` through FFI                             | Which guarantees belong to the backend and which remain the caller's responsibility?                    |
| [Fabric](fabric-design.md)                                 | Agent loop, provider adapters, action authorization, graph execution, and durability | BeamWeaver-style functionality                  | Which responsibilities reuse Saga, Grind, or existing libraries?                                        |
| [JSON Blueprint](https://json-blueprint.hexdocs.pm/1.1.0/) | A shared description for JSON Schema, encoding, and decoding                         | Existing user-owned library                     | Can an updated contract support runtime construction and generated definitions without semantic drift?  |

## Relationships to investigate

- JSON Blueprint is a candidate dependency for Relay tool schemas, Fabric structured output, and serialized job or workflow values. A general codec does not automatically need JSON Schema; callers should not acquire a schema dependency without a concrete use.
- Saga plans, Grind job workflows, and Fabric graphs overlap in dependency ordering. Compensation, queue scheduling, and durable review are different observable behaviors; a shared graph representation is a hypothesis rather than a requirement.
- Sinal could provide typed events across the ecosystem. Its contract must address handler failure, execution context, ordering, event loss, and compatibility with existing BEAM consumers before other packages depend on it.
- Warden's relying-party and OAuth client responsibilities overlap only partly with Relay authentication. Resource-server authorization requires its own responsibility analysis.
- Investigate whether Fabric's agent loop can consume a provider-independent model contract without losing provider-specific behavior. Study Jido's separate ReqLLM client before selecting the contract or package boundary; start with a small provider subset while testing how later adapters would fit.
- Avoid a general-purpose shared package until at least two consumer examples establish the same semantics. Similar field names do not establish interchangeable types.
- Evaluate a package split when a consumer needs independent adoption, target support, dependency selection, or release cadence. Keep a module boundary when extraction would add coordination without serving one of those needs.
- Use an order-processing scenario to compare workflow semantics: validate an order, reserve inventory, charge payment, and schedule a notification. Add an agent-assisted review only when testing suspension; do not require every library in every experiment.

## Refinement cycle

1. **Prepare.** Record each candidate's users, independent use case, external boundaries, target runtime, and known upstream references. Mark source-backed facts, proposed choices, and unanswered questions separately.
2. **Explore a bounded question.** Compare reuse, FFI, adaptation, and new implementation against the same consumer example. Gather source and test evidence through focused research agents; the coordinating agent reconciles conflicting findings.
3. **Write competing interfaces.** Express the smallest public types and consumer examples that distinguish the options. Include an existing-library consumer and a consumer that substitutes a different implementation.
4. **Check the interfaces.** Compile valid examples and verify that deliberately invalid examples fail for the intended type mismatch. Record what compilation proves and what unfinished bodies leave unknown.
5. **Resolve the question.** Retain the evidence, selected direction, rejected alternative, and remaining uncertainty. Ask the user to resolve choices that change intended scope or behavior.
6. **Repeat.** Choose the next question from the remaining uncertainty. Update affected package designs after the direction is agreed; do not treat this exploration plan as acceptance of their current APIs.

## Proposed order for today's refinement

- Establish the inventory and the Erlang/OTP target first. Locate the exact BeamWeaver repository and separate accessible upstream tests from behavior documented without an accessible test corpus.
- Examine JSON Blueprint and heterogeneous tool registration together. These questions affect Relay, Fabric, and the boundary between statically typed values and runtime-authored schemas.
- Compare Saga, Grind workflows, and Fabric graph execution through one shared consumer scenario. Describe the differences between in-process compensation, persistent jobs, and checkpointed execution before choosing a common abstraction.
- Examine Fabric's provider and agent contracts through Jido/ReqLLM and contrasting provider protocols. Decide which modules can be useful without a graph runtime, persistence backend, or authorization service; provider breadth is not a prerequisite for the first release.
- Examine Sinal's semantics and Warden/Relay's responsibility boundary. Keep protocol conformance research pinned to named revisions rather than the moving word “latest.”
- End the cycle with a proposed dependency map, explicit unresolved choices, and the next small experiment. Final package names, repository creation, and implementation scheduling come after those decisions.

## First interface experiments

| Experiment                 | Valid consumer example                                                                               | Deliberately invalid example                                                  | What remains a runtime question                                                                |
| -------------------------- | ---------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Schema and codec agreement | One typed record supplies a Relay tool schema and Fabric structured-result codec                     | A decoder or encoder for a different record cannot satisfy the typed contract | Schema validation agrees with encoding and decoding, including optional fields and constraints |
| Heterogeneous tools        | One registry contains a search tool and a notification tool with different argument and result types | A typed call passes notification arguments to the search tool                 | Registration preserves each codec/function pairing and reports malformed wire input            |
| Workflow composition       | Two branches share an upstream value and combine distinct outputs                                    | A dependency expecting an order receives a customer                           | Shared work executes once; cancellation, compensation, and retries obey their contracts        |
| Provider substitution      | An agent accepts two provider adapters and a scripted model through one public contract              | An incompatible provider result cannot satisfy the contract                   | Streaming, backpressure, usage reporting, and cancellation remain consistent                   |
| Durable suspension         | A consumer handles completion, failure, and review suspension explicitly                             | A consumer treating suspension as successful completion fails type checking   | Resume identity, duplicate replies, revision conflicts, and crash recovery work correctly      |

- Start with the schema and heterogeneous-tool experiments. Keep later experiments conditional on the questions exposed by the first pair.
- Use small separate Gleam projects with path dependencies when checking package dependency direction. A single project cannot establish that a consumer avoids unwanted package dependencies.
- Use named `todo` bodies only for interfaces whose behavior is deliberately unimplemented. A signature that compiles does not prove that a safe implementation exists; an unresolved representation question requires a later, separately scoped feasibility experiment.
- Maintain positive and negative compiler fixtures separately. A negative fixture passes only when its intended diagnostic occurs; an unrelated import or syntax failure is not evidence.
- Distinguish Gleam compilation from a library's graph-validation function. Calling `dag.compile` at application runtime is runtime validation even if the function is pure.

## Upstream evidence and later acceptance

- Classify each reference as an exact behavioral oracle, a scoped behavioral oracle, or design inspiration. “Exact” describes a named public behavior within a versioned scope, not identical internal implementation.
- Record the repository, revision, edition, license, test locations, runnable harness, selected scenarios, and intentional differences before promising parity. Public documentation of a commercial feature does not establish access or permission to reuse its implementation or tests.
- Prefer executable differential tests for observable outcomes shared with the upstream. Translate tests when language or runtime differences prevent direct execution; retain their provenance and adapt their assertions to the declared contract.
- Use protocol conformance suites for protocol behavior. Passing a backend's tests or wrapping a certified backend does not automatically confer certification or correctness on a new wrapper.
- After interface acceptance, implement through small TDD increments. Each increment starts with a failing behavior test and finishes with the relevant contract, upstream, and integration checks.
- Before release, exercise process crashes, timeouts, cancellation, duplicate delivery, retry exhaustion, storage failures, and restart recovery where applicable. Include resource bounds and observability assertions in those scenarios.
- Benchmark representative workloads against named baselines under recorded runtime and hardware conditions. Track latency distributions, throughput, memory, and recovery behavior only where they matter to the component's role.
- Treat type checks, behavioral tests, differential tests, conformance checks, fault tests, and benchmarks as distinct evidence. None substitutes for the others.

## Initial questions exposed by the drafts

- Fabric declares `List(Tool(a, r))` for agent tools. This requires one shared pair of types within a list; the design needs a typed construction boundary followed by a justified uniform invocation contract for heterogeneous tools.
- Fabric describes provider adapters as independent of the agent module while returning `agent.model.Model`. The owner of the shared model contract needs to be explicit before testing package extraction.
- Fabric describes errors returned by `dag.compile` as compile-time errors. The design needs to distinguish compiler rejection from runtime graph validation.
- Saga contains both statically typed plans and a runtime schema/type model. Their intended callers and conversion boundary need a decision before their APIs can be treated as one package contract.
- Grind's opening scope includes both Oban and Oban Pro. The parity target and available oracle evidence need to be established before “feature complete” is an acceptance criterion.
- Warden's upstream evidence cannot replace wrapper-specific tests. Its ownership table is an appropriate starting point for identifying those tests.

## Initial external findings — 2026-09-19

- [BeamWeaver](https://github.com/caudena/beam_weaver) is an Elixir implementation with public source, an Apache-2.0 license, and a test directory. Its feature set matches the reference described in Fabric, but that identification remains an inference until the design names its upstream; select and pin the relevant behaviors before deriving tests.
- [Gabsurd](https://gabsurd.hexdocs.pm/) is a candidate for investigating durable execution reuse. Compare its checkpoint, suspension, and retry contracts with the intended consumer scenario; its documented capabilities alone do not establish operational maturity or equivalence with Fabric.
- [anthropic_gleam](https://anthropic-gleam.hexdocs.pm/) and [claude](https://claude-gleam.hexdocs.pm/) are candidates for provider-client and agent-loop comparison. Investigate transport ownership, streaming, tools, and test fixtures before building equivalent components.
- [Jido's ReqLLM and LLMDB](https://jido.run/docs/reference/req-llm-and-llmdb) provide a separate LLM client and model metadata alongside the agent framework. The [provider-boundary exploration](research/llm-provider-boundary.md) examines what that separation requires and proposes a small provider subset for interface validation.
- [BEAM telemetry](https://github.com/beam-telemetry/telemetry) invokes handlers synchronously. Sinal's proposed actor-owned handler registry must specify where handlers execute before claiming equivalent behavior; an asynchronous dispatcher would introduce additional queueing and failure semantics.
- [Oban](https://github.com/oban-bg/oban), [Reactor](https://github.com/ash-project/reactor), and [oidcc](https://github.com/erlef/oidcc) expose upstream source and tests. These are candidate evidence sources, not completed differential harnesses; retain license notices when reusing material.
- The Grind proposal extends beyond the open-source Oban test corpus into Pro features. Keep those feature goals separate from demonstrated upstream test coverage until test access and permitted reuse are established.

## JSON Blueprint direction to test

- The linked [1.1.0 source](https://github.com/lostbean/json_blueprint/blob/v1.1.0/src/json/blueprint.gleam) uses the former `gleam/dynamic` decoder API. The [1.7.1 source](https://github.com/lostbean/json_blueprint/blob/v1.7.1/src/json/blueprint.gleam) is newer; its [compatibility module](https://json-blueprint.hexdocs.pm/json/blueprint/dynamic.html) preserves the decoder API removed from stdlib 0.60.
- The current descriptor combines a decoder, schema, and definitions; encoders remain separate. Updating dependency compatibility alone therefore does not establish Relay's proposed single-definition contract.
- Prefer an update experiment before replacement. Test an opaque `Codec(a)` that produces an encoder, a current [`gleam/dynamic/decode.Decoder(a)`](https://gleam-stdlib.hexdocs.pm/gleam/dynamic/decode.html), and a schema document through controlled constructors.
- Encoding makes mapping bidirectional: converting `Codec(a)` to `Codec(b)` needs both `a -> b` and `b -> a`, or an explicitly fallible alternative. Test this constraint with record fields and union variants before selecting an ergonomic builder API.
- Record optionality, explicit `null`, and unknown-field behavior as separate choices. The inspected 1.7.1 `optional_field` decoder accepts explicit `null`, while its rendered optional property does not necessarily describe `null`; snapshot tests alone cannot establish agreement.
- Later behavior tests must check round trips and agreement between decoding and an independent schema validator over the supported schema subset. Opaque constructors reduce accidental mismatches but cannot prove these laws by type checking alone.
- Runtime construction can build a `Codec(a)` for an already compiled type when the necessary typed constructors and getters are provided. A schema supplied after deployment cannot manufacture a new native Gleam type; use a runtime schema and an opaque validated value for that case.
- Keep code generation as a companion path for schemas known before application compilation. [`gleam run -m`](https://gleam.run/documentation/command-line-reference/) runs a generator module; it is not a macro phase, so the generation process must not depend on missing generated application modules.
- Evaluate [`glon`](https://hexdocs.pm/glon/glon.html) as a schema/decoder API reference and [`castor`](https://castor.hexdocs.pm/) for runtime schema representation. Neither is accepted as a replacement here; the required encoder contract remains part of the evaluation.

## Tooling preparation

- [.mcp.json](.mcp.json) configures `nix develop --command agent-lsp gleam:gleam,lsp`. The existing machine installation supplies `agent-lsp`; the project flake supplies Gleam 1.18.1 as checked on 2026-09-19.
- A disposable Gleam project passed MCP initialization, tool listing, language-server startup, and capability discovery. No library implementation or interface experiment was added to this repository during preparation.
- The current assistant session has no registered LSP tools. The project configuration and successful stdio probe do not establish that the host has loaded the registration; confirm tool availability when starting the interface experiments.
