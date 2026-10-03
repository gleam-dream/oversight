//// Portal routes (wisp). Warden takes the browser's gleam_http request and
//// answers with a gleam_http response; the app keeps only a custody
//// reference in its own session row.

import gleam/http
import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import http_gun
import http_gun/error as gun_error
import pog
import sso_portal/billing
import sso_portal/session_store
import sso_portal/telemetry.{type Telemetry}
import warden
import wisp.{type Request, type Response}

pub type Context {
  Context(
    warden: warden.Client,
    db: pog.Connection,
    billing: http_gun.Client,
    billing_url: String,
    telemetry: Telemetry,
    /// Turns the 303 for a started login into the response sent to the
    /// browser. Production: `warden.login_response`. The tests replace the
    /// provider's login page, which `warden/testing` does not serve.
    login_response: fn(Response, warden.LoginRedirect) -> Response,
  )
}

const session_cookie = "portal_session"

const session_max_age = 3600

pub fn handle(request: Request, context: Context) -> Response {
  use <- wisp.rescue_crashes
  use context <- traced(context)
  case request.method, wisp.path_segments(request) {
    http.Get, [] -> page(200, "Portal", "<a href=\"/dashboard\">Dashboard</a>")
    http.Get, ["login"] -> login(request, context)
    http.Get, ["callback"] -> callback(request, context)
    http.Get, ["dashboard"] -> dashboard(request, context)
    http.Post, ["logout"] -> logout(request, context)
    http.Get, ["signed-out"] -> page(200, "Signed out", "<p>Goodbye.</p>")
    _, _ -> wisp.not_found()
  }
}

/// One correlation per request, on Warden's client and on the billing
/// client, so every event the request causes carries it.
fn traced(context: Context, next: fn(Context) -> Response) -> Response {
  let correlation = telemetry.begin_request(context.telemetry)
  next(
    Context(
      ..context,
      warden: warden.with_correlation(context.warden, correlation),
      billing: http_gun.with_correlation(context.billing, correlation),
    ),
  )
}

// --- Login ------------------------------------------------------------------

fn login(request: Request, context: Context) -> Response {
  case warden.begin_login(context.warden, request, warden.default_login()) {
    Ok(redirect) -> context.login_response(wisp.response(303), redirect)
    Error(error) ->
      page(
        503,
        "Sign-in unavailable",
        wisp.escape_html(warden.describe_login_error(error)),
      )
  }
}

