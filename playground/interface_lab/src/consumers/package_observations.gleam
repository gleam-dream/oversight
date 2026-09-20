// THROWAWAY: Can package-owned facts share Sinal without a universal event?
import lab/blueprint
import lab/fabric
import lab/fabric_agent as agent
import lab/fabric_observations as fabric_facts
import lab/grind
import lab/grind_observations as grind_facts
import lab/llm
import lab/llm_turn as model
import lab/saga
import lab/saga_observations as saga_facts
import lab/sinal
import lab/sinal_fields as fields
import lab/value

type Continuation {
  Continuation
}

type EmitBehavior {
  StoreEvent
  RejectEvent
}

type Emission {
  Emission(
    name: List(String),
    measurements: fields.FieldMap,
    metadata: fields.FieldMap,
  )
}

type CaptureState {
  CaptureState(events: List(Emission))
}

@external(erlang, "sinal_scripted_backend", "get")
fn get_capture_state(key: Int, default: CaptureState) -> CaptureState

@external(erlang, "sinal_scripted_backend", "put")
fn put_capture_state(key: Int, state: CaptureState) -> Nil

@external(erlang, "erlang", "unique_integer")
fn fresh_capture_key() -> Int

pub fn probe() -> Nil {
  fabric_action_facts()
  saga_execution_facts()
  grind_cancellation_facts()
  Nil
}

