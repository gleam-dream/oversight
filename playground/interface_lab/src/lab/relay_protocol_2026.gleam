// THROWAWAY: Can one parsed MCP 2026 request boundary route exact modern values?
import lab/blueprint
import lab/relay
import lab/relay_exchange as exchange
import lab/value.{type Value}

pub type RequestId =
  exchange.RequestId

pub type ProgressToken =
  exchange.ProgressToken

type Maybe(a) {
  Missing
  Present(a)
}

pub type RequestMetadata {
  RequestMetadata(
    protocol_version: String,
    client_capabilities: Value,
    progress_token: exchange.Optional(ProgressToken),
    extensions: List(#(String, Value)),
    raw: Value,
  )
}

pub type Request {
  Discover(request_id: RequestId, metadata: RequestMetadata)
  ToolsList(
    request_id: RequestId,
    metadata: RequestMetadata,
    cursor: exchange.Optional(String),
  )
  ToolsCall(
    request_id: RequestId,
    metadata: RequestMetadata,
    name: String,
    arguments: Value,
  )
}

pub type ProtocolError {
  InvalidRequest
  InvalidParams
  MethodNotFound
  UnsupportedProtocolVersion(requested: String)
  InternalError
}

pub type Admission {
  Admitted(Request)
  Rejected(request_id: exchange.Optional(RequestId), error: ProtocolError)
  UnsupportedNotification
  UnexpectedResponseMessage
}

pub type UnhandledReason {
  UnsupportedNotificationReason
  UnexpectedResponseReason
}

pub fn supported_versions() -> List(String) {
  ["2026-07-28"]
}

pub fn admit(raw: Value) -> Admission {
  case raw {
    value.Object(members) ->
      case duplicate_name(members) {
        Present(_) -> Rejected(exchange.Absent, InvalidRequest)
        Missing -> admit_object(members)
      }
    _ -> Rejected(exchange.Absent, InvalidRequest)
  }
}

fn admit_object(members: List(#(String, Value))) -> Admission {
  case member(members, "result"), member(members, "error") {
    Present(_), _ -> classify_response(members)
    _, Present(_) -> classify_response(members)
    _, _ -> admit_request_or_notification(members)
  }
}

fn classify_response(members: List(#(String, Value))) -> Admission {
  case valid_response_envelope(members) {
    True -> UnexpectedResponseMessage
    False -> Rejected(exchange.Absent, InvalidRequest)
  }
}

fn valid_response_envelope(members: List(#(String, Value))) -> Bool {
  case
    member(members, "jsonrpc"),
    member(members, "method"),
    member(members, "id"),
    member(members, "result"),
    member(members, "error")
  {
    Present(value.Text("2.0")), Missing, Present(id), Present(result), Missing
    -> valid_response_id(Present(id)) && valid_modern_result(result)
    Present(value.Text("2.0")), Missing, id, Missing, Present(error) ->
      valid_response_id(id) && valid_error_object(error)
    _, _, _, _, _ -> False
  }
}

fn valid_modern_result(result: Value) -> Bool {
  case result {
    value.Object(members) ->
      duplicate_name(members) == Missing
      && case member(members, "resultType") {
        Present(value.Text(_)) -> True
        _ -> False
      }
    _ -> False
  }
}

fn valid_response_id(id: Maybe(Value)) -> Bool {
  case id {
    Missing -> True
    Present(raw) ->
      case request_id(raw) {
        Present(_) -> True
        Missing -> False
      }
  }
}

fn valid_error_object(error: Value) -> Bool {
  case error {
    value.Object(members) ->
      duplicate_name(members) == Missing
      && case member(members, "code"), member(members, "message") {
        Present(value.Int(_)), Present(value.Text(_)) -> True
        _, _ -> False
      }
    _ -> False
  }
}

fn admit_request_or_notification(members: List(#(String, Value))) -> Admission {
  case member(members, "jsonrpc"), member(members, "method") {
    Present(value.Text("2.0")), Present(value.Text(method)) ->
      case member(members, "id") {
        Missing -> admit_notification(members, method)
        Present(raw_id) ->
          case request_id(raw_id) {
            Missing -> Rejected(exchange.Absent, InvalidRequest)
            Present(request_id) -> admit_request(members, request_id, method)
          }
      }
    _, _ -> Rejected(exchange.Absent, InvalidRequest)
  }
}

fn admit_notification(
  members: List(#(String, Value)),
  _method: String,
) -> Admission {
  case member(members, "params") {
    Missing -> UnsupportedNotification
    Present(value.Object(params)) ->
      case duplicate_name(params) {
        Present(_) -> Rejected(exchange.Absent, InvalidRequest)
        Missing -> UnsupportedNotification
      }
    Present(_) -> Rejected(exchange.Absent, InvalidRequest)
  }
}

fn admit_request(
  members: List(#(String, Value)),
  request_id: RequestId,
  method: String,
) -> Admission {
  case method {
    "server/discover" -> admit_discover(members, request_id)
    "tools/list" -> admit_tools_list(members, request_id)
    "tools/call" -> admit_tools_call(members, request_id)
    _ -> Rejected(exchange.Present(request_id), MethodNotFound)
  }
}

fn admit_discover(
  members: List(#(String, Value)),
  request_id: RequestId,
) -> Admission {
  case parse_metadata(members) {
    Error(error) -> Rejected(exchange.Present(request_id), error)
    Ok(metadata) -> Admitted(Discover(request_id, metadata))
  }
}

fn admit_tools_list(
  members: List(#(String, Value)),
  request_id: RequestId,
) -> Admission {
  case params_object(members) {
    Missing -> Rejected(exchange.Present(request_id), InvalidParams)
    Present(params) ->
      case parse_metadata_members(params) {
        Error(error) -> Rejected(exchange.Present(request_id), error)
        Ok(metadata) ->
          case member(params, "cursor") {
            Missing ->
              Admitted(ToolsList(request_id, metadata, exchange.Absent))
            Present(value.Text(cursor)) ->
              Admitted(ToolsList(request_id, metadata, exchange.Present(cursor)))
            Present(_) -> Rejected(exchange.Present(request_id), InvalidParams)
          }
      }
  }
}

fn admit_tools_call(
  members: List(#(String, Value)),
  request_id: RequestId,
) -> Admission {
  case params_object(members) {
    Missing -> Rejected(exchange.Present(request_id), InvalidParams)
    Present(params) ->
      case duplicate_name(params) {
        Present(_) -> Rejected(exchange.Present(request_id), InvalidParams)
        Missing ->
          case
            member(params, "requestState"),
            member(params, "inputResponses")
          {
            Present(_), _ ->
              Rejected(exchange.Present(request_id), InvalidParams)
            _, Present(_) ->
              Rejected(exchange.Present(request_id), InvalidParams)
            _, _ ->
              case parse_metadata_members(params) {
                Error(error) -> Rejected(exchange.Present(request_id), error)
                Ok(metadata) ->
                  case member(params, "name"), member(params, "arguments") {
                    Present(value.Text(name)), Missing ->
                      Admitted(ToolsCall(
                        request_id,
                        metadata,
                        name,
                        value.Object([]),
                      ))
                    Present(value.Text(name)), Present(value.Object(arguments))
                    ->
                      Admitted(ToolsCall(
                        request_id,
                        metadata,
                        name,
                        value.Object(arguments),
                      ))
                    _, _ ->
                      Rejected(exchange.Present(request_id), InvalidParams)
                  }
              }
          }
      }
  }
}

fn parse_metadata(
  members: List(#(String, Value)),
) -> Result(RequestMetadata, ProtocolError) {
  case params_object(members) {
    Missing -> Error(InvalidParams)
    Present(params) -> parse_metadata_members(params)
  }
}

fn parse_metadata_members(
  params: List(#(String, Value)),
) -> Result(RequestMetadata, ProtocolError) {
  case duplicate_name(params) {
    Present(_) -> Error(InvalidParams)
    Missing ->
      case member(params, "_meta") {
        Missing -> Error(InvalidParams)
        Present(value.Object(meta)) -> parse_meta(meta)
        Present(_) -> Error(InvalidParams)
      }
  }
}

fn parse_meta(
  members: List(#(String, Value)),
) -> Result(RequestMetadata, ProtocolError) {
  case duplicate_name(members) {
    Present(_) -> Error(InvalidParams)
    Missing ->
      case
        member(members, "io.modelcontextprotocol/protocolVersion"),
        member(members, "io.modelcontextprotocol/clientCapabilities")
      {
        Present(value.Text(protocol_version)),
          Present(value.Object(capability_members) as capabilities)
        ->
          case
            duplicate_name(capability_members),
            valid_client_capabilities(capability_members),
            valid_client_metadata(members)
          {
            Present(_), _, _ -> Error(InvalidParams)
            _, False, _ -> Error(InvalidParams)
            _, _, False -> Error(InvalidParams)
            Missing, True, True ->
              case protocol_version == "2026-07-28" {
                False -> Error(UnsupportedProtocolVersion(protocol_version))
                True ->
                  case parse_progress_token(member(members, "progressToken")) {
                    Error(Nil) -> Error(InvalidParams)
                    Ok(progress_token) ->
                      Ok(RequestMetadata(
                        protocol_version,
                        capabilities,
                        progress_token,
                        extension_members(members),
                        value.Object(members),
                      ))
                  }
              }
          }
        _, _ -> Error(InvalidParams)
      }
  }
}

fn valid_client_capabilities(members: List(#(String, Value))) -> Bool {
  case members {
    [] -> True
    [#("roots", value.Object(root_fields)), ..rest] ->
      duplicate_name(root_fields) == Missing && valid_client_capabilities(rest)
    [#("roots", _), ..] -> False
    [#("sampling", value.Object(nested)), ..rest] ->
      valid_capability_object(nested, ["context", "tools"])
      && valid_client_capabilities(rest)
    [#("sampling", _), ..] -> False
    [#("elicitation", value.Object(nested)), ..rest] ->
      valid_capability_object(nested, ["form", "url"])
      && valid_client_capabilities(rest)
    [#("elicitation", _), ..] -> False
    [#("experimental", value.Object(nested)), ..rest] ->
      all_object_values(nested) && valid_client_capabilities(rest)
    [#("experimental", _), ..] -> False
    [#("extensions", value.Object(nested)), ..rest] ->
      all_object_values(nested) && valid_client_capabilities(rest)
    [#("extensions", _), ..] -> False
    [_, ..rest] -> valid_client_capabilities(rest)
  }
}

fn valid_capability_object(
  members: List(#(String, Value)),
  object_fields: List(String),
) -> Bool {
  case duplicate_name(members) {
    Present(_) -> False
    Missing -> all_named_values_are_objects(members, object_fields)
  }
}

fn all_named_values_are_objects(
  members: List(#(String, Value)),
  names: List(String),
) -> Bool {
  case names {
    [] -> True
    [name, ..rest] ->
      case member(members, name) {
        Missing -> all_named_values_are_objects(members, rest)
        Present(value.Object(_)) -> all_named_values_are_objects(members, rest)
        Present(_) -> False
      }
  }
}

fn all_object_values(members: List(#(String, Value))) -> Bool {
  case members {
    [] -> True
    [#(_, value.Object(fields)), ..rest] ->
      duplicate_name(fields) == Missing && all_object_values(rest)
    [_, ..] -> False
  }
}

fn valid_client_metadata(members: List(#(String, Value))) -> Bool {
  valid_client_info(member(members, "io.modelcontextprotocol/clientInfo"))
  && valid_log_level(member(members, "io.modelcontextprotocol/logLevel"))
}

fn valid_client_info(info: Maybe(Value)) -> Bool {
  case info {
    Missing -> True
    Present(value.Object(members)) ->
      case duplicate_name(members) {
        Present(_) -> False
        Missing ->
          case member(members, "name"), member(members, "version") {
            Present(value.Text(_)), Present(value.Text(_)) ->
              valid_optional_client_info_fields(members)
            _, _ -> False
          }
      }
    Present(_) -> False
  }
}

fn valid_optional_client_info_fields(members: List(#(String, Value))) -> Bool {
  valid_text_field(members, "title")
  && valid_text_field(members, "description")
  && valid_text_field(members, "websiteUrl")
  && valid_icons_field(members)
}

fn valid_text_field(members: List(#(String, Value)), name: String) -> Bool {
  case member(members, name) {
    Missing -> True
    Present(value.Text(_)) -> True
    Present(_) -> False
  }
}

fn valid_icons_field(members: List(#(String, Value))) -> Bool {
  case member(members, "icons") {
    Missing -> True
    Present(value.Array(icons)) -> all_icons_valid(icons)
    Present(_) -> False
  }
}

fn all_icons_valid(icons: List(Value)) -> Bool {
  case icons {
    [] -> True
    [value.Object(members), ..rest] ->
      duplicate_name(members) == Missing
      && case member(members, "src") {
        Present(value.Text(_)) ->
          valid_text_field(members, "mimeType")
          && valid_icon_sizes(member(members, "sizes"))
          && valid_icon_theme(member(members, "theme"))
          && all_icons_valid(rest)
        _ -> False
      }
    [_, ..] -> False
  }
}

fn valid_icon_sizes(sizes: Maybe(Value)) -> Bool {
  case sizes {
    Missing -> True
    Present(value.Array(values)) -> all_text(values)
    Present(_) -> False
  }
}

fn valid_icon_theme(theme: Maybe(Value)) -> Bool {
  case theme {
    Missing -> True
    Present(value.Text("dark")) -> True
    Present(value.Text("light")) -> True
    Present(_) -> False
  }
}

fn all_text(values: List(Value)) -> Bool {
  case values {
    [] -> True
    [value.Text(_), ..rest] -> all_text(rest)
    [_, ..] -> False
  }
}

fn valid_log_level(level: Maybe(Value)) -> Bool {
  case level {
    Missing -> True
    Present(value.Text("alert")) -> True
    Present(value.Text("critical")) -> True
    Present(value.Text("debug")) -> True
    Present(value.Text("emergency")) -> True
    Present(value.Text("error")) -> True
    Present(value.Text("info")) -> True
    Present(value.Text("notice")) -> True
    Present(value.Text("warning")) -> True
    Present(_) -> False
  }
}

fn parse_progress_token(
  token: Maybe(Value),
) -> Result(exchange.Optional(ProgressToken), Nil) {
  case token {
    Missing -> Ok(exchange.Absent)
    Present(value.Text(token)) ->
      Ok(exchange.Present(exchange.ProgressString(token)))
    Present(value.Int(token)) ->
      Ok(exchange.Present(exchange.ProgressInteger(token)))
    Present(_) -> Error(Nil)
  }
}

fn extension_members(
  members: List(#(String, Value)),
) -> List(#(String, Value)) {
  case members {
    [] -> []
    [#(key, _), ..rest]
      if key == "io.modelcontextprotocol/protocolVersion"
      || key == "io.modelcontextprotocol/clientCapabilities"
      || key == "progressToken"
    -> extension_members(rest)
    [member, ..rest] -> [member, ..extension_members(rest)]
  }
}

fn params_object(
  members: List(#(String, Value)),
) -> Maybe(List(#(String, Value))) {
  case member(members, "params") {
    Present(value.Object(params)) -> Present(params)
    _ -> Missing
  }
}

fn request_id(raw: Value) -> Maybe(RequestId) {
  case raw {
    value.Text(id) -> Present(exchange.RequestString(id))
    value.Int(id) -> Present(exchange.RequestInteger(id))
    _ -> Missing
  }
}

fn member(members: List(#(String, Value)), name: String) -> Maybe(Value) {
  case members {
    [] -> Missing
    [#(key, value), ..rest] ->
      case key == name {
        True -> Present(value)
        False -> member(rest, name)
      }
  }
}

fn duplicate_name(members: List(#(String, Value))) -> Maybe(String) {
  case members {
    [] -> Missing
    [#(key, _), ..rest] ->
      case member(rest, key) {
        Present(_) -> Present(key)
        Missing -> duplicate_name(rest)
      }
  }
}

pub fn request_metadata(request: Request) -> RequestMetadata {
  case request {
    Discover(_, metadata) -> metadata
    ToolsList(_, metadata, _) -> metadata
    ToolsCall(_, metadata, _, _) -> metadata
  }
}

pub fn metadata_extension(
  metadata: RequestMetadata,
  name: String,
) -> exchange.Optional(Value) {
  case member(metadata.extensions, name) {
    Missing -> exchange.Absent
    Present(value) -> exchange.Present(value)
  }
}

fn jsonrpc_result(request_id: RequestId, result: Value) -> Value {
  value.Object([
    #("jsonrpc", value.Text("2.0")),
    #("id", request_id_value(request_id)),
    #("result", result),
  ])
}

pub fn error_response(
  request_id: exchange.Optional(RequestId),
  error: ProtocolError,
) -> Value {
  let error_fields = case error {
    InvalidRequest -> rpc_error(-32_600, "Invalid request.", exchange.Absent)
    InvalidParams -> rpc_error(-32_602, "Invalid params.", exchange.Absent)
    MethodNotFound -> rpc_error(-32_601, "Method not found.", exchange.Absent)
    InternalError -> rpc_error(-32_603, "Internal error.", exchange.Absent)
    UnsupportedProtocolVersion(requested) ->
      rpc_error(
        -32_022,
        "Unsupported protocol version.",
        exchange.Present(
          value.Object([
            #("supported", string_array(supported_versions())),
            #("requested", value.Text(requested)),
          ]),
        ),
      )
  }
  let id_field = case request_id {
    exchange.Absent -> []
    exchange.Present(id) -> [#("id", request_id_value(id))]
  }
  value.Object(append_items(
    [#("jsonrpc", value.Text("2.0"))],
    append_items(id_field, [#("error", error_fields)]),
  ))
}

fn rpc_error(
  code: Int,
  message: String,
  data: exchange.Optional(Value),
) -> Value {
  let data_field = case data {
    exchange.Absent -> []
    exchange.Present(value) -> [#("data", value)]
  }
  value.Object([
    #("code", value.Int(code)),
    #("message", value.Text(message)),
    ..data_field
  ])
}

pub fn internal_error_response(request_id: RequestId) -> Value {
  error_response(exchange.Present(request_id), InternalError)
}

pub fn progress_notification(token: ProgressToken, progress: Int) -> Value {
  value.Object([
    #("jsonrpc", value.Text("2.0")),
    #("method", value.Text("notifications/progress")),
    #(
      "params",
      value.Object([
        #("progressToken", progress_token_value(token)),
        #("progress", value.Int(progress)),
      ]),
    ),
  ])
}

pub fn discovery_result(request_id: RequestId) -> Value {
  jsonrpc_result(
    request_id,
    value.Object([
      #("cacheScope", value.Text("private")),
      #("capabilities", value.Object([#("tools", value.Object([]))])),
      #("resultType", value.Text("complete")),
      #("supportedVersions", string_array(supported_versions())),
      #("ttlMs", value.Int(0)),
    ]),
  )
}

pub fn tools_result(
  request_id: RequestId,
  declarations: List(relay.Declaration),
) -> Value {
  jsonrpc_result(
    request_id,
    value.Object([
      #("cacheScope", value.Text("private")),
      #("resultType", value.Text("complete")),
      #("tools", tool_values(declarations)),
      #("ttlMs", value.Int(0)),
    ]),
  )
}

fn tool_values(declarations: List(relay.Declaration)) -> Value {
  case declarations {
    [] -> value.Array([])
    [relay.Declaration(name, schema), ..rest] -> {
      let assert value.Array(tail) = tool_values(rest)
      value.Array([
        value.Object([
          #("name", value.Text(name)),
          #("inputSchema", blueprint.schema_value(schema)),
        ]),
        ..tail
      ])
    }
  }
}

pub fn call_response(
  request_id: RequestId,
  outcome: Result(Value, relay.DispatchError),
) -> Value {
  case outcome {
    Ok(output) -> tool_result(request_id, output, exchange.Absent)
    Error(relay.UnknownTool(_)) ->
      error_response(exchange.Present(request_id), InvalidParams)
    Error(relay.InvocationFailed(relay.InvalidInput(_))) ->
      tool_result(
        request_id,
        value.Null,
        exchange.Present("Tool arguments were invalid."),
      )
    Error(relay.InvocationFailed(relay.ApplicationFailure(error))) ->
      tool_result(
        request_id,
        error,
        exchange.Present("The tool reported an error."),
      )
    Error(relay.InvocationFailed(relay.InvalidOutput(_))) ->
      internal_error_response(request_id)
    Error(relay.InvocationFailed(relay.InvalidError(_))) ->
      internal_error_response(request_id)
  }
}

fn tool_result(
  request_id: RequestId,
  structured: Value,
  error_message: exchange.Optional(String),
) -> Value {
  let base = [
    #("content", error_content(error_message)),
    #("resultType", value.Text("complete")),
  ]
  let is_error = case error_message {
    exchange.Absent -> []
    exchange.Present(_) -> [#("isError", value.Bool(True))]
  }
  let content = [#("structuredContent", structured)]
  jsonrpc_result(
    request_id,
    value.Object(append_items(append_items(base, is_error), content)),
  )
}

fn error_content(message: exchange.Optional(String)) -> Value {
  case message {
    exchange.Absent -> value.Array([])
    exchange.Present(text) ->
      value.Array([
        value.Object([
          #("type", value.Text("text")),
          #("text", value.Text(text)),
        ]),
      ])
  }
}

fn request_id_value(request_id: RequestId) -> Value {
  case request_id {
    exchange.RequestString(id) -> value.Text(id)
    exchange.RequestInteger(id) -> value.Int(id)
  }
}

fn progress_token_value(token: ProgressToken) -> Value {
  case token {
    exchange.ProgressString(id) -> value.Text(id)
    exchange.ProgressInteger(id) -> value.Int(id)
  }
}

fn string_array(strings: List(String)) -> Value {
  case strings {
    [] -> value.Array([])
    [string, ..rest] -> {
      let assert value.Array(tail) = string_array(rest)
      value.Array([value.Text(string), ..tail])
    }
  }
}

fn append_items(first: List(a), second: List(a)) -> List(a) {
  case first {
    [] -> second
    [item, ..rest] -> [item, ..append_items(rest, second)]
  }
}
