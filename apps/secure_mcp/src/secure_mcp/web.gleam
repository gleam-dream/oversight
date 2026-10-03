//// The wisp application: Warden's relying-party routes for the browser.
//// `/mcp` and its RFC 9728 metadata are Relay's endpoint, mounted beside
//// these routes in the same mist listener (see `app`).

import gleam/http
import gleam/http/request
import gleam/json
import gleam/option
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import gleam/uri
import warden
import warden/testing
import wisp.{type Request, type Response}

pub type Context {
  Context(
    warden: warden.Client,
    /// The scripted provider plays the provider's login page.
    provider: testing.Provider,
    /// The MCP endpoint URL; also the token audience (RFC 8707 resource).
    mcp_url: String,
  )
}

const session_cookie = "smcp_session"

pub fn handle(req: Request, context: Context) -> Response {
  use <- wisp.rescue_crashes
  case req.method, wisp.path_segments(req) {
    http.Get, [] ->
      wisp.ok() |> wisp.string_body("secure_mcp: sign in at /login?as=<user>")
    http.Get, ["login"] -> login(req, context)
    http.Get, ["auth", "callback"] -> callback(req, context)
    http.Get, ["me", "token"] -> my_token(req, context)
    _, _ -> wisp.not_found()
  }
}

// --- Browser login (Warden relying party) -------------------------------------

/// Starts a login and, because the provider is scripted, signs in as `as` at
/// once: the redirect goes straight to the callback the provider would
/// send, with Warden's binding cookie.
fn login(req: Request, context: Context) -> Response {
  // The MCP endpoint is the token audience: RFC 8707 `resource` travels as a
  // Warden extension parameter.
  let options =
    warden.LoginOptions(..warden.default_login(), extra_parameters: [
      #("resource", context.mcp_url),
    ])
  case wisp.get_query(req), warden.begin_login(context.warden, req, options) {
    _, Error(error) ->
      wisp.response(503)
      |> wisp.string_body(
        "sign-in unavailable: " <> warden.describe_login_error(error),
      )
    [#("as", user)], Ok(redirect) ->
      // GLUE (warden/testing): `authorize` takes the in-process
      // `LoginRedirect`, and the provider serves no `/authorize` page, so the
      // app answers for the provider instead of redirecting the browser there.
      case testing.authorize(context.provider, redirect, subject: user) {
        Ok(callback) ->
          warden.login_response(wisp.response(303), redirect)
          |> wisp.set_header(
            "location",
            uri.to_string(request.to_uri(callback)),
          )
        Error(error) ->
          wisp.response(502) |> wisp.string_body(string.inspect(error))
      }
    _, Ok(_) -> wisp.bad_request("sign in with /login?as=<user>")
  }
}

fn callback(req: Request, context: Context) -> Response {
  let completed = case
    warden.complete_login(context.warden, request.set_body(req, ""))
  {
    Ok(session) -> Ok(session)
    Error(warden.CustodyUnconfirmed(recovery)) ->
      warden.recover_custody(context.warden, recovery)
    Error(error) -> Error(error)
  }
  case completed {
    Ok(session) ->
      wisp.redirect("/me/token")
      |> wisp.set_cookie(
        req,
        session_cookie,
        warden.session_reference(session),
        wisp.Signed,
        3600,
      )
    Error(error) ->
      wisp.response(400)
      |> wisp.string_body(
        "sign-in failed: " <> warden.describe_login_error(error),
      )
  }
}

/// Hands the signed-in user the access token to paste into an MCP client.
/// Warden is a relying party only, so the app has no authorization-server
/// flow of its own for MCP clients; see FEEDBACK SMCP-6.
fn my_token(req: Request, context: Context) -> Response {
  let session =
    wisp.get_cookie(req, session_cookie, wisp.Signed)
    |> result.try(fn(reference) {
      warden.restore_session(context.warden, reference)
      |> result.replace_error(Nil)
    })
  case session {
    Error(Nil) -> wisp.redirect("/login")
    Ok(session) ->
      case warden.access_token(context.warden, session) {
        Error(error) ->
          wisp.response(409)
          |> wisp.string_body(warden.describe_session_error(error))
        Ok(access) ->
          json.object([
            #(
              "subject",
              json.string(warden.subject(warden.session_identity(session))),
            ),
            #(
              "access_token",
              json.string(warden.access_token_value(access.token)),
            ),
            #(
              "expires_at",
              json.nullable(
                option.map(access.expires_at, timestamp.to_rfc3339(
                  _,
                  calendar.utc_offset,
                )),
                json.string,
              ),
            ),
            #("mcp_url", json.string(context.mcp_url)),
          ])
          |> json.to_string
          |> wisp.json_response(200)
          |> wisp.set_header("cache-control", "no-store")
      }
  }
}
