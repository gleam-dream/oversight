//// A scripted browser for `main` and the tests: an http_gun client with a
//// cookie jar that follows redirects between the portal and the provider.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/http
import gleam/http/request
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/uri
import http_gun
import http_gun/config
import http_gun/destination
import http_gun/error

pub type Browser {
  Browser(client: http_gun.Client, jar: Dict(String, String))
}

pub type Page {
  Page(url: String, status: Int, location: Option(String), body: String)
}

/// The browser trusts the test provider's root (`hellhound/testing` publishes
/// it as DER) and may reach loopback, like a developer's browser would.
pub fn new(root_der: BitArray) -> Browser {
  let assert Ok(client) =
    config.default()
    |> config.with_trust(config.Anchors([root_der]))
    |> config.with_request_timeout(config.After(duration.seconds(10)))
    |> config.with_destination(destination.loopback_only())
    |> http_gun.start
  Browser(client:, jar: dict.new())
}

pub fn close(browser: Browser) -> Nil {
  http_gun.stop(browser.client)
}

/// One request; cookies are recorded, redirects are not followed.
pub fn request(
  browser: Browser,
  method: http.Method,
  url: String,
) -> Result(#(Browser, Page), String) {
  use base <- result.try(
    request.to(url) |> result.replace_error("bad url " <> url),
  )
  let cookies =
    dict.to_list(browser.jar)
    |> list.map(fn(pair) { pair.0 <> "=" <> pair.1 })
    |> string.join("; ")
  let req =
    base
    |> request.set_method(method)
    |> request.set_body(<<>>)
  let req = case cookies {
    "" -> req
    _ -> request.set_header(req, "cookie", cookies)
  }
  use buffered <- result.try(
    http_gun.send(browser.client, req)
    |> result.map_error(fn(f) { "http: " <> error.describe(f) }),
  )
  let response = buffered.response
  let jar =
    list.fold(response.headers, browser.jar, fn(jar, header) {
      case header {
        #("set-cookie", value) -> store_cookie(jar, value)
        _ -> jar
      }
    })
  let location =
    list.key_find(response.headers, "location")
    |> result.map(fn(target) { resolve(url, target) })
    |> option.from_result
  Ok(#(
    Browser(..browser, jar:),
    Page(
      url:,
      status: response.status,
      location:,
      body: bit_array.to_string(response.body) |> result.unwrap(""),
    ),
  ))
}

pub fn get(browser: Browser, url: String) -> Result(#(Browser, Page), String) {
  request(browser, http.Get, url)
}

/// GET and follow up to ten redirects.
pub fn visit(
  browser: Browser,
  url: String,
) -> Result(#(Browser, Page), String) {
  follow(browser, http.Get, url, 10)
}

pub fn post(browser: Browser, url: String) -> Result(#(Browser, Page), String) {
  follow(browser, http.Post, url, 10)
}

fn follow(
  browser: Browser,
  method: http.Method,
  url: String,
  hops: Int,
) -> Result(#(Browser, Page), String) {
  use #(browser, page) <- result.try(request(browser, method, url))
  case page.location, hops {
    Some(next), n if n > 0 -> follow(browser, http.Get, next, n - 1)
    _, _ -> Ok(#(browser, page))
  }
}

fn store_cookie(
  jar: Dict(String, String),
  header: String,
) -> Dict(String, String) {
  let parts = string.split(header, ";") |> list.map(string.trim)
  case parts {
    [pair, ..attributes] ->
      case string.split_once(pair, "=") {
        Ok(#(name, value)) -> {
          let expired =
            value == ""
            || list.any(attributes, fn(a) { string.lowercase(a) == "max-age=0" })
          case expired {
            True -> dict.delete(jar, name)
            False -> dict.insert(jar, name, value)
          }
        }
        Error(Nil) -> jar
      }
    [] -> jar
  }
}

fn resolve(base: String, target: String) -> String {
  case uri.parse(base), uri.parse(target) {
    Ok(base), Ok(relative) ->
      uri.merge(base, relative)
      |> result.map(uri.to_string)
      |> result.unwrap(target)
    _, _ -> target
  }
}
