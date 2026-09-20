// THROWAWAY: Does one supplied history model stream cleanup and origin-bound continuation?
import lab/llm
import lab/llm_stream_events as events
import lab/llm_turn as turn
import lab/value.{type Value}

// The closure is created by one provider adapter and retained unchanged. The
// source type is adapter-owned input for a later stream, not an ordinary turn
// reply or a claim that a live stream has been opened.
pub opaque type ContinuationPort(continuation, source) {
  ContinuationPort(
    resume: fn(continuation, List(turn.ToolResult)) ->
      Result(source, llm.CallError),
  )
}

pub fn continuation_port(
  resume: fn(c, List(turn.ToolResult)) -> Result(source, llm.CallError),
) -> ContinuationPort(c, source) {
  ContinuationPort(resume)
}

pub opaque type Owner(continuation, source) {
  Owner(
    grammar: events.State,
    decode_arguments: fn(String) -> Result(Value, Nil),
    port: ContinuationPort(continuation, source),
    lifecycle: Lifecycle(continuation, source),
  )
}

type Lifecycle(continuation, source) {
  Active
  Ended(End(continuation, source))
}

type End(continuation, source) {
  EndClosed
  EndCompleted
  EndFailed
  EndProtocolFailure
  EndWaitingForTools(Pending(continuation, source))
}

// A pure reducer value is copyable in Gleam. Separate copies can diverge; this
// type does not establish one shared runtime owner or serialize competing
// callers.
pub fn new_owner(
  port: ContinuationPort(c, source),
  decode_arguments: fn(String) -> Result(Value, Nil),
) -> Owner(c, source) {
  Owner(events.begin(), decode_arguments, port, Active)
}

// The first wave permits reuse only for tool-request turns. Final and
// output-limited continuation semantics remain an open follow-up.
pub type StreamEnd(continuation) {
  FinalText
  OutputLimited
  ToolsRequested(continuation)
}

pub type Event(continuation) {
  Progress(events.Progress)
  Complete(StreamEnd(continuation))
  ProviderFailure(llm.CallError)
  Close
}

pub type Status {
  Open
  LocallyClosed
  TurnCompleted
  TurnFailed
  ProtocolFailed
  WaitingForTools
}

pub type Command(continuation, source) {
  ProgressDelivered(events.Progress)
  OutcomeDelivered(events.Outcome)
  FailureDelivered(events.Failure)
  ProtocolFailureDelivered(events.ProtocolError)
  ToolTurnPending(Pending(continuation, source))
  CancelProvider
  CleanupTransport
}

pub fn status(owner: Owner(c, source)) -> Status {
  case owner.lifecycle {
    Active -> Open
    Ended(end) ->
      case end {
        EndClosed -> LocallyClosed
        EndCompleted -> TurnCompleted
        EndFailed -> TurnFailed
        EndProtocolFailure -> ProtocolFailed
        EndWaitingForTools(_) -> WaitingForTools
      }
  }
}

// Normal completion or provider failure requests cleanup once. Local close or
// protocol failure requests cancellation and cleanup once. These are commands
// in one reducer history only; no transport can confirm either effect here.
// Events after any terminal state are ignored.
pub fn transition(
  owner: Owner(c, source),
  event: Event(c),
) -> #(Owner(c, source), List(Command(c, source))) {
  case owner.lifecycle {
    Ended(_) -> #(owner, [])
    Active -> apply_event(owner, event)
  }
}

fn apply_event(
  owner: Owner(c, source),
  event: Event(c),
) -> #(Owner(c, source), List(Command(c, source))) {
  case event {
    Progress(progress) ->
      case events.progress(owner.grammar, progress, owner.decode_arguments) {
        Ok(grammar) -> #(Owner(..owner, grammar: grammar), [
          ProgressDelivered(progress),
        ])
        Error(error) -> protocol_failure(owner, error)
      }
    Complete(ending) -> complete(owner, ending)
    ProviderFailure(error) -> fail(owner, error)
    Close -> close(owner)
  }
}

fn complete(
  owner: Owner(c, source),
  ending: StreamEnd(c),
) -> #(Owner(c, source), List(Command(c, source))) {
  let reason = case ending {
    FinalText -> events.FinalText
    OutputLimited -> events.OutputLimited
    ToolsRequested(_) -> events.ToolsRequested
  }
  case events.complete(owner.grammar, reason) {
    Error(error) -> protocol_failure(owner, error)
    Ok(grammar) ->
      case events.terminal(grammar) {
        events.Some(events.Completed(outcome)) ->
          finish_outcome(owner, grammar, ending, outcome)
        events.Some(_) | events.None ->
          protocol_failure(owner, events.StreamTerminated)
      }
  }
}

