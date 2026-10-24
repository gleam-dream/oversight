//// Portal routes (wisp). Hellhound takes the browser's gleam_http request and
//// answers with a gleam_http response; the app keeps only a custody
//// reference in its own session row.

import gleam/http
import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import hellhound
import http_gun
import http_gun/error as gun_error
import pog
import sso_portal/billing
import sso_portal/session_store
import sso_portal/telemetry.{type Telemetry}
import wisp.{type Request, type Response}

pub type Context {
  Context(
    hellhound: hellhound.Client,
    db: pog.Connection,
    billing: http_gun.Client,
    billing_url: String,
    telemetry: Telemetry,
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

/// One correlation per request, on Hellhound's client and on the billing
/// client, so every event the request causes carries it.
fn traced(context: Context, next: fn(Context) -> Response) -> Response {
  let correlation = telemetry.begin_request(context.telemetry)
  next(
    Context(
      ..context,
      hellhound: hellhound.with_correlation(context.hellhound, correlation),
      billing: http_gun.with_correlation(context.billing, correlation),
    ),
  )
}

// --- Login ------------------------------------------------------------------

fn login(request: Request, context: Context) -> Response {
  case
    hellhound.begin_login(context.hellhound, request, hellhound.default_login())
  {
    Ok(redirect) -> hellhound.login_response(wisp.response(303), redirect)
    Error(error) ->
      page(
        503,
        "Sign-in unavailable",
        wisp.escape_html(hellhound.describe_login_error(error)),
      )
  }
}

fn callback(request: Request, context: Context) -> Response {
  let completed = case
    hellhound.complete_login(context.hellhound, request.set_body(request, ""))
  {
    Ok(session) -> Ok(session)
    Error(hellhound.CustodyUnconfirmed(recovery)) ->
      case hellhound.recover_custody(context.hellhound, recovery) {
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
      let identity = hellhound.session_identity(session)
      let stored =
        session_store.StoredSession(
          id: wisp.random_string(32),
          hellhound_reference: hellhound.session_reference(session),
          issuer: hellhound.issuer(identity),
          subject: hellhound.subject(identity),
          email: hellhound.email(identity),
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
            hellhound.logout(
              context.hellhound,
              session,
              hellhound.default_logout(),
            )
          page(503, "Sign-in failed", "<p>session store unavailable</p>")
        }
      }
    }
  }
}

/// A status and a safe reason for a login error.
fn login_failure(error: hellhound.LoginError) -> #(Int, String) {
  let status = case hellhound.login_error_action(error) {
    hellhound.RejectRequest -> 400
    hellhound.Reauthenticate -> 401
    hellhound.FixConfiguration -> 500
    hellhound.RetryLater | hellhound.Recover -> 503
  }
  #(status, hellhound.describe_login_error(error))
}

// --- Session ----------------------------------------------------------------

type Current {
  Current(stored: session_store.StoredSession, session: hellhound.Session)
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
  case
    hellhound.restore_session(context.hellhound, stored.hellhound_reference)
  {
    Ok(session) -> Ok(Current(stored:, session:))
    Error(error) ->
      case hellhound.session_error_action(error) {
        hellhound.RetryLater -> Error(StoreDown)
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

/// End the session everywhere the app can: Hellhound custody and the row.
fn end_session(context: Context, current: Current) -> Nil {
  let _ =
    hellhound.logout(
      context.hellhound,
      current.session,
      hellhound.default_logout(),
    )
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
  session: hellhound.Session,
) -> Result(List(billing.Invoice), DashboardError) {
  use access <- result.try(
    settled(context, fn() { hellhound.access_token(context.hellhound, session) }),
  )
  case billing.invoices(context.billing, context.billing_url, access.token) {
    // The API may reject a token custody still believes is live (revoked,
    // or a clock disagreement): refresh once and retry.
    Error(billing.Unauthorized) -> {
      use access <- result.try(
        settled(context, fn() {
          hellhound.refresh(context.hellhound, access.session)
        }),
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
  call: fn() -> Result(hellhound.Access, hellhound.SessionError),
) -> Result(hellhound.Access, DashboardError) {
  let recovered = case call() {
    Error(hellhound.RefreshUnconfirmed(recovery)) ->
      hellhound.recover_refresh(context.hellhound, recovery)
    other -> other
  }
  result.map_error(recovered, fn(error) {
    case hellhound.session_error_action(error) {
      hellhound.Reauthenticate ->
        SignInAgain(hellhound.describe_session_error(error))
      _ -> BillingDown(hellhound.describe_session_error(error))
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
        hellhound.LogoutOptions(
          ..hellhound.default_logout(),
          post_logout_redirect_uri: Some(origin(request) <> "/signed-out"),
          state: Some(wisp.random_string(16)),
        )
      let response = case
        hellhound.logout(context.hellhound, current.session, options)
      {
        Ok(hellhound.LoggedOut(
          provider_logout: hellhound.RedirectToProvider(to),
          ..,
        )) -> hellhound.logout_response(wisp.response(303), to)
        Ok(hellhound.LoggedOut(..)) | Error(_) -> wisp.redirect("/signed-out")
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
