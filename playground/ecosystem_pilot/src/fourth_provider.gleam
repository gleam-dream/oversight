// The application owns this provider and imports only public LLM Wire modules.
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import llm_wire/error as wire_error
import llm_wire/message
import llm_wire/provider

type State {
  State(
    text: String,
    calls: List(message.ToolCall),
    done: Bool,
    limited: Bool,
    refusal: Option(String),
    failure: Option(wire_error.Error),
  )
}

pub fn adapter(endpoint: String) -> provider.Adapter {
  provider.new(
    message.Custom("scripted-fourth"),
    endpoint,
    encode_request,
    fn() {
      provider.reducer(State("", [], False, False, None, None), step, terminal)
    },
  )
  |> provider.with_headers(fn() { [#("X-Fixture", "fourth")] })
}

fn encode_request(
  request: provider.Request,
  tools: List(provider.ProjectedTool),
  format: Option(provider.OutputFormat),
) -> Result(provider.Encoded, wire_error.PrepareError) {
  let messages = list.map(request.messages, encode_message)
  let projected =
    list.map(tools, fn(tool) {
      json.object([
        #("name", json.string(tool.name)),
        #("description", json.string(tool.description)),
        #("input_schema", tool.schema),
      ])
    })
  let format_fields = case format {
    None -> []
    Some(format) -> [
      #("output_name", json.string(format.name)),
      #("output_schema", format.schema),
    ]
  }
  let replay_fields =
    list.flat_map(request.messages, fn(message) {
      case message {
        message.Assistant(turn) if turn.calls != [] -> [
          #("replay_text", json.string(turn.text)),
          #(
            "replay_call_ids",
            json.array(turn.calls, fn(call) { json.string(call.id) }),
          ),
        ]
        _ -> []
      }
    })
  Ok(provider.encoded(
    "/events",
    json.to_string(
      json.object(list.append(
        [
          #("model", json.string(request.model)),
          #("messages", json.array(messages, fn(value) { value })),
          #("tools", json.array(projected, fn(value) { value })),
        ],
        list.append(format_fields, replay_fields),
      )),
    ),
  ))
}

fn encode_message(message: message.Message) -> json.Json {
  case message {
    message.System(text) -> message_json("system", text)
    message.User(text) -> message_json("user", text)
    message.UserParts(_) -> message_json("user", "[content]")
    message.Assistant(turn) -> assistant_calls(turn.text, turn.calls)
    message.AssistantParts(_) -> message_json("assistant", "[content]")
    message.ToolResult(id, content) ->
      json.object([
        #("role", json.string("tool")),
        #("call_id", json.string(id)),
        #("content", json.string(content)),
      ])
  }
}

fn message_json(role: String, text: String) -> json.Json {
  json.object([#("role", json.string(role)), #("text", json.string(text))])
}

fn assistant_calls(text: String, calls: List(message.ToolCall)) -> json.Json {
  json.object([
    #("role", json.string("assistant")),
    #("text", json.string(text)),
    #(
      "calls",
      json.array(calls, fn(call) {
        json.object([
          #("id", json.string(call.id)),
          #("name", json.string(call.name)),
          #("arguments", json.string(call.arguments_json)),
        ])
      }),
    ),
  ])
}

fn step(
  state: State,
  event: provider.Event,
) -> Result(#(State, List(message.Progress)), wire_error.Error) {
  case event.event {
    Some("text") -> {
      let next = State(..state, text: state.text <> event.data)
      Ok(#(next, [message.TextDelta("0", event.data)]))
    }
    Some("tool") -> {
      use call <- result.try(parse_call(event.data))
      Ok(#(State(..state, calls: list.append(state.calls, [call])), []))
    }
    Some("done") -> Ok(#(State(..state, done: True), []))
    Some("limited") -> Ok(#(State(..state, done: True, limited: True), []))
    Some("refusal") ->
      Ok(#(State(..state, done: True, refusal: Some(event.data)), []))
    Some("failure") ->
      Ok(
        #(
          State(
            ..state,
            done: True,
            failure: Some(wire_error.Provider(Some("fixture"), event.data)),
          ),
          [],
        ),
      )
    Some("extension") ->
      Ok(#(state, [message.ProviderExtension("scripted-fourth", event.data)]))
    _ -> Ok(#(state, []))
  }
}

fn parse_call(raw: String) -> Result(message.ToolCall, wire_error.Error) {
  case string.split(raw, "|") {
    [raw_id, raw_name, arguments_json] ->
      Ok(message.tool_call(raw_id, raw_name, arguments_json))
    _ -> Error(wire_error.Protocol("Malformed fixture tool event"))
  }
}

fn terminal(state: State) -> Option(provider.Terminal) {
  case state.done, state.failure, state.refusal, state.limited, state.calls {
    False, _, _, _, _ -> None
    True, Some(error), _, _, _ -> Some(provider.failed(error, None))
    True, None, Some(reason), _, _ -> Some(provider.refused(reason, None))
    True, None, None, True, _ ->
      Some(provider.output_limited(state.text, state.calls, None))
    True, None, None, False, [] -> Some(provider.text(state.text, None))
    True, None, None, False, calls ->
      Some(provider.tool_calls(
        state.text,
        calls,
        Some("response-fourth"),
        None,
        None,
      ))
  }
}
