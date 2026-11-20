# Follow the Blueprint codec practice in the applications

<a id="adr-0041"></a>

Recorded on 2026-11-19.

## Decision

- Every application and current playground package requires JSON Blueprint
  `>= 2.1.1 and < 3.0.0` and locks 2.1.1. The compatibility probes under
  `playground/blueprint_compatibility/` keep their 1.7.1 and 1.1.0 pins: they
  are oracles whose checksums [ORACLE.md](../ORACLE.md) records.
- The applications follow the
  [codec practice guide](https://github.com/lostbean/json_blueprint/blob/main/docs/CODEC-PRACTICE.md)
  of JSON Blueprint rather than restating it:
  - A child codec is built inside its field, through `of:` or a top-level
    function, never bound with `let` above a record whose later fields would
    capture it. The extractor invoice, the clinic registration extraction and
    card codecs, the extractor job error codec and the research agent answer
    union were changed to that form.
  - A shape fixed at build time that crosses processes may use a codec
    generated from a typed definition. The extractor's Grind job payload,
    `DocumentJob`, is the generated example: the definition and the generation
    task are development modules under `test/`, the generated module is
    committed under `src/extractor/generated/`, and `gleam test` fails when the
    committed fingerprint differs from a fresh compilation of the definition.
  - Combinators remain where the generator cannot express the shape: custom
    `try_map` checks, a field that depends on an earlier decoded field, tagged
    unions and run-time data. The invoice and every other codec stay
    combinators.
- `copy_cost_test` in extractor, clinic_registration, research_agent,
  payout_desk, secure_mcp and tool_hub bounds the flat size, in bytes, of the
  codecs, tool definitions, agents, decision points and workers each
  application hands to Grind, Fabric, Relay or Decisions.

## Rationale and consequences

- A BEAM copy does not keep sharing. Before 2.1.1 each combinator callback
  retained its whole child codec, so a nested codec multiplied its copied size
  at every layer; a production consumer of these libraries ran out of memory
  copying agents, job closures and requests between processes. 2.1.1 makes the
  combinators additive, but a codec captured by a later field's continuation is
  still copied once per callback that holds the continuation.
- Measured on 2.1.0, then 2.1.1 before and after these changes: the extractor
  invoice codec copied in 877,152, 163,400 and 1,640 bytes; the research
  agent's Fabric agent in 1,527,936, 26,320 and 26,320 bytes; the tool hub's
  Fabric agent in 553,128, 63,456 and 63,456 bytes. The budgets in each
  `copy_cost_test` sit near the 2.1.1 measurements, far below the 2.1.0 sizes.
- JSON Blueprint 2.1.1 ends each generated enum encoder with a catch-all arm
  that an exhaustive enum makes unreachable, and the application gate compiles
  with warnings as errors. The extractor's generation task removes that arm
  until the generator stops emitting it; a definition that omitted a
  constructor would then fail to compile instead of passing silently.
- The generated codec's functions are module references, so its copied size
  does not grow with the shape. Generation is a development step: changing the
  definition or the payload type requires running the task and formatting its
  output before the tests pass.
