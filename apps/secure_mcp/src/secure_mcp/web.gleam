//// The wisp application: Warden's relying-party routes for the browser, the
//// RFC 9728 protected-resource metadata, and the protected MCP endpoint.

import gleam/http
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import relay/authorization.{type ProtectionConfig}
import relay/server.{type Server}
import secure_mcp/auth
import secure_mcp/dev_provider
import secure_mcp/mcp_mount
import secure_mcp/telemetry
import secure_mcp/tools.{type McpContext, McpContext}
import warden
import wisp.{type Request, type Response}

pub type Context {
  Context(
    warden: warden.Client,
    mcp: Server(McpContext),
    protection: ProtectionConfig,
    issuer: String,
    /// The MCP endpoint URL; also the token audience (RFC 8707 resource).
    mcp_url: String,
    metadata_url: String,
  )
}

const binding_cookie = "smcp_binding"

const session_cookie = "smcp_session"

pub fn handle(req: Request, context: Context) -> Response {
  use <- wisp.rescue_crashes
  case req.method, wisp.path_segments(req) {
    http.Get, [] ->
      wisp.ok() |> wisp.string_body("secure_mcp: sign in at /login")
    http.Get, ["login"] -> login(req, context)
    http.Get, ["auth", "callback"] -> callback(req, context)
    http.Get, ["me", "token"] -> my_token(req, context)
    http.Get, [".well-known", "oauth-protected-resource", "mcp"] ->
      resource_metadata(context)
    _, ["mcp"] -> mcp(req, context)
    _, _ -> wisp.not_found()
  }
}

// --- Browser login (Warden relying party) -------------------------------------

fn login(req: Request, context: Context) -> Response {
  let binding =
    wisp.get_cookie(req, binding_cookie, wisp.PlainText)
    |> result.try(warden.parse_browser_binding)
    |> option.from_result
  let hint = case wisp.get_query(req) {
    [#("as", user)] -> Some(user)
    _ -> None
  }
  // The MCP endpoint is the token audience: RFC 8707 `resource` travels as a
  // Warden extension parameter.
  let options =
    warden.LoginOptions(
      ..warden.default_login(),
      scopes: ["reports"],
      login_hint: hint,
      extra_parameters: [#("resource", context.mcp_url)],
    )
  case warden.begin_login(context.warden, binding, options) {
    Ok(redirect) ->
      wisp.redirect(redirect.url)
      |> wisp.set_cookie(
        req,
        binding_cookie,
        warden.browser_binding_value(redirect.browser_binding),
        wisp.PlainText,
        900,
      )
    Error(error) ->
      wisp.response(503)
      |> wisp.string_body("sign-in unavailable: " <> string.inspect(error))
  }
}

fn callback(req: Request, context: Context) -> Response {
  let binding =
    wisp.get_cookie(req, binding_cookie, wisp.PlainText)
    |> result.try(warden.parse_browser_binding)
    |> option.from_result
  let query = option.unwrap(req.query, "")
  let completed = case
    warden.complete_login(context.warden, warden.QueryCallback(query), binding)
  {
    Ok(warden.LoginCompleted(session)) -> Ok(session)
    Ok(warden.LoginRecoveryRequired(recovery)) ->
      case warden.recover_custody(context.warden, recovery) {
        Ok(warden.CustodyRecovered(session)) -> Ok(session)
        other -> Error(string.inspect(other))
      }
    Error(error) -> Error(string.inspect(error))
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
    Error(reason) ->
      wisp.response(400) |> wisp.string_body("sign-in failed: " <> reason)
  }
}

/// Hands the signed-in user the access token to paste into an MCP client.
/// Warden is a relying party only, so the app has no authorization-server
/// flow of its own for MCP clients; see FEEDBACK SMCP-5.
fn my_token(req: Request, context: Context) -> Response {
  let session =
    wisp.get_cookie(req, session_cookie, wisp.Signed)
    |> result.replace_error(Nil)
    |> result.try(fn(reference) {
      warden.restore_session(context.warden, reference)
      |> result.replace_error(Nil)
    })
  case session {
    Error(Nil) -> wisp.redirect("/login")
    Ok(session) ->
      case warden.session_access_token(context.warden, session) {
        Error(error) ->
          wisp.response(409) |> wisp.string_body(string.inspect(error))
        Ok(#(token, expires_at)) ->
          json.object([
            #(
              "subject",
              json.string(warden.subject(warden.session_identity(session))),
            ),
            #("access_token", json.string(warden.access_token_value(token))),
            #("expires_at", json.nullable(expires_at, json.int)),
            #("mcp_url", json.string(context.mcp_url)),
          ])
          |> json.to_string
          |> wisp.json_response(200)
          |> wisp.set_header("cache-control", "no-store")
      }
  }
}

// --- Protected resource ---------------------------------------------------------

/// RFC 9728 protected-resource metadata. Relay does not publish it yet.
fn resource_metadata(context: Context) -> Response {
  json.object([
    #("resource", json.string(context.mcp_url)),
    #("authorization_servers", json.array([context.issuer], json.string)),
    #("scopes_supported", json.array(["reports"], json.string)),
    #("bearer_methods_supported", json.array(["header"], json.string)),
  ])
  |> json.to_string
  |> wisp.json_response(200)
}

fn mcp(req: Request, context: Context) -> Response {
  case
    auth.authenticate(
      req,
      context.warden,
      context.protection,
      dev_provider.now_seconds(),
    )
  {
    Error(failure) -> auth.challenge(failure, context.metadata_url)
    Ok(grant) -> {
      let principal = authorization.granted_principal(grant)
      let request_id = unique()
      mcp_mount.handle(
        req,
        context.mcp,
        McpContext(request_id:, principal:),
        mcp_mount.default_limits(),
        fn(exchange) {
          telemetry.mcp_request(
            request_id,
            server.exchange_id_to_int(exchange),
            principal.subject,
          )
        },
      )
    }
  }
}

@external(erlang, "secure_mcp_dev_ffi", "unique")
fn unique() -> Int
