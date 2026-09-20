# Package observations

This experiment projects facts returned by Fabric, Saga, and Grind into the
existing Sinal event/field interface. Each package keeps its own measurement,
metadata, and disposition types; there is no shared lifecycle event type.

| Package | Logical event                    | Measurements                          | Metadata                                                                |
| ------- | -------------------------------- | ------------------------------------- | ----------------------------------------------------------------------- |
| Fabric  | `fabric/action/report/accepted`  | model turn                            | call ID and model-visible, host-failure, or outcome-unknown disposition |
| Saga    | `saga/local/execution/finished`  | uncompensated and undo-failure counts | succeeded, failed, or cancelled disposition                             |
| Grind   | `grind/job/cancellation/decided` | job ID                                | closed cancellation transition and terminal flag                        |

The Fabric consumer emits only after `accept_report` returns `Ok`. It also
forces Sinal emission to fail and then confirms that accepting the same report
again still returns `DuplicateReport`. The event contains the observable turn
and call ID subset; the accepted report retains the complete action identity.
The subset is not a unique identity across runs.

The Saga consumer drives real local work to succeeded and failed reports, then
issues `CancelLocal` after an activity has completed and follows its failing
compensation to a cancelled report. The observations retain uncompensated and
undo-failure counts, and failed emission does not change the terminal report.
The Grind consumer uses the existing pure `cancellation_transition(JobQueued)`
result and verifies that rejected emission leaves its job ID, next state, and
decision unchanged. It does not claim to load or persist queue state.

All three paths use Sinal's current codec-backed fields and injected backend.
The field maps are prototype data, not Erlang telemetry maps. This experiment
adds no shared event vocabulary, command callback, package instrumentation,
transport, storage, scheduler, or native telemetry bridge.
