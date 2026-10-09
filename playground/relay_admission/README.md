# Relay admission deadline consumer

This separate consumer tests whether Relay's configured request timeout bounds
context creation and token verification. It also tests the process ownership
consequences of moving callbacks into workers. It imports only public Relay
modules; its Erlang fixture uses native process monitors and local TCP sockets.

## Run

From this directory, with the sibling repositories present:

```sh
nix develop ../.. --command gleam test
nix develop ../.. --command gleam run -m deadline_contract
```

- `gleam test` characterizes the current implementation and exercises successful
  use, application-native principals, authentication refusal, recovery, process
  ownership, disconnects, and shared budgets. These tests pass while the gap
  remains; they must change alongside its eventual correction.
- `deadline_contract` checks the proposed stronger behavior and deliberately
  exits nonzero against the recorded Relay revision. It prints every observation
  before asserting, after each scenario's fixture cleanup. It is a regression
  starting point, not a working implementation or an ecosystem release gate.
- Both commands use scripted verification and loopback HTTP. Neither requires
  credentials, a live identity provider, or a database.

## Recorded evidence

- Examined on 8 October 2026: Relay `754137581c0461189579676cb2089ad9f04eefa7`
  (0.1.0), with its local dependencies and the consumer's committed
  `manifest.toml`. The Relay working tree was unchanged.
- Toolchain: Gleam 1.18.1, Erlang/OTP 28, ERTS 16.4.0.6. Local dependency
  revisions were JSON Blueprint `cb67746f484de4a6a8f90b5955d665dee79b9b45`,
  HTTP Gun `291595db7295d80f21cfb3e123570ec7723f2acf`, and
  Sinal `c3539129ed0d80c9ade12e4c350566cb2d6c248d`; all three were clean.
- The first test compiled and failed before any production change: a 40 ms
  timeout produced no response during a 200 ms callback hold; a second request
  received 503; releasing the callback produced 200 and invoked the tool.
- The expanded characterization suite passed 13 tests. The proposed contract
  failed across all eight scenarios (four admission, two disconnect, two shared
  budget). These are native runtime observations, not upstream conformance.

| Scenario                                                                   | Observed current behavior                                                                                                                                     |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Ordinary endpoint, defaults                                                | `tools/list` returns HTTP 200                                                                                                                                 |
| Context blocked; buffered mount and real listener                          | No response within 200 ms despite a 40 ms request timeout and 20 ms cancellation grace; capacity one remains occupied                                         |
| Verifier blocked; buffered mount and real listener                         | Same result as blocked context; releasing verification admits the caller-native `AppContext` and invokes the tool                                             |
| Request after the blocked call completes                                   | Capacity recovers; `tools/list` returns 200                                                                                                                   |
| Accepted, refused, accepted token                                          | HTTP 200, 401, 200; only the accepted calls reach application logic                                                                                           |
| Client disconnect while admission is blocked                               | Callback and ordinary linked child remain alive after 200 ms; another request gets 503                                                                        |
| Release after disconnect                                                   | Tool dispatch was observed in both recorded runs; this races disconnect handling, so the characterization suite does not require that particular race outcome |
| 600 ms budget: verifier consumes 200 ms, then handler waits another 450 ms | No response at the observation point; releasing the handler still produces 200, demonstrating a fresh dispatch budget                                         |
| Subject created by a direct callback                                       | Subject belongs to the calling process                                                                                                                        |
| Same callback in a worker that returns and exits                           | Returned Subject belongs to the exited worker                                                                                                                 |
| Kill callback worker                                                       | Ordinary linked child exits; child trapping exits and detached child survive; borrowed process remains alive                                                  |

- Callback entry is acknowledged before observing the timeout window. Holding a
  barrier prevents accidental callback completion. The shared-budget case
  acknowledges both verification and handler entry.
- Fixture cleanup closes sockets, stops endpoints, and waits for monitor
  acknowledgements when stopping known test processes. A supervisor report with
  reason `killed` can result from deliberately terminating a fixture-owned Mist
  request process; it is not a failed assertion.
- The network fixture reads the HTTP response headers, not the complete body.
  A separate callback event proves tool invocation and the native tenant value.
  The consumer does not establish complete-body delivery or response flushing.

## Cause and ownership choice

- Relay acquires a request slot, then synchronously runs correlation/context and
  protected verification in the serving process. Its invocation and response
  timers start after context returns. The independent observer therefore cannot
  enforce that deadline while the serving process is inside the callback.
- [Relay ADR 0008](../../../relay/docs/adr/0008-admission-budget-remains-unresolved.md)
  owns the unresolved admission model. Its
  [HTTP implementation](../../../relay/src/relay/http.gleam) and
  [current design](../../../relay/docs/design/design.typ) remain authoritative.
  This consumer does not accept or implement a new Relay contract.