fn finish_outcome(
  owner: Owner(c, source),
  grammar: events.State,
  ending: StreamEnd(c),
  outcome: events.Outcome,
) -> #(Owner(c, source), List(Command(c, source))) {
  case ending, outcome {
    FinalText, events.Final(_) -> #(
      Owner(..owner, grammar: grammar, lifecycle: Ended(EndCompleted)),
      [
        OutcomeDelivered(outcome),
        CleanupTransport,
      ],
    )
    OutputLimited, events.Limited(_) -> #(
      Owner(..owner, grammar: grammar, lifecycle: Ended(EndCompleted)),
      [
        OutcomeDelivered(outcome),
        CleanupTransport,
      ],
    )
    ToolsRequested(continuation), events.RequestsTools(text, calls) -> {
      let pending = Pending(owner.port, continuation, text, calls)
      #(
        Owner(
          ..owner,
          grammar: grammar,
          lifecycle: Ended(EndWaitingForTools(pending)),
        ),
        [
          ToolTurnPending(pending),
          CleanupTransport,
        ],
      )
    }
    _, _ -> protocol_failure(owner, events.StreamTerminated)
  }
}

fn fail(
  owner: Owner(c, source),
  error: llm.CallError,
) -> #(Owner(c, source), List(Command(c, source))) {
  case events.fail(owner.grammar, error) {
    Error(protocol_error) -> protocol_failure(owner, protocol_error)
    Ok(grammar) ->
      case events.terminal(grammar) {
        events.Some(events.Failed(failure)) -> #(
          Owner(..owner, grammar: grammar, lifecycle: Ended(EndFailed)),
          [
            FailureDelivered(failure),
            CleanupTransport,
          ],
        )
        events.Some(_) | events.None ->
          protocol_failure(owner, events.StreamTerminated)
      }
  }
}

fn close(
  owner: Owner(c, source),
) -> #(Owner(c, source), List(Command(c, source))) {
  #(
    Owner(
      ..owner,
      grammar: events.close(owner.grammar),
      lifecycle: Ended(EndClosed),
    ),
    [
      CancelProvider,
      CleanupTransport,
    ],
  )
}

fn protocol_failure(
  owner: Owner(c, source),
  error: events.ProtocolError,
) -> #(Owner(c, source), List(Command(c, source))) {
  #(
    Owner(
      ..owner,
      grammar: events.close(owner.grammar),
      lifecycle: Ended(EndProtocolFailure),
    ),
    [
      ProtocolFailureDelivered(error),
      CancelProvider,
      CleanupTransport,
    ],
  )
}

pub opaque type Pending(continuation, source) {
  Pending(
    port: ContinuationPort(continuation, source),
    continuation: continuation,
    text: String,
    calls: List(turn.ToolCall),
  )
}

pub fn pending_text(pending: Pending(c, source)) -> String {
  pending.text
}

pub fn pending_calls(pending: Pending(c, source)) -> List(turn.ToolCall) {
  pending.calls
}

pub type ContinueError {
  UnknownToolResult(turn.CallId)
  DuplicateToolResult(turn.CallId)
  MissingToolResult(turn.CallId)
}

// Validation is local and invokes no provider callback. A successful value
// captures the original port and continuation in a deferred, zero-argument
// callback so the adapter decides when to open the next source.
pub fn prepare_continue(
  pending: Pending(c, source),
  results: List(turn.ToolResult),
) -> Result(PreparedContinuation(source), ContinueError) {
  let expected = map(pending.calls, fn(call) { call.id })
  let supplied = map(results, turn.result_id)
  case validate_results(supplied, expected, []) {
    Error(error) -> Error(error)
    Ok(Nil) -> {
      let ContinuationPort(resume) = pending.port
      Ok(PreparedContinuation(fn() { resume(pending.continuation, results) }))
    }
  }
}

pub opaque type PreparedContinuation(source) {
  PreparedContinuation(open: fn() -> Result(source, llm.CallError))
}

// This is the callback boundary, outside the reducer. No network or transport
// behavior is supplied here; source is whatever the adapter uses to stream the
// next turn.
pub fn open(
  prepared: PreparedContinuation(source),
) -> Result(source, llm.CallError) {
  let PreparedContinuation(open) = prepared
  open()
}

fn validate_results(
  supplied: List(turn.CallId),
  expected: List(turn.CallId),
  seen: List(turn.CallId),
) -> Result(Nil, ContinueError) {
  case supplied {
    [] -> require_all(expected, seen)
    [id, ..rest] ->
      case contains(expected, id), contains(seen, id) {
        False, _ -> Error(UnknownToolResult(id))
        True, True -> Error(DuplicateToolResult(id))
        True, False -> validate_results(rest, expected, [id, ..seen])
      }
  }
}

fn require_all(
  expected: List(turn.CallId),
  supplied: List(turn.CallId),
) -> Result(Nil, ContinueError) {
  case expected {
    [] -> Ok(Nil)
    [id, ..rest] ->
      case contains(supplied, id) {
        True -> require_all(rest, supplied)
        False -> Error(MissingToolResult(id))
      }
  }
}

fn contains(items: List(a), wanted: a) -> Bool {
  case items {
    [] -> False
    [head, ..rest] ->
      case head == wanted {
        True -> True
        False -> contains(rest, wanted)
      }
  }
}

fn map(items: List(a), f: fn(a) -> b) -> List(b) {
  case items {
    [] -> []
    [head, ..rest] -> [f(head), ..map(rest, f)]
  }
}
