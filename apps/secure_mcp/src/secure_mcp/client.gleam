//// The two external actors, scripted: a browser that signs in through the
//// app, and an MCP client (Relay's own) that presents a bearer token.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import http_gun
import http_gun/config as gun_config
import http_gun/destination
import http_gun/error as gun_error
import relay/client as mcp
import relay/content

// --- Browser -------------------------------------------------------------------

pub type SignedIn {
  SignedIn(subject: String, access_token: String, mcp_url: String)
}

/// A browser signed in to the app: the provider root it trusts and the
/// app's cookies.
pub type Browser {
  Browser(base_url: String, trust: BitArray, cookies: List(#(String, String)))
}

/// Signs in and POSTs for the access token at `/me/token`.
pub fn sign_in(
  base_url: String,
  trust: BitArray,
  user: String,
) -> Result(SignedIn, String) {
  use browser <- result.try(log_in(base_url, trust, user))
  use me <- result.try(send(browser, http.Post, "/me/token"))
  let decoder = {
    use subject <- decode.field("subject", decode.string)
    use access_token <- decode.field("access_token", decode.string)
    use mcp_url <- decode.field("mcp_url", decode.string)
    decode.success(SignedIn(subject:, access_token:, mcp_url:))
  }
  json.parse(me.body, decoder)
  |> result.map_error(fn(_) { "unexpected /me/token body: " <> me.body })
}

/// Follows `/login` -> the provider's `/authorize` -> `/auth/callback` like
/// a browser: every redirect is followed, and each host gets only the
/// cookies it set. The scripted provider signs in as the `login_hint` the
/// app forwards from `?as=`. `trust` is the provider's root certificate
/// (DER).
pub fn log_in(
  base_url: String,
  trust: BitArray,
  user: String,
) -> Result(Browser, String) {
  use login <- result.try(get(trust, base_url <> "/login?as=" <> user, []))
  let cookies = set_cookies(login)
  use authorize_url <- result.try(location(login))
  use authorize <- result.try(get(trust, authorize_url, []))
  use callback_url <- result.try(location(authorize))
  use callback <- result.try(get(trust, callback_url, cookies))
  use _ <- result.try(location(callback))
  Ok(Browser(
    base_url:,
    trust:,
    cookies: list.append(cookies, set_cookies(callback)),
  ))
}

/// One request to the app with the browser's cookies.
pub fn send(
  browser: Browser,
  method: http.Method,
  path: String,
) -> Result(Response(String), String) {
  request(browser.trust, method, browser.base_url <> path, browser.cookies)
}

fn get(
  trust: BitArray,
  url: String,
  cookies: List(#(String, String)),
) -> Result(Response(String), String) {
  request(trust, http.Get, url, cookies)
}

/// The browser verifies TLS. It trusts only the scripted provider's
/// throwaway root (`hellhound/testing` publishes it as DER), and may reach
/// loopback, like a developer's browser would.
fn request(
  trust: BitArray,
  method: http.Method,
  url: String,
  cookies: List(#(String, String)),
) -> Result(Response(String), String) {
  use req <- result.try(
    request.to(url) |> result.replace_error("bad url " <> url),
  )
  let req =
    req
    |> request.set_method(method)
    |> request.set_body(<<>>)
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
  let failed = fn(reason) {
    http.method_to_string(method) |> string.uppercase
    <> " "
    <> url
    <> ": "
    <> reason
  }
  use browser <- result.try(
    gun_config.default()
    |> gun_config.with_trust(gun_config.Anchors([trust]))
    |> gun_config.with_request_timeout(gun_config.After(duration.seconds(10)))
    |> gun_config.with_destination(destination.loopback_only())
    |> http_gun.start
    |> result.map_error(fn(e) { failed(http_gun.describe_start_error(e)) }),
  )
  let sent = http_gun.send(browser, req)
  http_gun.stop(browser)
  use buffered <- result.try(
    sent |> result.map_error(fn(e) { failed(gun_error.describe(e)) }),
  )
  Ok(
    response.map(buffered.response, fn(body) {
      bit_array.to_string(body) |> result.unwrap("")
    }),
  )
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