fn fabric_action_facts() -> Nil {
  let #(accepted_controller, report) =
    accepted_fabric_report(
      value.Text("account-7"),
      "fabric-success",
      ExecuteAction,
    )
  let fact = fabric_facts.accepted_action_fact(report)
  let assert fabric_facts.AcceptedActionMeasurements(1) =
    fabric_facts.fact_measurements(fact)
  let assert fabric_facts.AcceptedActionMetadata(
    model.CallId("fabric-success"),
    fabric_facts.ModelVisible,
  ) = fabric_facts.fact_metadata(fact)

  let #(stored_backend, stored_key) = capture_backend(StoreEvent)
  let assert Ok(Nil) = fabric_facts.emit_accepted(stored_backend, fact)
  assert_emitted(
    stored_key,
    Emission(
      ["fabric", "action", "report", "accepted"],
      fields.FieldMap([#("turn", value.Int(1))]),
      fields.FieldMap([
        #("call_id", value.Text("fabric-success")),
        #("disposition", value.Text("model-visible")),
      ]),
    ),
  )

  let #(failing_backend, _) = capture_backend(RejectEvent)
  let assert Error(sinal.BackendFailed(sinal.BackendRejected)) =
    fabric_facts.emit_accepted(failing_backend, fact)
  let assert Error(agent.DuplicateReport(_)) =
    agent.accept_report(accepted_controller, report)

  let #(_, host_failure_report) =
    accepted_fabric_report(value.Int(23), "fabric-host-failure", ExecuteAction)
  let host_failure = fabric_facts.accepted_action_fact(host_failure_report)
  let assert fabric_facts.AcceptedActionMetadata(
    model.CallId("fabric-host-failure"),
    fabric_facts.HostFailure,
  ) = fabric_facts.fact_metadata(host_failure)

  let #(_, unknown_report) =
    accepted_fabric_report(
      value.Text("account-7"),
      "fabric-unknown",
      MarkOutcomeUnknown,
    )
  let unknown = fabric_facts.accepted_action_fact(unknown_report)
  let assert fabric_facts.AcceptedActionMetadata(
    model.CallId("fabric-unknown"),
    fabric_facts.OutcomeUnknown,
  ) = fabric_facts.fact_metadata(unknown)
  Nil
}

type ActionReportMode {
  ExecuteAction
  MarkOutcomeUnknown
}

fn accepted_fabric_report(
  arguments: value.Value,
  call_id: String,
  report_mode: ActionReportMode,
) -> #(agent.Controller(Nil, Continuation), agent.ActionReport) {
  let provider =
    model.provider(
      fn(_request, _tools) {
        Ok(
          model.RequestsTools(Continuation, [
            model.ToolCall(
              model.CallId(call_id),
              model.ToolName("lookup"),
              arguments,
            ),
          ]),
        )
      },
      fn(_continuation, _results) { Ok(model.Final(value.Text("complete"))) },
    )
  let assert Ok(incarnation) = agent.trusted_incarnation("package-probe-1")
  let assert Ok(limit) = agent.max_model_turns(2)
  let assert Ok(agent.InitialPendingActions(started)) =
    agent.start(
      agent.run_id("package-observation-run"),
      incarnation,
      limit,
      provider,
      llm.Request([llm.User("inspect a record")], 128),
      fabric_registry(),
      allow_action,
    )
  let assert [action] = agent.current_actions(started)
  let assert Ok(#(inspected, agent.InvocationPrepared(prepared))) =
    agent.inspect_action(started, Nil, agent.action_identity(action))
  let report = case report_mode {
    ExecuteAction -> agent.execute_prepared(prepared)
    MarkOutcomeUnknown -> agent.report_unknown_effect(prepared, "reply lost")
  }
  // The package fact is produced only after the controller accepts this report.
  let assert Ok(next_controller) = agent.accept_report(inspected, report)
  #(next_controller, report)
}

fn fabric_registry() -> fabric.Registry(Nil) {
  let assert Ok(registry) =
    fabric.registry([
      fabric.context_tool(
        "lookup",
        blueprint.text(),
        blueprint.text(),
        blueprint.text(),
        fn(_context: Nil, account: String) { Ok("found:" <> account) },
      ),
    ])
  registry
}

fn allow_action(
  _context: Nil,
  _action: agent.ActionDescription,
) -> Result(agent.PolicyDecision, agent.PolicyError) {
  Ok(agent.Allow)
}

fn saga_execution_facts() -> Nil {
  let success_definition =
    saga.define(
      must_definition_id("package-observation-success"),
      must_saga_version(1),
      "package-observation:success",
      text_activity(
        "report.uncompensated",
        fn(input) { Ok("observed:" <> input) },
        saga.Uncompensated,
      ),
    )
  let assert Ok(success_started) =
    saga.start_local(success_definition, "batch-3")
  let #(success_terminal, success_report) = drive_local(success_started)
  let success_fact = saga_facts.execution_fact(success_report)
  let saga_facts.ExecutionMeasurements(uncompensated, no_undo_failures) =
    saga_facts.fact_measurements(success_fact)
  let assert True = uncompensated > 0
  let assert 0 = no_undo_failures
  let assert saga_facts.ExecutionMetadata(saga_facts.ExecutionSucceeded) =
    saga_facts.fact_metadata(success_fact)
  let #(stored_backend, stored_key) = capture_backend(StoreEvent)
  let assert Ok(Nil) = saga_facts.emit_finished(stored_backend, success_fact)
  assert_event_name(stored_key, ["saga", "local", "execution", "finished"])
  let #(failing_backend, _) = capture_backend(RejectEvent)
  let assert Error(sinal.BackendFailed(sinal.BackendRejected)) =
    saga_facts.emit_finished(failing_backend, success_fact)
  let assert saga.LocalExecutionFinished(_, same_report) =
    saga.advance_local(success_terminal, saga.ContinueLocal)
  let assert True = same_report == success_report

  let failure_definition = saga_failure_definition()
  let assert Ok(failure_started) =
    saga.start_local(failure_definition, "batch-4")
  let #(_, failure_report) = drive_local(failure_started)
  let failure_fact = saga_facts.execution_fact(failure_report)
  let saga_facts.ExecutionMeasurements(_, undo_failures) =
    saga_facts.fact_measurements(failure_fact)
  let assert 1 = undo_failures
  let assert saga_facts.ExecutionMetadata(saga_facts.ExecutionFailed) =
    saga_facts.fact_metadata(failure_fact)

  // Cancellation is an actual local reducer path with a completed effect and
  // a failed undo. The observation reports that returned terminal result.
  let #(cancelled_terminal, cancelled_report) = cancelled_local_report()
  let cancelled_fact = saga_facts.execution_fact(cancelled_report)
  let saga_facts.ExecutionMeasurements(cancelled_uncompensated, cancelled_undo) =
    saga_facts.fact_measurements(cancelled_fact)
  let assert 0 = cancelled_uncompensated
  let assert 1 = cancelled_undo
  let assert saga_facts.ExecutionMetadata(saga_facts.ExecutionCancelled) =
    saga_facts.fact_metadata(cancelled_fact)
  let assert saga.LocalExecutionFinished(_, same_cancelled_report) =
    saga.advance_local(cancelled_terminal, saga.ContinueLocal)
  let assert True = same_cancelled_report == cancelled_report
  Nil
}

fn cancelled_local_report() -> #(
  saga.LocalExecution(String, String, String),
  saga.LocalReport(String, String, String),
) {
  let definition =
    text_activity(
      "report.cancelled-reservation",
      fn(input) { Ok("reserved:" <> input) },
      saga.Compensate(fn(_, _) { Error("release-failed") }),
    )
    |> finish_single_activity("package-observation-cancelled")
  let assert Ok(started) = saga.start_local(definition, "batch-5")
  let assert saga.LocalWorkIssued(input_waiting, input_work) =
    saga.advance_local(started, saga.ContinueLocal)
  let assert saga.LocalExecutionPaused(after_input) =
    saga.advance_local(
      input_waiting,
      saga.CompleteLocal(saga.perform_local(input_work)),
    )
  let assert saga.LocalWorkIssued(activity_waiting, activity_work) =
    saga.advance_local(after_input, saga.ContinueLocal)
  let assert saga.LocalExecutionPaused(after_activity) =
    saga.advance_local(
      activity_waiting,
      saga.CompleteLocal(saga.perform_local(activity_work)),
    )
  drive_cancelled_local(saga.advance_local(after_activity, saga.CancelLocal))
}

fn drive_cancelled_local(
  transition: saga.LocalTransition(String, String, String),
) -> #(
  saga.LocalExecution(String, String, String),
  saga.LocalReport(String, String, String),
) {
  case transition {
    saga.LocalExecutionFinished(terminal, report) -> #(terminal, report)
    saga.LocalExecutionPaused(next) ->
      drive_cancelled_local(saga.advance_local(next, saga.ContinueLocal))
    saga.LocalWorkIssued(waiting, work) ->
      drive_cancelled_local(saga.advance_local(
        waiting,
        saga.CompleteLocal(saga.perform_local(work)),
      ))
    _ -> panic as "the cancellation probe must finish its local compensation"
  }
}

