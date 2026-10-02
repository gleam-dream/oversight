//// Portal routes (wisp). Warden is reached through strings: the raw query
//// string, cookie values and a custody reference.

import gleam/http
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import http_gun
import pog
import sso_portal/access
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
    access_policy: access.Policy,
  )
}

const binding_cookie = "portal_login"

const session_cookie = "portal_session"

const session_max_age = 3600

pub fn handle(request: Request, context: Context) -> Response {
  use <- wisp.rescue_crashes
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

// --- Login ------------------------------------------------------------------

fn login(request: Request, context: Context) -> Response {
  // Seam: the binding cookie is a string Warden parses itself.
  let binding =
    wisp.get_cookie(request, binding_cookie, wisp.PlainText)
    |> result.try(warden.parse_browser_binding)
    |> option.from_result
  case warden.begin_login(context.warden, binding, warden.default_login()) {
    Ok(redirect) ->
      wisp.redirect(redirect.url)
      |> wisp.set_cookie(
        request,
        binding_cookie,
        warden.browser_binding_value(redirect.browser_binding),
        wisp.PlainText,
        600,
      )
    Error(error) ->
      page(503, "Sign-in unavailable", wisp.escape_html(string.inspect(error)))
  }
}

fn callback(request: Request, context: Context) -> Response {
  let binding =
    wisp.get_cookie(request, binding_cookie, wisp.PlainText)
    |> result.try(warden.parse_browser_binding)
    |> option.from_result
  // Seam: Warden wants the raw query string, not wisp's parsed pairs.
  let query = option.unwrap(request.query, "")
  let completed = case
    warden.complete_login(context.warden, warden.QueryCallback(query), binding)
  {
    Ok(warden.LoginCompleted(session)) -> Ok(session)
    Ok(warden.LoginRecoveryRequired(recovery)) ->
      case warden.recover_custody(context.warden, recovery) {
        Ok(warden.CustodyRecovered(session)) -> Ok(session)
        _ -> Error(#(503, "sign-in could not be confirmed"))
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
          |> wisp.set_cookie(request, binding_cookie, "", wisp.PlainText, 0)
        Error(_) -> {
          let _ = warden.logout(context.warden, session, no_redirect())
          page(503, "Sign-in failed", "<p>session store unavailable</p>")
        }
      }
    }
  }
}

/// Every Warden login error mapped to a status and a safe reason.
fn login_failure(error: warden.LoginError) -> #(Int, String) {
  case error {
    warden.CallbackMalformed(problem) -> #(
      400,
      "malformed callback: " <> string.inspect(problem),
    )
    warden.CallbackRejected(problem) -> #(
      400,
      "callback rejected: " <> string.inspect(problem),
    )
    warden.LoginExpired -> #(401, "the sign-in took too long")
    warden.LoginReplayed -> #(401, "this sign-in was already used")
    warden.LoginChanged -> #(401, "the sign-in changed")
    warden.TransactionStoreUnavailable -> #(503, "sign-in store unavailable")
    warden.ProviderDenied(denial) -> #(401, string.inspect(denial))
    warden.ProviderUnavailableBeforeExchange(_) -> #(
      503,
      "identity provider unreachable",
    )
    warden.ExchangeRejected(code) -> #(
      401,
      "exchange rejected: " <> string.inspect(code),
    )
    warden.ExchangeOutcomeUnknown -> #(503, "sign-in outcome unknown")
    warden.IdentityRejected(problem) -> #(
      401,
      "identity rejected: " <> string.inspect(problem),
    )
  }
}

// --- Session ----------------------------------------------------------------

type Current {
  Current(stored: session_store.StoredSession, session: warden.Session)
}

type NoSession {
  /// No cookie, or no row: an anonymous visitor.
  Anonymous
  /// The row exists but Warden's custody no longer knows the reference
  /// (logged out elsewhere, expired, or Warden restarted).
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
    Error(warden.SessionStoreUnavailable) -> Error(StoreDown)
    Error(_) -> {
      let _ = session_store.delete(context.db, stored.id)
      Error(CustodyLost)
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
  let _ = end_custody(context, current, no_redirect())
  let _ = session_store.delete(context.db, current.stored.id)
  Nil
}

/// `warden.logout` refuses a session value whose revision is stale (a
/// concurrent request refreshed it) and then leaves custody in place, so
/// restore by reference and try once more.
fn end_custody(
  context: Context,
  current: Current,
  options: warden.LogoutOptions,
) -> Result(warden.LogoutOutcome, warden.LogoutError) {
  case warden.logout(context.warden, current.session, options) {
    Error(warden.LogoutSession(warden.SessionStale)) ->
      case
        warden.restore_session(context.warden, current.stored.warden_reference)
      {
        Ok(latest) -> warden.logout(context.warden, latest, options)
        Error(error) -> Error(warden.LogoutSession(error))
      }
    other -> other
  }
}

// --- Dashboard --------------------------------------------------------------

type DashboardError {
  SignInAgain(String)
  BillingDown(String)
}

fn dashboard(request: Request, context: Context) -> Response {
  use current <- require_session(request, context)
  let correlation = telemetry.begin_request(context.telemetry)
  let client = http_gun.with_correlation(context.billing, correlation)
  case invoices(context, client, current.session) {
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
  client: http_gun.Client,
  session: warden.Session,
) -> Result(List(billing.Invoice), DashboardError) {
  use #(session, token) <- result.try(
    access.usable_token(context.warden, session, context.access_policy)
    |> result.map_error(access_error),
  )
  case billing.invoices(client, context.billing_url, token) {
    // The API may reject a token custody still believes is live (revoked,
    // or a clock disagreement): refresh once and retry.
    Error(billing.Unauthorized) -> {
      use #(_, token) <- result.try(
        access.refreshed(context.warden, session, context.access_policy)
        |> result.map_error(access_error),
      )
      billing.invoices(client, context.billing_url, token)
      |> result.map_error(billing_error)
    }
    other -> other |> result.map_error(billing_error)
  }
}

fn access_error(error: access.AccessError) -> DashboardError {
  case error {
    access.Reauthenticate(reason) -> SignInAgain(reason)
    access.TryLater(reason) -> BillingDown(reason)
  }
}

fn billing_error(error: billing.BillingError) -> DashboardError {
  case error {
    billing.Unauthorized -> SignInAgain("billing still refuses the token")
    billing.Unavailable(failure) -> BillingDown(string.inspect(failure.reason))
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
          post_logout_redirect_uri: Some(origin(request) <> "/signed-out"),
          state: Some(wisp.random_string(16)),
        )
      let target = case
        warden.logout(context.warden, current.session, options)
      {
        Ok(warden.RedirectToProvider(url)) -> url
        Ok(warden.NoEndSessionEndpoint) | Error(_) -> "/signed-out"
      }
      let _ = session_store.delete(context.db, current.stored.id)
      wisp.redirect(target) |> clear_session(request)
    }
  }
}

// --- Helpers ----------------------------------------------------------------

fn no_redirect() -> warden.LogoutOptions {
  warden.LogoutOptions(post_logout_redirect_uri: None, state: None)
}

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