The current public configuration used by the failing case is:

```gleam
http.new_with_context(service, context_builder)
|> http.with_request_timeout(duration.milliseconds(40))
|> http.with_cancellation_grace(duration.milliseconds(20))
|> http.with_max_concurrent_requests(1)
```

The proposed behavioral change keeps that ordinary configuration useful:

```text
Current:   slot -> callback [unbounded] -> fresh 40 ms dispatch/response budget
Proposed:  slot -> callback -> dispatch -> response
                   |---------- one 40 ms deadline ----------|
                   expiry closes dispatch authority;
                   callback cleanup has a separate bounded interval
```

| Alternative                                                   | Gain                                                                               | Cost / limit                                                                                                                                         |
| ------------------------------------------------------------- | ---------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| Keep callback process affinity and require application bounds | Existing Subjects, links, and handles retain their owner                           | Every application must enforce callback limits; Relay still cannot promise an admitted-request deadline for arbitrary callbacks                      |
| Spawn only the callback and discard its worker on success     | Outer process can wait independently                                               | Changes Subject ownership and invalidates returned process-owned resources; generic child cleanup is still unproven                                  |
| Keep an explicit request owner through admission and dispatch | One deadline and one authority can suppress late admission and observe disconnects | Adds process/state ownership inside Relay; buffered callbacks no longer run in the caller's process; cleanup guarantees must be bounded and explicit |

- Recommend the third alternative as the design to settle next. The worker must
  remain alive for the admitted exchange, rather than ending when context
  creation returns. The endpoint coordinator must decide whether a returned
  admission result still has authority to dispatch; a worker must not dispatch
  independently after its deadline.
- Establish the absolute deadline when an admitted request obtains its slot,
  before application correlation, verification, or context callbacks. Dispatch
  receives the remaining duration, not the original duration. Mist's preceding
  body read remains outside this particular bound; subscription lifetime after
  successful stream establishment needs its existing separate contract.
- Before dispatch, deadline expiry should return HTTP 504 while the peer remains
  connected; disconnect should produce no response. Neither event is an invalid
  credential decision. After dispatch, preserve Relay's typed invocation outcome
  and external-effect uncertainty rather than relabeling timeout as non-execution.
- Stop accepting callback results at expiry. Retire the callback within a stated
  cleanup interval and release its capacity without waiting for voluntary return.
  Capacity accounting must include any retiring workers, or another explicit
  bound must limit them; fast disconnect/retry loops must not create an unbounded
  population during cancellation grace. The present probes do not settle that
  accounting mechanism.
- Relay can own its request process and registered lifecycle resources. It cannot
  promise to discover and stop arbitrary detached children, children trapping
  exits, or remote effects. Long-lived clients, pools, and actors should remain
  application-owned and be borrowed by callbacks; a callback-local resource
  needs an explicit cleanup owner.
- The ordinary constructors need not gain a configuration matrix. A remaining
  deadline/cancellation port for advanced callbacks needs a separate public
  consumer before its signature is selected; this experiment does not invent
  that API or make `authorization.Verifier` HTTP-specific.

A concrete caller migration concerns where a process-owned value is created.
These excerpts illustrate ownership, not a proposed new Relay API:

```gleam
// Before: this Subject belongs to whichever process invokes the callback.
http.new_with_context(service, fn(_) {
  Ok(AppContext(process.new_subject()))
})

// After: application-owned mailbox is explicitly borrowed by each context.
let replies = process.new_subject()
http.new_with_context(service, fn(_) { Ok(AppContext(replies)) })
```

- The application must keep the mailbox owner alive and receive there. Moving
  creation outside the callback is appropriate only when application lifetime is
  intended; request-local mailboxes must retain request-local ownership.
- This is an observable lifecycle change even if constructor signatures stay
  identical. The Subject and child experiments show why it needs a documented
  migration rather than an invisible timeout wrapper.

## Next implementation proof

- Start with the retained red assertions for deadline response, capacity reuse,
  late-result suppression, disconnect, and one remaining dispatch budget.
  Convert the matching current-behavior assertions when the model is implemented.
- Add a callback result arriving at the deadline boundary and repeated rapid
  disconnects. Prove no late dispatch and a bounded count of live/retiring workers.
- Add endpoint shutdown and callback failure cases. Prove registered resources
  are released, borrowed resources remain usable, and a failed request does not
  terminate the buffered mount's caller.
- Exercise a real scoped callback that calls an application-owned HTTP client
  with the remaining deadline and cancellation signal before choosing its public
  port. This will distinguish useful propagation from merely adding another
  timeout argument.
- Do not infer slowloris protection, incomplete-body bounds, streaming lifecycle
  conformance, peak allocation, production throughput, external-effect rollback,
  or arbitrary child cleanup from this consumer. None was tested here.