fn finish_single_activity(
  activity: saga.Activity(String, String, String, String),
  name: String,
) -> saga.Definition(String, String, String, String) {
  let #(builder, input) =
    saga.begin(blueprint.text(), blueprint.text(), blueprint.text())
  let assert Ok(#(builder, output)) =
    saga.add_activity(builder, input, must_node_id(name), activity)
  let assert Ok(definition) =
    saga.finish(
      builder,
      output,
      must_definition_id(name),
      must_saga_version(1),
      "package-observation:" <> name,
    )
  definition
}

fn saga_failure_definition() -> saga.Definition(String, String, String, String) {
  let #(builder, input) =
    saga.begin(blueprint.text(), blueprint.text(), blueprint.text())
  let reserve =
    text_activity(
      "report.reserve",
      fn(batch) { Ok("reserved:" <> batch) },
      saga.Compensate(fn(_input, _output) { Error("reserve-cleanup-failed") }),
    )
  let assert Ok(#(builder, reserved)) =
    saga.add_activity(builder, input, must_node_id("report.reserve"), reserve)
  let failing =
    text_activity(
      "report.fail",
      fn(_input) { Error("domain-failure") },
      saga.Uncompensated,
    )
  let assert Ok(#(builder, failed)) =
    saga.add_activity(builder, reserved, must_node_id("report.fail"), failing)
  let assert Ok(definition) =
    saga.finish(
      builder,
      failed,
      must_definition_id("package-observation-failure"),
      must_saga_version(1),
      "package-observation:failure",
    )
  definition
}

fn text_activity(
  name: String,
  execute: fn(String) -> Result(String, String),
  compensation: saga.Compensation(String, String, String),
) -> saga.Activity(String, String, String, String) {
  let version = must_saga_version(1)
  saga.activity(
    must_step_id(name),
    version,
    saga.ActivityContract(
      saga.VersionedCodec(version, blueprint.text()),
      saga.VersionedCodec(version, blueprint.text()),
      saga.VersionedCodec(version, blueprint.text()),
      saga.VersionedCodec(version, blueprint.text()),
    ),
    execute,
    compensation,
  )
}

fn drive_local(
  execution: saga.LocalExecution(o, e, u),
) -> #(saga.LocalExecution(o, e, u), saga.LocalReport(o, e, u)) {
  case saga.advance_local(execution, saga.ContinueLocal) {
    saga.LocalExecutionFinished(terminal, report) -> #(terminal, report)
    saga.LocalExecutionPaused(next) -> drive_local(next)
    saga.LocalWorkIssued(waiting, work) -> {
      let completion = saga.perform_local(work)
      drive_transition(saga.advance_local(
        waiting,
        saga.CompleteLocal(completion),
      ))
    }
    _ -> panic as "the bounded local probe must reach a work, pause, or report"
  }
}

fn drive_transition(
  transition: saga.LocalTransition(o, e, u),
) -> #(saga.LocalExecution(o, e, u), saga.LocalReport(o, e, u)) {
  case transition {
    saga.LocalExecutionFinished(terminal, report) -> #(terminal, report)
    saga.LocalExecutionPaused(next) -> drive_local(next)
    saga.LocalWorkIssued(waiting, work) -> {
      let completion = saga.perform_local(work)
      drive_transition(saga.advance_local(
        waiting,
        saga.CompleteLocal(completion),
      ))
    }
    _ -> panic as "the bounded work result must continue toward a report"
  }
}

fn grind_cancellation_facts() -> Nil {
  let id = grind.job_id("job-47")
  let fact = grind_facts.cancellation_fact(id, grind.JobQueued)
  let assert True = grind_facts.fact_job_id(fact) == id
  let assert grind.JobFinished(grind.JobCancelled) =
    grind_facts.fact_next_state(fact)
  let assert grind.CancelledWhileInactive = grind_facts.fact_transition(fact)
  let assert grind_facts.CancellationMeasurements("job-47") =
    grind_facts.fact_measurements(fact)
  let assert grind_facts.CancellationMetadata(
    grind_facts.CancelledWhileInactive,
    True,
  ) = grind_facts.fact_metadata(fact)

  let #(backend, key) = capture_backend(StoreEvent)
  let assert Ok(Nil) = grind_facts.emit_decided(backend, fact)
  assert_emitted(
    key,
    Emission(
      ["grind", "job", "cancellation", "decided"],
      fields.FieldMap([#("job_id", value.Text("job-47"))]),
      fields.FieldMap([
        #("transition", value.Text("cancelled-inactive")),
        #("terminal", value.Bool(True)),
      ]),
    ),
  )

  let #(rejecting_backend, _) = capture_backend(RejectEvent)
  let assert Error(sinal.BackendFailed(sinal.BackendRejected)) =
    grind_facts.emit_decided(rejecting_backend, fact)
  let assert True = grind_facts.fact_job_id(fact) == id
  let assert grind.JobFinished(grind.JobCancelled) =
    grind_facts.fact_next_state(fact)
  let assert grind.CancelledWhileInactive = grind_facts.fact_transition(fact)

  let running =
    grind_facts.cancellation_fact(
      grind.job_id("job-48"),
      grind.JobRunning(grind.NoRequest),
    )
  let assert grind.JobRunning(grind.Requested) =
    grind_facts.fact_next_state(running)
  let assert grind.CancellationRequested = grind_facts.fact_transition(running)
  let assert grind_facts.CancellationMetadata(
    grind_facts.CancellationRequested,
    False,
  ) = grind_facts.fact_metadata(running)
  Nil
}

fn capture_backend(behavior: EmitBehavior) -> #(sinal.Backend, Int) {
  let key = fresh_capture_key()
  write_captures(key, CaptureState([]))
  let backend =
    sinal.backend(
      fn(name, measurements, metadata) {
        case behavior {
          RejectEvent -> Error(sinal.BackendRejected)
          StoreEvent -> {
            record_event(key, Emission(name, measurements, metadata))
            Ok(Nil)
          }
        }
      },
      fn(_, _, _) { panic as "these probes emit only" },
    )
  #(backend, key)
}

fn record_event(key: Int, emission: Emission) -> Nil {
  let CaptureState(events) = captures(key)
  write_captures(key, CaptureState(append(events, [emission])))
}

fn assert_emitted(key: Int, expected: Emission) -> Nil {
  let CaptureState(events) = captures(key)
  let assert True = contains_event(events, expected)
  Nil
}

fn assert_event_name(key: Int, expected: List(String)) -> Nil {
  let CaptureState(events) = captures(key)
  case events {
    [Emission(name, _, _), ..] -> {
      let assert True = name == expected
      Nil
    }
    [] -> panic as "Sinal should have captured the emitted event"
  }
}

fn contains_event(events: List(Emission), expected: Emission) -> Bool {
  case events {
    [] -> False
    [event, ..rest] -> event == expected || contains_event(rest, expected)
  }
}

fn captures(key: Int) -> CaptureState {
  get_capture_state(key, CaptureState([]))
}

fn write_captures(key: Int, state: CaptureState) -> Nil {
  put_capture_state(key, state)
}

fn append(left: List(a), right: List(a)) -> List(a) {
  case left {
    [] -> right
    [item, ..rest] -> [item, ..append(rest, right)]
  }
}

fn must_definition_id(name: String) -> saga.DefinitionId {
  let assert Ok(id) = saga.definition_id(name)
  id
}

fn must_node_id(name: String) -> saga.NodeId {
  let assert Ok(id) = saga.node_id(name)
  id
}

fn must_step_id(name: String) -> saga.StepId {
  let assert Ok(id) = saga.step_id(name)
  id
}

fn must_saga_version(number: Int) -> saga.Version {
  let assert Ok(version) = saga.version(number)
  version
}
