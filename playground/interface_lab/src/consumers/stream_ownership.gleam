// THROWAWAY: Does one supplied stream history suppress duplicate cleanup and preserve callback origin?
import lab/llm
import lab/llm_stream_events as events
import lab/llm_stream_owner as owner
import lab/llm_turn as turn
import lab/value

pub type SharedContinuation {
  SharedContinuation(Int)
}

pub type SourceEvent {
  SourceText(String)
  SourceFinish
}

pub type ScriptedSource {
  ScriptedSource(provider: String, events: List(SourceEvent))
}

pub fn probe() -> Nil {
  close_suppresses_late_events()
  partial_tools_wait_for_terminal()
  malformed_event_is_terminal()
  terminal_paths_clean_up_once()
  continuation_keeps_provider_origin()
  Nil
}

fn close_suppresses_late_events() -> Nil {
  let machine = new_owner("close-case")
  let assert #(machine, [owner.ProgressDelivered(_)]) =
    owner.transition(
      machine,
      owner.Progress(events.TextDelta(events.TextBlockId("body"), "partial")),
    )
  let #(closed, close_commands) = owner.transition(machine, owner.Close)
  let assert [owner.CancelProvider, owner.CleanupTransport] = close_commands
  let assert owner.LocallyClosed = owner.status(closed)

  let assert #(closed, []) =
    owner.transition(
      closed,
      owner.Progress(events.TextDelta(events.TextBlockId("body"), "late")),
    )
  let assert #(closed, []) =
    owner.transition(closed, owner.Complete(owner.FinalText))
  let assert #(closed, []) =
    owner.transition(
      closed,
      owner.Complete(owner.ToolsRequested(SharedContinuation(0))),
    )
  let assert #(closed, []) =
    owner.transition(closed, owner.ProviderFailure(llm.TransportUnavailable))
  let assert #(_, []) = owner.transition(closed, owner.Close)
  Nil
}

fn partial_tools_wait_for_terminal() -> Nil {
  let call_id = turn.CallId("partial-call")
  let machine = new_owner("partial-tool")
  let assert #(machine, [owner.ProgressDelivered(_)]) =
    owner.transition(
      machine,
      owner.Progress(events.ToolStarted(call_id, turn.ToolName("lookup"))),
    )
  let assert #(machine, [owner.ProgressDelivered(_)]) =
    owner.transition(
      machine,
      owner.Progress(events.ArgumentsDelta(call_id, "unfinished")),
    )
  let assert #(closed, [owner.CancelProvider, owner.CleanupTransport]) =
    owner.transition(machine, owner.Close)
  let assert owner.LocallyClosed = owner.status(closed)
  Nil
}

fn malformed_event_is_terminal() -> Nil {
  let machine = new_owner("protocol-case")
  let missing_call = turn.CallId("missing")
  let #(failed, commands) =
    owner.transition(
      machine,
      owner.Progress(events.ArgumentsDelta(missing_call, "{")),
    )
  let assert [
    owner.ProtocolFailureDelivered(events.UnknownCall(reported_call)),
    owner.CancelProvider,
    owner.CleanupTransport,
  ] = commands
  let assert True = reported_call == missing_call
  let assert owner.ProtocolFailed = owner.status(failed)

  let assert #(failed, []) =
    owner.transition(
      failed,
      owner.Progress(events.TextDelta(events.TextBlockId("late"), "ignored")),
    )
  let assert #(failed, []) =
    owner.transition(failed, owner.ProviderFailure(llm.RateLimited))
  let assert #(_, []) = owner.transition(failed, owner.Close)
  Nil
}

fn terminal_paths_clean_up_once() -> Nil {
  let before_progress = new_owner("early-failure")
  let #(before_progress, early_commands) =
    owner.transition(before_progress, owner.ProviderFailure(llm.RateLimited))
  let assert [
    owner.FailureDelivered(events.BeforeProgress(llm.RateLimited)),
    owner.CleanupTransport,
  ] = early_commands
  let assert owner.TurnFailed = owner.status(before_progress)
  let assert #(_, []) = owner.transition(before_progress, owner.Close)

  let after_progress = new_owner("late-failure")
  let assert #(after_progress, [owner.ProgressDelivered(_)]) =
    owner.transition(
      after_progress,
      owner.Progress(events.TextDelta(events.TextBlockId("body"), "seen")),
    )
  let #(after_progress, late_commands) =
    owner.transition(
      after_progress,
      owner.ProviderFailure(llm.TransportUnavailable),
    )
  let assert [
    owner.FailureDelivered(events.AfterProgress(llm.TransportUnavailable)),
    owner.CleanupTransport,
  ] = late_commands
  let assert owner.TurnFailed = owner.status(after_progress)
  let assert #(_, []) = owner.transition(after_progress, owner.Close)

  let completed = new_owner("normal-terminal")
  let #(completed, completion_commands) =
    owner.transition(completed, owner.Complete(owner.FinalText))
  let assert [owner.OutcomeDelivered(events.Final("")), owner.CleanupTransport] =
    completion_commands
  let assert owner.TurnCompleted = owner.status(completed)
  let assert #(_, []) = owner.transition(completed, owner.Close)

  let limited = new_owner("limited-terminal")
  let assert #(
    limited,
    [owner.OutcomeDelivered(events.Limited("")), owner.CleanupTransport],
  ) = owner.transition(limited, owner.Complete(owner.OutputLimited))
  let assert owner.TurnCompleted = owner.status(limited)
  let assert #(_, []) = owner.transition(limited, owner.Close)
  Nil
}

