# Integration pilot progress

Started the consumer pilot from the `relay-llm-wire` integration contract.

- Dependency heads recorded: Relay `6574f38fbe34908592c71b9442942936ad7e1eac`, LLM Wire `cdfb38af290619a6fba890141b0701990691ba87`, Blueprint `d3f0708b61eddb4a4789c0476ab5384267814a51`, Sinal `dd09933e5466628f7d46fa896c389f31ba7d4cb6`.
- State: consumer, runnable roundtrip, reports, and integration scenarios are complete; all required local gates passed.

## Takeover and public API audit

The pilot contained an initial consumer, scripted TCP provider, and scenario tests from the prior implementation attempt. I preserved those files and checked their call sites against the public package facades. The requested Gleam/TDD guidance was read before source changes.

The exact dependency heads still match the requested Relay `6574f38fbe34908592c71b9442942936ad7e1eac`, LLM Wire `cdfb38af290619a6fba890141b0701990691ba87`, Blueprint `d3f0708b61eddb4a4789c0476ab5384267814a51`, and Sinal `dd09933e5466628f7d46fa896c389f31ba7d4cb6`. The first consumer run compiled but reported three assertion failures. Public API inspection confirmed that Relay validates input before the typed handler, and that its HTTP server currently drops the declared application-error value when encoding `isError`; the client only exposes the generic failure text. The scripted provider is being strengthened to parse request JSON and validate the continuation result by call ID and typed dataset fields. The initial compile and test gate is therefore baseline evidence, not acceptance.

## Consumer boundary and scenario pass

The host shares one Blueprint lookup codec between Relay and LLM Wire, declares the Relay lookup as read-only, and records only tool-name/error observations in test-owned subjects. The local provider validates the model, prompt, route, local bearer placeholder, Blueprint-derived schema, and continuation payload through standard Gleam JSON decoders. The scenarios assert handler non-execution for invalid arguments, the Relay application error encoded in MCP content, partial-stream cancellation cleanup, and absence of a provider retry. All five consumer tests pass.

## Runnable example and green consumer gates

The scripted provider now lives beside the consumer example so `gleam run`
executes the real loopback roundtrip, including the Relay HTTP tool call and
LLM Wire continuation. The run printed `A-100 has 7 Ada Lovelace notebooks.`
The consumer suite passed all five scenarios after the stronger request checks.
The missing-record scenario verifies Relay's declared error JSON crosses HTTP,
decodes through the same Blueprint codec, and continues under `call_1`.
`gleam format`, `gleam check`, and `gleam test` all pass.

## Final synchronous gates

From `playground/ecosystem_pilot`, `nix develop --command gleam format --check`
passed, `nix develop --command gleam check` passed, `nix develop --command
gleam run` passed with the final answer shown above, and `nix develop
--command gleam test` passed with 5 tests and 0 failures. From the Oversight
root, `nix flake check` passed the repository treefmt check on `aarch64-darwin`.
Nix reported that Linux and x86_64 Darwin systems were omitted as incompatible
with this host. The provider disconnect test watches for another request for
1.6 seconds before cleanup. No live provider behavior was tested.

## Declared application-error follow-up

Relay places the exact JSON serialization of a successfully codec-encoded
application error in standard MCP `isError` text content. The public client
retains that text, and the pilot decodes it with the same Blueprint codec
before continuing with the plain declared message under `call_1`. Error-codec
failures remain sanitized JSON-RPC internal errors. The invalid-arguments
scenario receives malformed function arguments from the scripted provider;
LLM Wire rejects them during schema validation, the Blueprint codec
independently rejects the payload, and Relay rejects a direct malformed call
without invoking the handler.
