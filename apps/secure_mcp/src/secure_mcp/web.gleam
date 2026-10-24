//// The wisp application: Warden's relying-party routes for the browser.
//// `/mcp` and its RFC 9728 metadata are Relay's endpoint, mounted beside
//// these routes in the same mist listener (see `app`).

import gleam/http
import gleam/http/request
import gleam/json
import gleam/option
import gleam/result
import gleam/time/calendar
import gleam/time/timestamp
import warden
import wisp.{type Request, type Response}

pub type Context {
  Context(
    warden: warden.Client,
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

/// Starts a login: the browser follows Warden's redirect to the provider's
/// `/authorize`. `?as=<user>` goes along as the OpenID `login_hint`, which the
/// scripted provider signs in as.
fn login(req: Request, context: Context) -> Response {
  // The MCP endpoint is the token audience: RFC 8707 `resource` travels as a
  // Warden extension parameter.
  let hint = case wisp.get_query(req) {
    [#("as", user)] -> option.Some(user)
    _ -> option.None
  }
  let options =
    warden.LoginOptions(
      ..warden.default_login(),
      login_hint: hint,
      extra_parameters: [#("resource", context.mcp_url)],
    )
  case warden.begin_login(context.warden, req, options) {
    Ok(redirect) -> warden.login_response(wisp.response(303), redirect)
    Error(error) ->
      wisp.response(503)
      |> wisp.string_body(
        "sign-in unavailable: " <> warden.describe_login_error(error),
      )
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
/// Warden supplies the relying-party login. MCP clients use the issued token;
/// this application does not run its own authorization server.
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
