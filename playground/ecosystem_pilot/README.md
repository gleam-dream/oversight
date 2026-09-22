# Cross-package integration pilot

This consumer composes the public APIs of `json_blueprint`, Relay, LLM Wire, and
Sinal. It looks up a synthetic inventory record through Relay, using the same
Blueprint codec to define Relay's tool schema, validate the LLM Wire function
arguments, and encode the typed result for the OpenAI Responses continuation.

From this directory, run the end-to-end example with:

```sh
nix develop --command gleam run
```

The example prints:

```text
A-100 has 7 Ada Lovelace notebooks.
```

It starts ephemeral loopback HTTP endpoints for Relay and the scripted
Responses provider. The provider key is a local placeholder and no request
leaves the machine.

Run the five integration scenarios with:

```sh
nix develop --command gleam test
```

The tests cover a successful lookup and continuation, invalid arguments,
missing-record failure, cancellation during a partial response, and provider
disconnect without retry. A declared Relay application error crosses HTTP as
JSON text in an MCP `isError` content block; the consumer decodes it with the
same Blueprint error codec before continuing the provider call. See
[REPORT.md](REPORT.md) for observed dependency heads, scenario evidence, and
validation results.
