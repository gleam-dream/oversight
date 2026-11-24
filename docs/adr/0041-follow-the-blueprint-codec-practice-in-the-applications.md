# Follow the Blueprint codec practice in the applications

<a id="adr-0041"></a>

Recorded on 2026-11-20.

## Decision

- Every application and current playground package requires JSON Blueprint
  `>= 2.2.0 and < 3.0.0` and locks 2.2.0. The compatibility probes under
  `playground/blueprint_compatibility/` keep their 1.7.1 and 1.1.0 pins: they
  are oracles whose checksums [ORACLE.md](../ORACLE.md) records.
- The applications follow the
  [codec practice guide](https://github.com/gleam-dream/json_blueprint/blob/main/docs/CODEC-PRACTICE.md)
  of JSON Blueprint rather than restating it. With a 2.2.0 minimum its rules
  on where a child codec is built and on sending built codecs no longer
  apply, and a run-time enum is built once, before the field chain; none of
  the applications builds one.
  - A shape fixed at build time whose codec is hot, long-lived or held by
    other processes may use a codec generated from a typed definition. The
    extractor's Grind job payload, `DocumentJob`, is the generated example:
    the definition and the generation task are development modules under
    `test/`, the generated module is committed under
    `src/extractor/generated/` exactly as the generator emits it and then
    formatted, and `gleam test` fails when the committed fingerprint differs
    from a fresh compilation of the definition.
  - Combinators remain where the generator cannot express the shape: custom
    `try_map` checks, a field that depends on an earlier decoded field, tagged
    unions and run-time data. The invoice and every other codec stay
    combinators.
- `copy_cost_test` in extractor, clinic_registration, research_agent,
  payout_desk, secure_mcp and tool_hub bounds the flat size, in bytes, of the
  terms each application hands to another process: Grind workers with what
  their handlers capture, Fabric agents and Relay tool lists. Each bound is set
  from a 2.2.0 measurement and fails on 2.1.1.

## Rationale and consequences

- A BEAM copy does not keep sharing, so a term costs its flat size each time
  it crosses a process. Up to 2.1.0 each combinator callback retained its whole
  child codec and a nested codec multiplied its copied size at every layer; a
  production consumer of these libraries ran out of memory copying agents, job
  closures and requests between processes. 2.1.1 made the combinators
  additive, and 2.2.0 holds each input once, so a codec copies at about its
  in-heap size wherever its children are built.
- The terms that cross, measured on 2.1.0, 2.1.1 and 2.2.0 (the Relay
  applications also moved from Relay 0.2.1 to 0.2.2 in the last step): the
  research agent's Grind worker copied in 1,604,448, 45,392 and 22,280 bytes;
  the payout desk's Relay tool list in 1,123,728, 210,528 and 86,080 bytes; the
  tool hub's Fabric agent in 553,128, 63,456 and 32,560 bytes; the clinic
  registration worker in 73,808, 32,384 and 23,552 bytes; the extractor worker
  in 84,504, 14,392 and 4,024 bytes.
- On 2.2.0 a child codec bound above the record and used by a later field
  costs little more than one built in its field (the clinic extraction codec:
  288 against 168 bytes), so the applications keep no codec-size tests for
  codecs that never cross a process.
- About 66 kB of the payout desk's tool list is the `open_payout` definition,
  whose output codec `decisions/view.codec` holds the payout schema parsed into
  a JSON value.
- The application gate builds every application with
  `gleam build --warnings-as-errors`. JSON Blueprint 2.2.0's typed generator
  guards its enum arms, so the generated module compiles without warnings.
- The generated codec's functions are module references, so its copied size
  does not grow with the shape. Generation is a development step: changing the
  definition or the payload type requires running the task and formatting its
  output before the tests pass.
- The applications still hand Fabric a built agent, copied into each run.
  Fabric 0.5's builder entry point removes that copy; adopting it replaces the
  deprecated `agent.build` across the applications and is tracked as its own
  issue.
