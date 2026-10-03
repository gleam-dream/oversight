//// The two external actors, scripted: a browser that signs in through the
//// app, and an MCP client (Relay's own) that presents a bearer token.

import gleam/bit_array
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
import gleam/time/duration
import relay/client as mcp
import relay/content

// --- Browser -------------------------------------------------------------------

pub type SignedIn {
  SignedIn(subject: String, access_token: String, mcp_url: String)
}

/// Follows `/login` -> `/auth/callback` -> `/me/token`, carrying the app's cookies like a browser would.
pub fn sign_in(base_url: String, user: String) -> Result(SignedIn, String) {
  use login <- result.try(get(base_url <> "/login?as=" <> user, []))
  // The scripted provider approved at once: the redirect is the callback.
  use callback_url <- result.try(location(login))
  let cookies = set_cookies(login)
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
  send(req)
  |> result.map_error(fn(e) { "GET " <> url <> ": " <> e })
}

fn send(req: request.Request(String)) -> Result(Response(String), String) {
  // The scripted provider's certificate comes from its own throwaway root.
  httpc.configure()
  |> httpc.verify_tls(False)
  |> httpc.dispatch(req)
  |> result.map_error(string.inspect)
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

/// Relay's HTTP client, sending `Authorization: Bearer` when given a token
/// and any extra headers (such as `x-request-id`) on every request.
pub fn connect(
  mcp_url: String,
  token: Option(String),
  headers: List(#(String, String)),
) -> Result(mcp.Client, mcp.Error) {
  use config <- result.try(mcp.http(mcp_url))
  let bearer = case token {
    Some(token) -> [#("authorization", "Bearer " <> token)]
    None -> []
  }
  config
  |> mcp.with_timeout(duration.seconds(5))
  |> mcp.with_headers(fn() { list.append(bearer, headers) })
  |> mcp.connect
}

/// The text of a tool's content blocks.
pub fn text(blocks: List(content.ContentBlock)) -> String {
  list.filter_map(blocks, fn(block) {
    case block {
      content.TextContent(text, _, _) -> Ok(text)
      _ -> Error(Nil)
    }
  })
  |> string.join(" ")
}

// --- Provider ------------------------------------------------------------------

// GLUE (warden/testing): the provider can revoke refresh tokens by subject
// (`revoke_refresh_tokens`) but has no call for one access token, so this
// posts to its `/revoke` endpoint with the client's credentials.

/// Revokes an access token at the scripted provider (RFC 7009), as its
/// administrator would.
pub fn revoke_access_token(
  issuer: String,
  client_id: String,
  client_secret: String,
  token: String,
) -> Result(Nil, String) {
  use req <- result.try(
    request.to(issuer <> "/revoke") |> result.replace_error("bad issuer"),
  )
  let credentials =
    bit_array.base64_encode(<<client_id:utf8, ":", client_secret:utf8>>, True)
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("authorization", "Basic " <> credentials)
    |> request.set_header("content-type", "application/x-www-form-urlencoded")
    |> request.set_body("token=" <> token)
  case send(req) {
    Ok(resp) if resp.status == 200 -> Ok(Nil)
    Ok(resp) -> Error("revoke answered " <> int.to_string(resp.status))
    Error(reason) -> Error(reason)
  }
}
