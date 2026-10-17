# Relay request deadline consumer

- This separate consumer checks Relay's admitted request deadline through public
  APIs. The deadline covers context creation, token verification, execution, and
  finite response waits.
- The consumer exercises buffered mounting and a real loopback HTTP listener.
  Its Erlang fixture uses native process monitors and TCP sockets without
  importing Relay internals or reading Mist records.
- Relay owns the contract in its [HTTP endpoint design](../../../relay/docs/design/design.typ).
  [ADR 0010](../../../relay/docs/adr/0010-own-admission-and-execution-under-one-deadline.md)
  records the accepted process-ownership decision.
- Client tests also exercise dynamic headers, request budgets, cancellation and
  subscription opening through native typed calls and real loopback peers.
  [ADR 0011](../../../relay/docs/adr/0011-own-client-header-acquisition-and-opening.md)
  records client callback ownership. The pinned HTTP Gun revision includes the
  additive cancellation port used by those tests.

## Run

- From Oversight, run the consumer against its immutable Git dependencies:

```sh
nix develop --command sh -c 'cd playground/relay_admission && ERL_FLAGS="+S 4:4" gleam test'
```

- For unpublished coordinated changes, use the separate
  [local-source experiment](../../docs/TESTING.md#unpublished-local-source-experiments).
  Its disposable overrides do not qualify the immutable Git baseline.

- `gleam test` checks the accepted deadline and lifecycle contract, ordinary use,
  application-native principals, refusal and recovery, and native BEAM ownership
  limits.
- `deadline_contract` prints observations from eight deadline scenarios before
  asserting the same contract. It is a diagnostic runner for assertions also
  present in the normal suite.
- Verification is scripted and HTTP uses loopback. Neither command requires
  credentials, a live identity provider, or a database.

## Consumer coverage

Client scenarios in `client_headers_test.gleam` cover:

- Blocked headers return `TimedOut(NotSent)` before their barrier is released.
  Explicit cancellation, owned-client close and caller death stop the callback;
  releasing an old barrier never dispatches the tool.
- Callback panic returns sanitized `InvalidConfig(Headers)`. The borrowed HTTP
  client remains usable for a later native `Input` to `String` call.
- Header acquisition consumes part of one request budget. Transport receives
  only the remainder, and post-dispatch failures retain `MaybeSent` evidence.
- Existing borrowed HTTP cancellation and absolute deadlines remain effective.
  Relay timeout does not cancel an application token. Borrowed-client close
  does not terminate acquisition or stop the shared pool.
- Subscription headers, HTTP opening and acknowledgement share one opening
  budget. An established stream remains readable past its relative opening
  timeout while explicit deadlines and cancellation still apply.
- A malformed notification closes the socket without requiring a separate
  close call. Repeated cancelled acquisitions terminate their workers and leave
  the shared pool usable.

Client callbacks use entry/release barriers and process monitors. A one-second
budget has a separate observation bound. The shared-budget test deliberately
spends two seconds of a three-second budget after observed callback entry.
The raw HTTP fixture reads the actual request id and acknowledges socket closure;
it imports no Relay or HTTP Gun internals. These are functional checks, not
latency or throughput benchmarks.

| Scenario                                                | Required observation                                                                                                                       |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Ordinary endpoint, defaults                             | `tools/list` returns HTTP 200                                                                                                              |
| Blocked context; buffered mount and listener            | A 120 ms deadline returns 504 before barrier release; cleanup terminates the callback and capacity recovers without its voluntary return   |
| Blocked verifier; buffered mount and listener           | The same deadline and cleanup behavior applies before a native principal is admitted                                                       |
| Late callback result                                    | Releasing the old barrier never invokes the tool                                                                                           |
| Positive context returns during cleanup grace           | After 504, a still-live callback returns its native context; the tool never starts and capacity recovers                                   |
| Retiring callback; capacity one                         | After 504, a callback still alive during its 500 ms grace retains the slot; another request gets 503 until termination                     |
| Accepted, refused, accepted token                       | HTTP 200, 401, 200; only accepted calls reach application logic with the native tenant value                                               |
| Listener disconnect during context or verification      | Cleanup terminates the blocked callback before the five-second request deadline; capacity recovers and late success never invokes the tool |
| Admission consumes 200 ms of a 600 ms budget            | A handler held for another 450 ms cannot obtain a fresh execution budget                                                                   |
| Tool policy returns after expiry                        | The positive decision cannot start the handler                                                                                             |
| Callback creates a Subject; buffered mount and listener | Its owner differs from the buffered caller, remains alive during the tool exchange, and terminates after the exchange                      |
| Endpoint stop or buffered caller death                  | Blocked admission terminates within the observation window; borrowed application actor remains usable; no late dispatch occurs             |
| Buffered callback panic                                 | HTTP 500, caller survival, and subsequent successful admission                                                                             |
| Standalone temporary-worker mechanism                   | Returning a Subject from an exited worker does not transfer its ownership                                                                  |
| Standalone process-kill mechanism                       | An ordinary linked child exits; detached and exit-trapping children survive; borrowed process remains alive                                |

- Callback entry is acknowledged before deadline or disconnect observations.
  Held barriers prevent accidental callback completion.
- A timeout response is not a termination acknowledgement. Blocked-admission probes
  observe process termination before checking recovered capacity, while the
  retirement probe separately checks capacity during cancellation grace.
- Callback termination does not acknowledge all owned work or endpoint slot
  release. Cleanup recovery polls only HTTP 503 for a fixed 200 ms window;
  HTTP 504 and other responses remain visible as failures.
- The ordinary sequential authentication control uses capacity one and requires
  HTTP 200, 401, 200 without retrying HTTP 503. A completed buffered response
  acknowledges owned-work termination and slot release.
- Admission probes use a 120 ms deadline and a 400 ms response window to allow
  cold runtime startup in successful recovery requests. These are functional
  deadline checks, not latency benchmarks.
- The stop probe observes callback termination independently of the stop call
  returning. A blocked stop call cannot conceal an overlong callback lifetime.
- Fixture cleanup closes sockets, stops endpoints, and waits for monitor
  acknowledgements when terminating known test processes. Assertions run after
  each probe's fixture cleanup.
- The callback-panic test deliberately emits a crash report. That report is
  expected; its assertions require the buffered caller to survive.

## Caller ownership

- Ordinary constructors and configuration remain sufficient:

```gleam
http.new_with_context(service, context_builder)
|> http.with_request_timeout(duration.milliseconds(120))
|> http.with_cancellation_grace(duration.milliseconds(20))
|> http.with_max_concurrent_requests(1)
```

```text
slot admission -> callback -> dispatch -> finite response
                 |---------- one deadline ----------|
expiry revokes dispatch authority and begins bounded cleanup
retiring work retains capacity until owned work terminates
```

- Correlation, context, and verification callbacks run in a managed request
  worker. Successful admission does not end that worker's lifetime.
- A callback-created Subject belongs to that worker. Only that worker may receive
  from it; retaining its lifetime does not transfer mailbox ownership to a tool
  process or the application.
- Long-lived clients, pools, and actors remain application-owned borrowed
  resources. An application-owned mailbox is created outside the callback and
  received by its application owner:

```gleam
let replies = process.new_subject()
http.new_with_context(service, fn(_) { Ok(AppContext(replies)) })
```

- Creating the Subject outside the callback is appropriate when application
  lifetime is intended. Request-local resources retain request-local ownership.
- Timeout or process termination does not prove that an external effect did not
  occur. Arbitrary detached children and children trapping exits do not become
  Relay-owned resources.

## Evidence provenance

- Acceptance against Relay `11c9c0b8c467064fe745a859efd699829abf1ff7` on
  8 October 2026 passed the strict build, all 21 consumer tests, and the eight
  diagnostic scenarios with zero failed invariants. The retained consumer
  imports the local sibling checkout, so later runs examine that checkout.
- The original red baseline examined Relay
  `754137581c0461189579676cb2089ad9f04eefa7` (0.1.0) on 8 October 2026. Consumer
  commit `cde88c5` retained the reproduction and ownership experiments.
- Before a runtime change, a 40 ms timeout produced no response during a 200 ms
  callback hold. A second request received 503, and releasing the callback
  produced HTTP 200 and invoked the tool.
- The original characterization suite passed 13 tests while the separate
  deadline runner failed across eight scenarios. After the accepted contract was
  projected into the normal suite, its initial run had five passes and eight
  failures; adding lifecycle cases produced seven passes and thirteen failures.
- The baseline used Gleam 1.18.1, Erlang/OTP 28, and ERTS 16.4.0.6. Local
  dependencies were JSON Blueprint `cb67746f484de4a6a8f90b5955d665dee79b9b45`,
  HTTP Gun `291595db7295d80f21cfb3e123570ec7723f2acf`, and Sinal
  `c3539129ed0d80c9ade12e4c350566cb2d6c248d`, with the committed consumer
  `manifest.toml`.
- These are compiler and native runtime observations. They are not upstream MCP
  conformance claims.

## Evidence limits

- The listener fixture reads response headers, not the complete body. Separate
  callback events prove tool invocation and the native tenant value.
- The server admission probes do not exercise finite SSE. Client probes cover
  subscription opening, established reads and terminal stream errors; broader
  socket handoff guarantees still require Relay's own transport tests.
- No claim is made for incomplete-body bounds, slowloris protection, complete-body
  delivery, production throughput, allocation, external-effect rollback, or
  arbitrary child cleanup.
- This consumer introduces no public remaining-deadline or cancellation argument
  for application callbacks. Such a port needs its own concrete consumer before
  selecting its signature.