fn continuation_keeps_provider_origin() -> Nil {
  let shared = SharedContinuation(17)
  let call_id = turn.CallId("same-call-id")
  let provider_a = new_owner("provider-a")
  let #(provider_a, commands_a) = start_tool_turn(provider_a, call_id, shared)
  let assert [owner.ToolTurnPending(pending_a), owner.CleanupTransport] =
    commands_a
  let assert "Checking inventory" = owner.pending_text(pending_a)
  let assert [call_a] = owner.pending_calls(pending_a)
  let assert True = call_a.id == call_id
  let result = turn.ToolSucceeded(call_id, value.Text("approved result"))

  let assert Error(owner.MissingToolResult(reported_missing)) =
    owner.prepare_continue(pending_a, [])
  let assert True = reported_missing == call_id
  let assert Error(owner.DuplicateToolResult(reported_duplicate)) =
    owner.prepare_continue(pending_a, [result, result])
  let assert True = reported_duplicate == call_id
  let unknown = turn.CallId("other-call")
  let assert Error(owner.UnknownToolResult(reported_unknown)) =
    owner.prepare_continue(pending_a, [
      turn.ToolSucceeded(unknown, value.Text("wrong call")),
    ])
  let assert True = reported_unknown == unknown
  let assert Ok(prepared_a) = owner.prepare_continue(pending_a, [result])
  let assert Ok(source_a) = owner.open(prepared_a)
  let assert "provider-a:resumed by original callback" =
    consume_source(source_a)
  let assert #(_, []) = owner.transition(provider_a, owner.Close)

  let provider_b = new_owner("provider-b")
  let #(provider_b, commands_b) = start_tool_turn(provider_b, call_id, shared)
  let assert [owner.ToolTurnPending(pending_b), owner.CleanupTransport] =
    commands_b
  let assert Ok(prepared_b) = owner.prepare_continue(pending_b, [result])
  let assert Ok(source_b) = owner.open(prepared_b)
  let assert "provider-b:resumed by original callback" =
    consume_source(source_b)
  let assert #(_, []) = owner.transition(provider_b, owner.Close)

  let panic_port: owner.ContinuationPort(SharedContinuation, ScriptedSource) =
    owner.continuation_port(fn(_continuation, _results) {
      panic as "prepare_continue must not invoke the provider callback"
    })
  let deferred_owner =
    owner.new_owner(panic_port, fn(raw) { Ok(value.Text(raw)) })
  let deferred_call_id = turn.CallId("same-call-id")
  let #(_, deferred_commands) =
    start_tool_turn(deferred_owner, deferred_call_id, shared)
  let assert [owner.ToolTurnPending(deferred_pending), owner.CleanupTransport] =
    deferred_commands
  let deferred_result =
    turn.ToolSucceeded(deferred_call_id, value.Text("approved result"))
  let assert Ok(_prepared_without_opening) =
    owner.prepare_continue(deferred_pending, [deferred_result])
  Nil
}

fn start_tool_turn(
  machine: owner.Owner(SharedContinuation, ScriptedSource),
  call_id: turn.CallId,
  continuation: SharedContinuation,
) -> #(
  owner.Owner(SharedContinuation, ScriptedSource),
  List(owner.Command(SharedContinuation, ScriptedSource)),
) {
  let tool_name = turn.ToolName("lookup")
  let assert #(machine, [owner.ProgressDelivered(_)]) =
    owner.transition(
      machine,
      owner.Progress(events.TextDelta(
        events.TextBlockId("body"),
        "Checking inventory",
      )),
    )
  let assert #(machine, [owner.ProgressDelivered(_)]) =
    owner.transition(
      machine,
      owner.Progress(events.ToolStarted(call_id, tool_name)),
    )
  let assert #(machine, [owner.ProgressDelivered(_)]) =
    owner.transition(
      machine,
      owner.Progress(events.ArgumentsDelta(call_id, "item-7")),
    )
  let assert #(machine, [owner.ProgressDelivered(_)]) =
    owner.transition(machine, owner.Progress(events.ArgumentsEnded(call_id)))
  owner.transition(machine, owner.Complete(owner.ToolsRequested(continuation)))
}

fn new_owner(
  origin: String,
) -> owner.Owner(SharedContinuation, ScriptedSource) {
  let port =
    owner.continuation_port(fn(continuation, results) {
      case continuation, results {
        SharedContinuation(17),
          [
            turn.ToolSucceeded(
              turn.CallId("same-call-id"),
              value.Text("approved result"),
            ),
          ]
        ->
          Ok(
            ScriptedSource(origin, [
              SourceText("resumed by original callback"),
              SourceFinish,
            ]),
          )
        _, _ -> Error(llm.UnsupportedCapability)
      }
    })
  owner.new_owner(port, fn(raw) { Ok(value.Text(raw)) })
}

fn consume_source(source: ScriptedSource) -> String {
  case source {
    ScriptedSource(origin, [SourceText(text), SourceFinish]) -> {
      let machine = new_owner(origin)
      let assert #(machine, [owner.ProgressDelivered(_)]) =
        owner.transition(
          machine,
          owner.Progress(events.TextDelta(
            events.TextBlockId("second-turn"),
            text,
          )),
        )
      let assert #(
        _,
        [
          owner.OutcomeDelivered(events.Final(final_text)),
          owner.CleanupTransport,
        ],
      ) = owner.transition(machine, owner.Complete(owner.FinalText))
      origin <> ":" <> final_text
    }
    _ ->
      panic as "the adapter source must contain one progress event and a terminal"
  }
}
