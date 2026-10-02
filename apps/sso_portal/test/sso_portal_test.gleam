import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit
import pog
import sso_portal/access
import sso_portal/app.{type App}
import sso_portal/billing_api
import sso_portal/browser.{type Browser}
import sso_portal/fake_idp
import sso_portal/session_store
import sso_portal/telemetry
import warden

pub fn main() -> Nil {
  gleeunit.main()
}

// --- Harness ----------------------------------------------------------------

/// Options with a subject unique to the test, so row counts are per test.
fn options() -> app.Options {
  let defaults = app.default_options()
  app.Options(
    ..defaults,
    idp: fake_idp.Settings(
      ..defaults.idp,
      subject: "user-" <> int.to_string(int.random(1_000_000_000)),
    ),
  )
}

fn with_app(options: app.Options, run: fn(App, Browser) -> Nil) -> Nil {
  let assert Ok(portal) = app.start(options)
  let b = browser.new(portal.pki)
  run(portal, b)
  browser.close(b)
  app.stop(portal)
}

fn sign_in(portal: App, b: Browser) -> Browser {
  let assert Ok(#(b, page)) =
    browser.visit(b, portal.portal_url <> "/dashboard")
  assert page.status == 200
  assert string.contains(page.body, "INV-1001")
  b
}

fn rows(portal: App) -> Int {
  let assert Ok(n) =
    session_store.count(portal.db, fake_idp.settings(portal.idp).subject)
  n
}

// --- Common path -------------------------------------------------------------

pub fn login_dashboard_logout_test() {
  use portal, b <- with_app(options())
  let b = sign_in(portal, b)
  assert rows(portal) == 1
  assert fake_idp.stats(portal.idp).code_grants == 1

  let assert Ok(#(b, page)) = browser.post(b, portal.portal_url <> "/logout")
  // RP-initiated logout lands on the provider's end-session endpoint.
  assert string.starts_with(page.url, fake_idp.issuer(portal.idp) <> "/logout")
  assert fake_idp.stats(portal.idp).end_session_visits == 1
  assert rows(portal) == 0

  let assert Ok(#(_, page)) = browser.get(b, portal.portal_url <> "/dashboard")
  assert page.location == Some(portal.portal_url <> "/login")
}

// --- Refresh -----------------------------------------------------------------

pub fn token_near_expiry_is_refreshed_before_billing_test() {
  // Advanced: tokens live 20 s and the portal refreshes 30 s ahead.
  let o = options()
  let o =
    app.Options(
      ..o,
      idp: fake_idp.Settings(..o.idp, access_ttl_seconds: 20),
      access_policy: access.Policy(..o.access_policy, expiry_margin_seconds: 30),
    )
  use portal, b <- with_app(o)
  let b = sign_in(portal, b)
  assert fake_idp.stats(portal.idp).refresh_grants == 1
  let _ = sign_in(portal, b)
  let stats = fake_idp.stats(portal.idp)
  assert stats.refresh_grants == 2
  // Rotation: only the newest refresh token is live at the provider.
  assert stats.active_refresh_tokens == 1
}

pub fn billing_401_refreshes_and_retries_in_one_request_test() {
  use portal, b <- with_app(options())
  let b = sign_in(portal, b)
  fake_idp.revoke_access_tokens(portal.idp)
  let _ = sign_in(portal, b)
  assert fake_idp.stats(portal.idp).refresh_grants == 1

  // The request is followable across packages only through app glue: the
  // Warden token call and both http_gun billing calls share one trace.
  let trace =
    telemetry.last_request_trace(portal.telemetry)
    |> list.map(telemetry.describe)
  assert list.contains(
    trace,
    "[http_gun.lifecycle] response_headers(401) (correlated)",
  )
  assert list.contains(
    trace,
    "[http_gun.lifecycle] response_headers(200) (correlated)",
  )
  assert list.any(trace, string.starts_with(
    _,
    "[warden.http.request] POST /token -> 200",
  ))
}

pub fn concurrent_requests_share_one_refresh_test() {
  // Advanced: the provider answers refresh grants slowly, so two dashboard
  // requests that both see a 401 race for the same refresh.
  let o = options()
  let o =
    app.Options(..o, idp: fake_idp.Settings(..o.idp, refresh_delay_ms: 300))
  use portal, b <- with_app(o)
  let b = sign_in(portal, b)
  fake_idp.revoke_access_tokens(portal.idp)
  let results = process.new_subject()
  list.each([1, 2], fn(_) {
    process.spawn(fn() {
      let assert Ok(#(_, page)) =
        browser.get(b, portal.portal_url <> "/dashboard")
      process.send(results, page.status)
    })
  })
  let assert Ok(first) = process.receive(results, 4000)
  let assert Ok(second) = process.receive(results, 4000)
  assert #(first, second) == #(200, 200)
  let stats = fake_idp.stats(portal.idp)
  // Warden's reservation let exactly one refresh token reach the provider.
  assert stats.refresh_grants == 1
  assert stats.rejected_refresh_grants == 0
}

// --- Clock tolerance -----------------------------------------------------------

pub fn provider_clock_ahead_needs_tolerance_test() {
  // The provider's clock runs 20 s ahead: `iat` is in the future.
  let o = options()
  let skewed =
    app.Options(..o, idp: fake_idp.Settings(..o.idp, iat_skew_seconds: 20))
  {
    use portal, b <- with_app(skewed)
    let assert Ok(#(_, page)) =
      browser.visit(b, portal.portal_url <> "/dashboard")
    assert page.status == 401
    assert string.contains(page.body, "IdTokenNotYetValid")
    assert rows(portal) == 0
  }
  use portal, b <- with_app(
    app.Options(..skewed, clock_tolerance_seconds: Some(60)),
  )
  let _ = sign_in(portal, b)
  assert rows(portal) == 1
}

// --- Failure paths ---------------------------------------------------------------

pub fn tampered_callback_state_is_rejected_test() {
  use portal, b <- with_app(options())
  let assert Ok(#(b, login)) = browser.get(b, portal.portal_url <> "/login")
  let assert Some(authorize) = login.location
  let assert Ok(#(b, consent)) = browser.get(b, authorize)
  let assert Some(callback) = consent.location
  let assert Ok(#(before, after)) = string.split_once(callback, "state=")
  let tampered = before <> "state=x" <> after
  let assert Ok(#(_, page)) = browser.get(b, tampered)
  assert page.status == 400
  assert string.contains(page.body, "UnknownState")
  // The code was never exchanged and no session exists.
  assert fake_idp.stats(portal.idp).code_grants == 0
  assert rows(portal) == 0
}

pub fn revoked_refresh_token_forces_relogin_test() {
  use portal, b <- with_app(options())
  let b = sign_in(portal, b)
  fake_idp.revoke_refresh_tokens(portal.idp)
  fake_idp.revoke_access_tokens(portal.idp)
  let assert Ok(#(b, page)) = browser.get(b, portal.portal_url <> "/dashboard")
  assert page.location == Some(portal.portal_url <> "/login")
  assert fake_idp.stats(portal.idp).rejected_refresh_grants == 1
  assert rows(portal) == 0
  // Signing in again works.
  let _ = sign_in(portal, b)
  assert rows(portal) == 1
}

pub fn billing_down_keeps_the_session_test() {
  use portal, b <- with_app(options())
  let b = sign_in(portal, b)
  billing_api.stop(portal.billing_api)
  let assert Ok(#(_, page)) = browser.get(b, portal.portal_url <> "/dashboard")
  assert page.status == 503
  assert string.contains(page.body, "ConnectionFailed")
  assert rows(portal) == 1
  assert fake_idp.stats(portal.idp).refresh_grants == 0
}

// --- Durable sessions --------------------------------------------------------------

pub fn sessions_survive_web_restart_but_not_warden_restart_test() {
  let assert Ok(portal) = app.start(options())
  let b = sign_in(portal, browser.new(portal.pki))

  // The web tier restarts: Postgres row + Warden custody carry the session.
  let assert Ok(portal) = app.restart_portal(portal)
  let assert Ok(#(b, page)) = browser.get(b, portal.portal_url <> "/dashboard")
  assert page.status == 200

  // Warden restarts: its in-memory custody is gone, so the durable row is
  // useless and the user must sign in again.
  let assert Ok(portal) = app.restart_warden(portal)
  let assert Ok(#(_, page)) = browser.get(b, portal.portal_url <> "/dashboard")
  assert page.location == Some(portal.portal_url <> "/login")
  assert rows(portal) == 0
  browser.close(b)
  app.stop(portal)
}

pub fn logout_with_a_stale_session_revision_keeps_custody_test() {
  // Two requests hold the same session; one refreshes, the other logs out.
  use portal, b <- with_app(options())
  let _ = sign_in(portal, b)
  let assert Ok(pog.Returned(rows: [reference], ..)) =
    pog.query("select warden_reference from portal_sessions where subject = $1")
    |> pog.parameter(pog.text(fake_idp.settings(portal.idp).subject))
    |> pog.returning(decode.at([0], decode.string))
    |> pog.execute(portal.db)
  let assert Ok(held) = warden.restore_session(portal.warden, reference)
  let assert Ok(warden.RefreshCompleted(_)) =
    warden.refresh_session(portal.warden, held)
  let no_redirect =
    warden.LogoutOptions(
      post_logout_redirect_uri: option.None,
      state: option.None,
    )
  let assert Error(warden.LogoutSession(warden.SessionStale)) =
    warden.logout(portal.warden, held, no_redirect)
  // The session the user asked to end is still live in custody.
  let assert Ok(_) = warden.restore_session(portal.warden, reference)
  Nil
}
