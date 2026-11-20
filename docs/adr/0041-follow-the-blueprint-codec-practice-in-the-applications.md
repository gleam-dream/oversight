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
    capture it. The extractor invoice and the clinic registration extraction
    and card codecs captured a child codec that way and were changed. The
    extractor job error codec and the research agent answer union used their
    `let`-bound child only in the first field or variant, where nothing
    captures it; they were rewritten in the same form for consistency.
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
  terms each application hands to another process: Grind workers with what
  their handlers capture, Fabric agents and Relay tool lists. Where a codec
  that never crosses a process was fixed, a labelled codec-size guard fails if
  the capture returns. Each bound tied to a fix fails on the code before it.

## Rationale and consequences

- A BEAM copy does not keep sharing. Before 2.1.1 each combinator callback
  retained its whole child codec, so a nested codec multiplied its copied size
  at every layer; a production consumer of these libraries ran out of memory
  copying agents, job closures and requests between processes. 2.1.1 makes the
  combinators additive, but a codec captured by a later field's continuation is
  still copied once per callback that holds the continuation.
- Measured on 2.1.0 and on 2.1.1: the research agent's Grind worker copied in
  1,604,448 and 45,392 bytes, the payout desk's Relay tool list in 1,123,728
  and 210,528 bytes, the tool hub's Fabric agent in 553,128 and 63,456 bytes,
  and the clinic registration worker in 73,808 and 32,384 bytes. Most of the
  saving is the upgrade itself.
- The application fixes shrink the codecs they touch, not what crosses: the
  extractor invoice codec went from 163,400 to 1,640 bytes on 2.1.1, but it is
  built inside the output codec's later field, so the extractor worker copies
  in 14,392 bytes either way. The generated job input codec is what took that
  worker from 16,552 to 14,392 bytes.
- The payout desk's tool list stays at about 210 kB because its `open_payout`
  output codec, `decisions/view.codec`, captures the payout codec in later
  fields. That is owned by json_blueprint's
  [record continuation issue](https://github.com/lostbean/json_blueprint/blob/main/issues/record-copy-cost/issues/01-hold-a-record-continuation-once.md)
  and decisions'
  [copy-cost issue 31](https://github.com/gleam-dream/decisions/blob/main/issues/first-applications-findings/issues/31-an-isolated-model-is-copied-into-every-call.md).
- JSON Blueprint 2.1.1 ends each generated enum encoder with a catch-all arm
  that an exhaustive enum makes unreachable, and the application gate compiles
  with warnings as errors. The extractor's generation task removes that arm
  until the generator stops emitting it; a definition that omitted a
  constructor would then fail to compile instead of passing silently.
- The generated codec's functions are module references, so its copied size
  does not grow with the shape. Generation is a development step: changing the
  definition or the payload type requires running the task and formatting its
  output before the tests pass.
