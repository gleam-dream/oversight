# Retain Relay admission evidence against its recorded baseline

<a id="adr-0022"></a>

## Decision

- On 8 October 2026 the repository retained a separate consumer that checks Relay's admitted request deadline through public APIs. It covers buffered mounting and a real loopback listener, and a native Erlang fixture uses process monitors and sockets without importing Relay or Mist internals.
- Relay owns the contract, and its decision records own the process-ownership and client header-acquisition rules. The consumer asserts them.
- The consumer runs against its locked sources in the `experiments` profile. A local-source capture exercises an unpublished coordinated Relay change, and its results do not qualify the locked sources.

## Rationale and alternatives

- The baseline examined Relay 0.1.0, where a 40 ms timeout produced no response during a 200 ms callback hold, a second request was refused for capacity, and releasing the callback produced a success that invoked the tool. The characterization suite passed 13 tests while the separate deadline runner failed eight scenarios.
- After the accepted contract entered the normal suite, the first run had five passes and eight failures, and adding lifecycle cases produced seven passes and thirteen failures. Acceptance against the implementing revision passed the strict build, all 21 consumer tests and eight diagnostic scenarios with zero failed invariants.
- Timeouts and process termination are not termination acknowledgements, so each probe observes callback termination independently before checking recovered capacity.

## Consequences

- The evidence is compiler and native-runtime observation, not upstream MCP conformance. The listener fixture reads response headers only, the admission probes do not exercise finite streaming, and no claim covers incomplete-body bounds, slow-sender protection, production throughput, allocation, effect rollback or arbitrary child cleanup.
- The experiment introduces no public remaining-deadline or cancellation argument for application callbacks, and that port needs its own concrete consumer before a signature is chosen.
