# LLM provider boundary exploration

## Question and status

- Can a standalone Gleam LLM client serve both direct callers and Fabric agents while preserving provider-specific behavior?
- The user requested this exploration before choosing the provider package boundary. A small initial provider set is sufficient, but later providers must have a credible integration path.
- This document records research and proposed experiments as of 2026-09-19. It does not accept a package split, select production providers, or authorize a provider implementation.

## Initial evidence

- Jido separates its agent layer (`jido_ai`), LLM client (`req_llm`), and model metadata (`llmdb`). ReqLLM and LLMDB are usable independently of Jido; metadata includes capabilities and context limits. [Jido reference](https://jido.run/docs/reference/req-llm-and-llmdb)
- Elixir LangChain defines a common model callback returning messages or message deltas. Its Anthropic adapter also exposes provider-specific thinking, caching, and structured-output configuration; a shared call interface does not remove these differences. [Model callback](https://langchain.hexdocs.pm/LangChain.ChatModels.ChatModel.html), [Anthropic adapter](https://langchain.hexdocs.pm/LangChain.ChatModels.ChatAnthropic.html)
- Fabric currently describes its provider module as mostly wire translation and its model port as owned by the agent module. The investigation must account for capabilities, response state, streaming lifecycle, and provider-specific options before accepting that boundary. [Current draft](../fabric-design.md)

## ReqLLM source findings

- The focused source inspection used [ReqLLM v1.24.0](https://github.com/agentjido/req_llm/tree/v1.24.0) and [Jido AI v2.3.0](https://github.com/agentjido/jido_ai/tree/v2.3.0). Jido AI's release lockfile pins ReqLLM 1.17.1, so the newer client contract is not evidence that this exact pairing was tested upstream; these are research snapshots, not selected dependencies.
- ReqLLM defines a one-interaction contract: it returns a buffered response or consumable stream, while the host owns subsequent calls and application policy. Its continuation helper matches tool results to calls without executing tools or starting another interaction. [Host integration contract](https://req-llm.hexdocs.pm/host-integration.html)
- The client normalizes outcomes, tool calls, usage, and stream events while preserving provider metadata separately. The documented portable host contract avoids branching on provider metadata keys. [Host integration contract](https://req-llm.hexdocs.pm/host-integration.html)
- The abstraction involves substantial machinery beyond HTTP encoding: provider callbacks, option translation, stateful stream decoding, response assembly, usage normalization, cancellation, and continuation handling. The inspected provider interface has roughly 18 callbacks, and the OpenAI and Anthropic adapters each exceed 1,000 source lines; these counts include documentation and are not a Gleam implementation estimate. [Provider interface](https://github.com/agentjido/req_llm/blob/v1.24.0/lib/req_llm/provider.ex), [OpenAI adapter](https://github.com/agentjido/req_llm/blob/v1.24.0/lib/req_llm/providers/openai.ex), [Anthropic adapter](https://github.com/agentjido/req_llm/blob/v1.24.0/lib/req_llm/providers/anthropic.ex)
- Jido AI's ReAct runner still recognizes OpenAI models, carries `previous_response_id` between tool rounds, and manages provider-specific WebSocket sessions. Package separation therefore does not establish that every advanced feature can use a provider-independent host path. [Pinned runner](https://github.com/agentjido/jido_ai/blob/v2.3.0/lib/jido_ai/reasoning/react/runner.ex)
- A suitable hypothesis for Gleam is a portable common path plus explicit provider-specific integration modules. Requiring every advanced session feature to fit the common path could either lose behavior or make the common contract unnecessarily large.

## Upstream tests worth adapting

| ReqLLM v1.24.0 source                                                                                                                  | Evidence to derive                                                                                  |
| -------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| [Host contract](https://github.com/agentjido/req_llm/blob/v1.24.0/test/contracts/host_integration_contract_test.exs)                   | Common OpenAI/Anthropic response behavior and tool continuation                                     |
| [Continuation](https://github.com/agentjido/req_llm/blob/v1.24.0/test/req_llm/context_tool_continuation_test.exs)                      | Call/result matching and preservation of provider-required reasoning metadata through serialization |
| [Stream response](https://github.com/agentjido/req_llm/blob/v1.24.0/test/req_llm/stream_response_test.exs)                             | Fragmented and multiple tool calls, malformed arguments, ordering, and stream ownership             |
| [Streaming retry](https://github.com/agentjido/req_llm/blob/v1.24.0/test/req_llm/streaming/retry_test.exs)                             | Retry before output begins and refusal to restart silently after partial output                     |
| [Streaming orchestration](https://github.com/agentjido/req_llm/blob/v1.24.0/test/req_llm/integration/streaming_orchestration_test.exs) | Cancellation and cleanup during complete and partial consumption                                    |

- Source inspection identified these scenarios; this exploration did not run the upstream test suite. ReqLLM's Apache-2.0 license permits reuse subject to its terms and notices.

## Proposed responsibility boundary

| Responsibility                                                               | Candidate owner                                                       | Question to validate                                                        |
| ---------------------------------------------------------------------------- | --------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Common messages, tool-call identifiers, response outcomes, and stream events | Standalone LLM contract                                               | Which meanings survive translation without losing information?              |
| Provider request encoding, response decoding, and provider-specific options  | Provider adapter                                                      | Can a new adapter be added without modifying the agent loop?                |
| Connections, transport deadlines, cancellation, and bounded buffering        | Client transport                                                      | Who releases resources when the consumer stops or crashes?                  |
| Model capability metadata                                                    | Small injected catalog or separate metadata library                   | How are unknown and stale capabilities handled?                             |
| Tool execution, approvals, loop budgets, and workflow recovery               | Agent or workflow runtime                                             | Can the client represent a tool request without executing application code? |
| Persisting conversation and continuation state                               | Consumer's durable runtime, using client-supplied codecs where needed | What state is portable, provider-bound, or version-dependent?               |

- A provider-hosted tool is different from an application tool requested by a model. Represent their outcomes separately so the agent does not execute an already completed remote action again.
- Separate a client retry within one call from an agent retry of a logical step. Define behavior after partial output before adding either policy; retrying can duplicate output or repeat a provider-side action.
- A normalized conversation is not proof that it can continue on another provider. Provider-bound continuation data may require retaining the original adapter or returning an explicit incompatibility result.

## Gleam interface hypotheses

- Keep the common contract small, but include observable outcomes beyond text (tool requests, completion reason, usage availability, refusal or failure where applicable).
- Use typed provider-specific configuration at adapter construction. A configured adapter can close over those options while exposing the common operation to the agent; the core need not define an option variant for every provider.
- Preserve opaque provider-owned continuation data through the client boundary. Do not require ordinary application handlers to inspect raw JSON to continue a conversation.
- Model unsupported features and incompatible option combinations as explicit errors. Do not silently discard a requested feature to make two providers appear interchangeable.
- Distinguish known capability constraints from remotely determined support. Types can validate local request structure; runtime-selected models still require validation and honest failure outcomes.
- Treat schema support as a provider capability with a declared subset. Reusing JSON Blueprint does not establish that every provider accepts every generated schema keyword.
- Keep a full model catalog optional during the first experiment. Test the contract with a few explicit model descriptions and an unknown model rather than introducing continuous catalog maintenance immediately.

## Small initial exploration

- Compare two different protocol families, provisionally OpenAI Responses and Anthropic Messages. This is an investigation choice, not a commitment to ship both first.
- Restrict initial consumer examples to text, application tool calls, structured results, and streaming. Investigate one provider-specific option and one continuation requirement to expose limits of normalization.
- Add a scripted third adapter with a missing capability and an unfamiliar extension. This tests whether extensibility works beyond two built-in provider cases without implementing a third integration.
- Compile a standalone client consumer and a Fabric agent consumer against the same public contract. The standalone consumer must not import agent, workflow, or persistence modules.
- Keep direct use of an existing Gleam client, a narrow ReqLLM FFI adapter, and a native Gleam client in the comparison. Evaluate Elixir runtime/dependency packaging and exception translation before treating FFI as the simplest option.

## Evidence required before choosing the package boundary

| Scenario                                    | Interface evidence now                                        | Behavioral evidence later                                                     |
| ------------------------------------------- | ------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Replace one configured adapter with another | Ordinary caller and agent signatures remain usable            | Supported common requests preserve their declared meaning                     |
| Use a provider-specific feature             | Typed adapter construction contains the option                | The request encodes it correctly or rejects it explicitly                     |
| Request an unsupported capability           | Caller handles an explicit failure alternative                | No silent option removal or undocumented fallback occurs                      |
| Receive multiple streamed tool calls        | Event types preserve call identity and partial argument state | Interleaving and fragmented JSON reconstruct correctly within resource bounds |
| Stop after partial output                   | The stream has explicit cancellation and terminal outcomes    | Resources are released and retries do not conceal duplicate output            |
| Continue after a tool result or restart     | Continuation data has an owner and a serialization contract   | Provider-required state survives, or restoration fails explicitly             |

- Reuse upstream test scenarios only after recording the exact source revision and license. Common adapter laws and provider-specific fixtures are separate test groups.
- A successful signature experiment supports the API boundary only. Stream cancellation, retry safety, lossless continuation, and resource bounds remain unproven until their behavioral tests run.
- Prefer a standalone client only if these examples support independent use without pervasive provider checks in the agent. If they do not, refine the contract before deciding whether the modules should remain within Fabric.

## Backend recommendation after the ecosystem review

- Use a small Gleam contract/core and separately selectable provider adapters. First attempt narrow reuse of [`anthropic_gleam` 0.1.1](https://anthropic-gleam.hexdocs.pm/) through its public sans-I/O and incremental stream APIs; its high-level streaming convenience buffers results and must not define the real-time client contract.
- Accept that reuse only if the adapter passes the common Anthropic fixtures without internal imports, including partial tool arguments, cancellation, error mapping, and continuation preservation. Otherwise implement the narrow wire adapter natively; do not weaken the common contract to keep the dependency.
- ReqLLM can be wrapped without requiring the consumer to author a Mix project: current Gleam accepts Mix packages as dependencies and supports external Elixir function calls. An adapter still needs to prove clean builds, application startup, release packaging, exception translation, and stream ownership; Elixir is an additional build dependency. [Gleam configuration reference](https://gleam.run/documentation/gleam-toml-reference/), [Elixir interoperability](https://gleam.run/frequently-asked-questions/)
- Keep ReqLLM as a behavioral oracle and optional backend initially. Reconsider it for broader provider coverage only after a clean Gleam consumer and the shared buffered/streaming/tool/continuation suite pass for both initial protocol families.
- Keep [`claude_gleam`](https://claude-gleam.hexdocs.pm/) as a behavior comparator. Its integrated agent loop and string-based tool handler do not supply the intended shared typed contract without additional adaptation, so they are not the default foundation.
