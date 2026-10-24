// THROWAWAY: A pure stream grammar, not a socket/actor owner or provider parser.
import lab/llm
import lab/llm_turn as turn
import lab/value.{type Value}

pub type TextBlockId {
  TextBlockId(String)
}

pub type Progress {
  TextDelta(TextBlockId, String)
  ToolStarted(turn.CallId, turn.ToolName)
  ArgumentsDelta(turn.CallId, String)
  ArgumentsEnded(turn.CallId)
}

type ToolBuffer {
  Collecting(turn.CallId, turn.ToolName, String)
  Decoded(turn.ToolCall)
}

pub type Failure {
  BeforeProgress(llm.CallError)
  AfterProgress(llm.CallError)
}

pub type ProtocolError {
  DuplicateCall(turn.CallId)
  UnknownCall(turn.CallId)
  ArgumentsAlreadyEnded(turn.CallId)
  InvalidArguments(turn.CallId)
  IncompleteCall(turn.CallId)
  NoToolCalls
  UnexpectedToolCalls
  StreamTerminated
}

pub type StopReason {
  FinalText
  OutputLimited
  ToolsRequested
}

pub type Outcome {
  Final(String)
  Limited(String)
  RequestsTools(text: String, calls: List(turn.ToolCall))
}

pub type Terminal {
  Completed(Outcome)
  Failed(Failure)
  ConsumerClosed
}

pub opaque type State {
  State(
    observed: Bool,
    text: String,
    tools: List(ToolBuffer),
    terminal: Option(Terminal),
  )
}

pub type Option(a) {
  None
  Some(a)
}

pub fn begin() -> State {
  State(False, "", [], None)
}

pub fn progress(
  state: State,
  event: Progress,
  decode_arguments: fn(String) -> Result(Value, Nil),
) -> Result(State, ProtocolError) {
  case state.terminal {
    Some(_) -> Error(StreamTerminated)
    None ->
      case event {
        TextDelta(_, text) ->
          Ok(State(..state, observed: True, text: state.text <> text))
        ToolStarted(id, name) ->
          case has_call(state.tools, id) {
            True -> Error(DuplicateCall(id))
            False ->
              Ok(
                State(
                  ..state,
                  observed: True,
                  tools: append(state.tools, [Collecting(id, name, "")]),
                ),
              )
          }
        ArgumentsDelta(id, fragment) ->
          case
            update_buffer(state.tools, id, fn(name, existing) {
              Ok(Collecting(id, name, existing <> fragment))
            })
          {
            Ok(tools) -> Ok(State(..state, observed: True, tools: tools))
            Error(error) -> Error(error)
          }
        ArgumentsEnded(id) ->
          case
            update_buffer(state.tools, id, fn(name, raw) {
              case decode_arguments(raw) {
                Ok(arguments) -> Ok(Decoded(turn.ToolCall(id, name, arguments)))
                Error(Nil) -> Error(InvalidArguments(id))
              }
            })
          {
            Ok(tools) -> Ok(State(..state, observed: True, tools: tools))
            Error(error) -> Error(error)
          }
      }
  }
}

pub fn complete(
  state: State,
  reason: StopReason,
) -> Result(State, ProtocolError) {
  case state.terminal {
    Some(_) -> Error(StreamTerminated)
    None ->
      case reason {
        OutputLimited ->
          Ok(State(..state, terminal: Some(Completed(Limited(state.text)))))
        FinalText ->
          case state.tools {
            [] ->
              Ok(State(..state, terminal: Some(Completed(Final(state.text)))))
            _ -> Error(UnexpectedToolCalls)
          }
        ToolsRequested ->
          case completed_calls(state.tools) {
            Error(error) -> Error(error)
            Ok([]) -> Error(NoToolCalls)
            Ok(calls) ->
              Ok(
                State(
                  ..state,
                  terminal: Some(Completed(RequestsTools(state.text, calls))),
                ),
              )
          }
      }
  }
}

pub fn fail(
  state: State,
  error: llm.CallError,
) -> Result(State, ProtocolError) {
  case state.terminal {
    Some(_) -> Error(StreamTerminated)
    None -> {
      let failure = case state.observed {
        True -> AfterProgress(error)
        False -> BeforeProgress(error)
      }
      Ok(State(..state, terminal: Some(Failed(failure))))
    }
  }
}

// Local closure makes no claim that the provider stopped computation.
pub fn close(state: State) -> State {
  case state.terminal {
    Some(_) -> state
    None -> State(..state, terminal: Some(ConsumerClosed))
  }
}

pub fn terminal(state: State) -> Option(Terminal) {
  state.terminal
}

fn buffer_id(buffer: ToolBuffer) -> turn.CallId {
  case buffer {
    Collecting(id, _, _) -> id
    Decoded(call) -> call.id
  }
}

fn has_call(buffers: List(ToolBuffer), id: turn.CallId) -> Bool {
  case buffers {
    [] -> False
    [first, ..rest] ->
      case buffer_id(first) == id {
        True -> True
        False -> has_call(rest, id)
      }
  }
}

fn update_buffer(
  buffers: List(ToolBuffer),
  id: turn.CallId,
  update: fn(turn.ToolName, String) -> Result(ToolBuffer, ProtocolError),
) -> Result(List(ToolBuffer), ProtocolError) {
  case buffers {
    [] -> Error(UnknownCall(id))
    [first, ..rest] ->
      case buffer_id(first) == id {
        True ->
          case first {
            Decoded(_) -> Error(ArgumentsAlreadyEnded(id))
            Collecting(_, name, raw) ->
              case update(name, raw) {
                Ok(updated) -> Ok([updated, ..rest])
                Error(error) -> Error(error)
              }
          }
        False ->
          case update_buffer(rest, id, update) {
            Ok(rest) -> Ok([first, ..rest])
            Error(error) -> Error(error)
          }
      }
  }
}

fn completed_calls(
  buffers: List(ToolBuffer),
) -> Result(List(turn.ToolCall), ProtocolError) {
  case buffers {
    [] -> Ok([])
    [Collecting(id, _, _), ..] -> Error(IncompleteCall(id))
    [Decoded(call), ..rest] ->
      case completed_calls(rest) {
        Ok(rest) -> Ok([call, ..rest])
        Error(error) -> Error(error)
      }
  }
}

fn append(left: List(a), right: List(a)) -> List(a) {
  case left {
    [] -> right
    [first, ..rest] -> [first, ..append(rest, right)]
  }
}
