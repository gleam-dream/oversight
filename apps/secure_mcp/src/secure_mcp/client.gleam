//// The two external actors, scripted: a browser that signs in through the
//// app and the provider, and an MCP client that presents a bearer token.
////
//// The MCP client speaks raw JSON-RPC: Relay's own client
//// (`relay/client.http_config`) has no header or token-provider hook, so it
//// cannot send `Authorization` to a protected server (FEEDBACK SMCP-6).

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

// --- Browser -------------------------------------------------------------------

pub type SignedIn {
  SignedIn(subject: String, access_token: String, mcp_url: String)
}

/// Follows `/login` -> provider `/authorize` -> `/auth/callback` ->
/// `/me/token`, carrying the app's cookies like a browser would.
pub fn sign_in(base_url: String, user: String) -> Result(SignedIn, String) {
  use login <- result.try(get(base_url <> "/login?as=" <> user, []))
  use authorize_url <- result.try(location(login))
  let cookies = set_cookies(login)
  use authorized <- result.try(get(authorize_url, []))
  use callback_url <- result.try(location(authorized))
  use callback <- result.try(get(callback_url, cookies))
  use _ <- result.try(location(callback))
  let cookies = list.append(cookies, set_cookies(callback))
  use me <- result.try(get(base_url <> "/me/token", cookies))
  let decoder = {
    use subject <- decode.field("subject", decode.string)
    use access_token <- decode.field("access_token", decode.string)
    use mcp_url <- decode.field("mcp_url", decode.string)
    decode.success(SignedIn(subject:, access_token:, mcp_url:))
  }
  json.parse(me.body, decoder)
  |> result.map_error(fn(_) { "unexpected /me/token body: " <> me.body })
}

fn get(
  url: String,
  cookies: List(#(String, String)),
) -> Result(Response(String), String) {
  use req <- result.try(
    request.to(url) |> result.replace_error("bad url " <> url),
  )
  let req = case cookies {
    [] -> req
    _ ->
      request.set_header(
        req,
        "cookie",
        cookies
          |> list.map(fn(c) { c.0 <> "=" <> c.1 })
          |> string.join("; "),
      )
  }
  // The scripted provider's certificate comes from a throwaway CA.
  httpc.configure()
  |> httpc.verify_tls(False)
  |> httpc.dispatch(req)
  |> result.map_error(fn(e) { "GET " <> url <> ": " <> string.inspect(e) })
}

fn location(resp: Response(String)) -> Result(String, String) {
  case resp.status >= 300 && resp.status < 400 {
    True ->
      response.get_header(resp, "location")
      |> result.replace_error("redirect without location")
    False ->
      Error(
        "expected a redirect, got "
        <> int.to_string(resp.status)
        <> ": "
        <> resp.body,
      )
  }
}

fn set_cookies(resp: Response(String)) -> List(#(String, String)) {
  resp.headers
  |> list.filter(fn(h) { h.0 == "set-cookie" })
  |> list.filter_map(fn(h) {
    case string.split_once(h.1, ";") {
      Ok(#(pair, _)) -> string.split_once(pair, "=")
      Error(Nil) -> string.split_once(h.1, "=")
    }
  })
}

// --- MCP client ----------------------------------------------------------------

pub type Reply {
  /// `tools/call` succeeded with structured content.
  Structured(Dynamic)
  /// The tool reported `isError: true`; its text content.
  ToolError(String)
  /// Any other JSON-RPC result (discover, tools/list) as JSON text.
  Other(String)
  /// The HTTP layer refused the request.
  Refused(status: Int, challenge: Option(String))
}

pub fn discover(
  mcp_url: String,
  token: Option(String),
) -> Result(Reply, String) {
  rpc(mcp_url, token, "server/discover", None, [], [])
}

pub fn list_tools(mcp_url: String, token: String) -> Result(Reply, String) {
  rpc(mcp_url, Some(token), "tools/list", None, [], [])
}

pub fn call_tool(
  mcp_url: String,
  token: Option(String),
  name: String,
  arguments: json.Json,
) -> Result(Reply, String) {
  call_tool_with_headers(mcp_url, token, name, arguments, [])
}

/// `call_tool` with extra request headers, such as `x-request-id`.
pub fn call_tool_with_headers(
  mcp_url: String,
  token: Option(String),
  name: String,
  arguments: json.Json,
  headers: List(#(String, String)),
) -> Result(Reply, String) {
  rpc(
    mcp_url,
    token,
    "tools/call",
    Some(name),
    [#("name", json.string(name)), #("arguments", arguments)],
    headers,
  )
}

fn rpc(
  mcp_url: String,
  token: Option(String),
  method: String,
  name: Option(String),
  params: List(#(String, json.Json)),
  headers: List(#(String, String)),
) -> Result(Reply, String) {
  let meta =
    json.object([
      #("io.modelcontextprotocol/protocolVersion", json.string("2026-07-28")),
      #("io.modelcontextprotocol/clientCapabilities", json.object([])),
    ])
  let body =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.int(1)),
      #("method", json.string(method)),
      #("params", json.object([#("_meta", meta), ..params])),
    ])
    |> json.to_string
  use req <- result.try(
    request.to(mcp_url) |> result.replace_error("bad url " <> mcp_url),
  )
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("accept", "application/json, text/event-stream")
    |> request.set_header("mcp-protocol-version", "2026-07-28")
    |> request.set_header("mcp-method", method)
    |> request.set_body(body)
  let req =
    list.fold(headers, req, fn(req, h) { request.set_header(req, h.0, h.1) })
  let req = case name {
    Some(n) -> request.set_header(req, "mcp-name", n)
    None -> req
  }
  let req = case token {
    Some(t) -> request.set_header(req, "authorization", "Bearer " <> t)
    None -> req
  }
  use resp <- result.try(
    httpc.send(req) |> result.map_error(fn(e) { string.inspect(e) }),
  )
  case resp.status {
    200 -> interpret(resp.body)
    status ->
      Ok(Refused(
        status,
        response.get_header(resp, "www-authenticate") |> option.from_result,
      ))
  }
}

fn interpret(body: String) -> Result(Reply, String) {
  let structured = {
    use is_error <- decode.optional_field("isError", False, decode.bool)
    use content <- decode.optional_field(
      "content",
      [],
      decode.list({
        use text <- decode.optional_field("text", "", decode.string)
        decode.success(text)
      }),
    )
    use structured <- decode.optional_field(
      "structuredContent",
      None,
      decode.optional(decode.dynamic),
    )
    decode.success(#(is_error, content, structured))
  }
  let decoder = {
    use result <- decode.field("result", decode.dynamic)
    decode.success(result)
  }
  case json.parse(body, decoder) {
    Error(_) -> Error("not a JSON-RPC result: " <> body)
    Ok(result) ->
      case decode.run(result, structured) {
        Ok(#(True, texts, _)) -> Ok(ToolError(string.join(texts, " ")))
        Ok(#(False, _, Some(value))) -> Ok(Structured(value))
        _ -> Ok(Other(body))
      }
  }
}