fn callback(request: Request, context: Context) -> Response {
  let completed = case
    warden.complete_login(context.warden, request.set_body(request, ""))
  {
    Ok(session) -> Ok(session)
    Error(warden.CustodyUnconfirmed(recovery)) ->
      case warden.recover_custody(context.warden, recovery) {
        Ok(session) -> Ok(session)
        Error(_) -> Error(#(503, "sign-in could not be confirmed"))
      }
    Error(error) -> Error(login_failure(error))
  }
  case completed {
    Error(#(status, reason)) ->
      page(
        status,
        "Sign-in failed",
        "<p id=\"reason\">"
          <> wisp.escape_html(reason)
          <> "</p><a href=\"/login\">Try again</a>",
      )
    Ok(session) -> {
      let identity = warden.session_identity(session)
      let stored =
        session_store.StoredSession(
          id: wisp.random_string(32),
          warden_reference: warden.session_reference(session),
          issuer: warden.issuer(identity),
          subject: warden.subject(identity),
          email: warden.email(identity),
        )
      case session_store.insert(context.db, stored) {
        Ok(Nil) ->
          wisp.redirect("/dashboard")
          |> wisp.set_cookie(
            request,
            session_cookie,
            stored.id,
            wisp.Signed,
            session_max_age,
          )
        Error(_) -> {
          let _ =
            warden.logout(context.warden, session, warden.default_logout())
          page(503, "Sign-in failed", "<p>session store unavailable</p>")
        }
      }
    }
  }
}

/// A status and a safe reason for a login error.
fn login_failure(error: warden.LoginError) -> #(Int, String) {
  let status = case warden.login_error_action(error) {
    warden.RejectRequest -> 400
    warden.Reauthenticate -> 401
    warden.FixConfiguration -> 500
    warden.RetryLater | warden.Recover -> 503
  }
  #(status, warden.describe_login_error(error))
}

// --- Session ----------------------------------------------------------------

type Current {
  Current(stored: session_store.StoredSession, session: warden.Session)
}

type NoSession {
  /// No cookie, or no row: an anonymous visitor.
  Anonymous
  /// The row exists but custody no longer holds the reference (logged out
  /// elsewhere or expired).
  CustodyLost
  StoreDown
}

fn current(request: Request, context: Context) -> Result(Current, NoSession) {
  use id <- result.try(
    wisp.get_cookie(request, session_cookie, wisp.Signed)
    |> result.replace_error(Anonymous),
  )
  use found <- result.try(
    session_store.touch(context.db, id) |> result.replace_error(StoreDown),
  )
  use stored <- result.try(found |> result.replace_error(Anonymous))
  case warden.restore_session(context.warden, stored.warden_reference) {
    Ok(session) -> Ok(Current(stored:, session:))
    Error(error) ->
      case warden.session_error_action(error) {
        warden.RetryLater -> Error(StoreDown)
        _ -> {
          let _ = session_store.delete(context.db, stored.id)
          Error(CustodyLost)
        }
      }
  }
}

fn require_session(
  request: Request,
  context: Context,
  next: fn(Current) -> Response,
) -> Response {
  case current(request, context) {
    Ok(current) -> next(current)
    Error(StoreDown) -> page(503, "Try again later", "<p>sessions down</p>")
    Error(Anonymous) | Error(CustodyLost) ->
      wisp.redirect("/login") |> clear_session(request)
  }
}

/// End the session everywhere the app can: Warden custody and the row.
fn end_session(context: Context, current: Current) -> Nil {
  let _ =
    warden.logout(context.warden, current.session, warden.default_logout())
  let _ = session_store.delete(context.db, current.stored.id)
  Nil
}

// --- Dashboard --------------------------------------------------------------

type DashboardError {
  SignInAgain(String)
  BillingDown(String)
}

fn dashboard(request: Request, context: Context) -> Response {
  use current <- require_session(request, context)
  case invoices(context, current.session) {
    Ok(invoices) ->
      page(
        200,
        "Dashboard",
        "<p id=\"user\">"
          <> wisp.escape_html(option.unwrap(current.stored.email, ""))
          <> "</p><ul>"
          <> string.concat(
          list.map(invoices, fn(invoice) {
            "<li class=\"invoice\">"
            <> wisp.escape_html(invoice.id)
            <> " "
            <> int.to_string(invoice.amount_cents)
            <> " "
            <> wisp.escape_html(invoice.status)
            <> "</li>"
          }),
        )
          <> "</ul><form method=\"post\" action=\"/logout\"><button>Sign out</button></form>",
      )
    Error(SignInAgain(_reason)) -> {
      end_session(context, current)
      wisp.redirect("/login") |> clear_session(request)
    }
    Error(BillingDown(reason)) ->
      page(
        503,
        "Billing unavailable",
        "<p id=\"reason\">" <> wisp.escape_html(reason) <> "</p>",
      )
  }
}

fn invoices(
  context: Context,
  session: warden.Session,
) -> Result(List(billing.Invoice), DashboardError) {
  use access <- result.try(
    settled(context, fn() { warden.access_token(context.warden, session) }),
  )
  case billing.invoices(context.billing, context.billing_url, access.token) {
    // The API may reject a token custody still believes is live (revoked,
    // or a clock disagreement): refresh once and retry.
    Error(billing.Unauthorized) -> {
      use access <- result.try(
        settled(context, fn() { warden.refresh(context.warden, access.session) }),
      )
      billing.invoices(context.billing, context.billing_url, access.token)
      |> result.map_error(billing_error)
    }
    other -> other |> result.map_error(billing_error)
  }
}

/// A token call's result as a dashboard decision, recovering an unconfirmed
/// refresh once.
fn settled(
  context: Context,
  call: fn() -> Result(warden.Access, warden.SessionError),
) -> Result(warden.Access, DashboardError) {
  let recovered = case call() {
    Error(warden.RefreshUnconfirmed(recovery)) ->
      warden.recover_refresh(context.warden, recovery)
    other -> other
  }
  result.map_error(recovered, fn(error) {
    case warden.session_error_action(error) {
      warden.Reauthenticate -> SignInAgain(warden.describe_session_error(error))
      _ -> BillingDown(warden.describe_session_error(error))
    }
  })
}

fn billing_error(error: billing.BillingError) -> DashboardError {
  case error {
    billing.Unauthorized -> SignInAgain("billing still refuses the token")
    billing.Unavailable(failure) -> BillingDown(gun_error.describe(failure))
    billing.UnexpectedStatus(status) ->
      BillingDown("billing answered " <> int.to_string(status))
    billing.MalformedBody -> BillingDown("billing answered nonsense")
  }
}

// --- Logout -----------------------------------------------------------------

fn logout(request: Request, context: Context) -> Response {
  case current(request, context) {
    Error(_) -> wisp.redirect("/signed-out") |> clear_session(request)
    Ok(current) -> {
      let options =
        warden.LogoutOptions(
          ..warden.default_logout(),
          post_logout_redirect_uri: Some(origin(request) <> "/signed-out"),
          state: Some(wisp.random_string(16)),
        )
      let response = case
        warden.logout(context.warden, current.session, options)
      {
        Ok(warden.LoggedOut(provider_logout: warden.RedirectToProvider(to), ..)) ->
          warden.logout_response(wisp.response(303), to)
        Ok(warden.LoggedOut(..)) | Error(_) -> wisp.redirect("/signed-out")
      }
      let _ = session_store.delete(context.db, current.stored.id)
      clear_session(response, request)
    }
  }
}

// --- Helpers ----------------------------------------------------------------

fn clear_session(response: Response, request: Request) -> Response {
  wisp.set_cookie(response, request, session_cookie, "", wisp.Signed, 0)
}

/// This app's origin as the browser sees it, for the post-logout redirect.
fn origin(request: Request) -> String {
  let port = case request.port {
    Some(port) -> ":" <> int.to_string(port)
    None -> ""
  }
  http.scheme_to_string(request.scheme) <> "://" <> request.host <> port
}

fn page(status: Int, title: String, body: String) -> Response {
  wisp.html_response(
    "<!doctype html><title>"
      <> wisp.escape_html(title)
      <> "</title><h1>"
      <> wisp.escape_html(title)
      <> "</h1>"
      <> body,
    status,
  )
}
