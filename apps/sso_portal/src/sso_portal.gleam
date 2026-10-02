//// `gleam run`: one scripted browser walks through the portal and prints
//// what each package did. Needs Postgres: `../scripts/with-postgres.sh gleam run`.

import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/string
import sso_portal/app
import sso_portal/billing_api
import sso_portal/browser
import sso_portal/fake_idp
import sso_portal/session_store
import sso_portal/telemetry

pub fn main() -> Nil {
  let assert Ok(portal) = app.start(app.default_options())
  io.println("sso_portal")
  io.println(
    "  provider  "
    <> fake_idp.issuer(portal.idp)
    <> " (TLS, test root from public_key)",
  )
  io.println("  billing   " <> portal.billing_api.base_url)
  io.println("  portal    " <> portal.portal_url)

  let b = browser.new(portal.pki)
  step("1. Anonymous visit to /dashboard: login via Warden, then billing")
  let assert Ok(#(b, page)) =
    browser.visit(b, portal.portal_url <> "/dashboard")
  show(page)
  io.println("   postgres sessions for user-42: " <> sessions(portal))

  step("2. Billing rejects the token (revoked early): 401, refresh, retry")
  fake_idp.revoke_access_tokens(portal.idp)
  let assert Ok(#(b, page)) =
    browser.visit(b, portal.portal_url <> "/dashboard")
  show(page)
  io.println(
    "   refresh grants at provider: "
    <> int.to_string(fake_idp.stats(portal.idp).refresh_grants),
  )
  io.println("   one request, followed across packages:")
  telemetry.last_request_trace(portal.telemetry)
  |> list.each(fn(r) { io.println("     " <> telemetry.describe(r)) })

  step("3. Billing API goes down")
  billing_api.stop(portal.billing_api)
  let assert Ok(#(b, page)) =
    browser.visit(b, portal.portal_url <> "/dashboard")
  show(page)

  step("4. Sign out: custody removed, row deleted, provider end-session")
  let assert Ok(#(b, page)) = browser.post(b, portal.portal_url <> "/logout")
  show(page)
  io.println("   postgres sessions for user-42: " <> sessions(portal))
  io.println(
    "   provider refresh tokens still active after logout: "
    <> int.to_string(fake_idp.stats(portal.idp).active_refresh_tokens),
  )

  browser.close(b)
  app.stop(portal)
  io.println("done")
}

fn step(title: String) -> Nil {
  io.println("\n" <> title)
}

fn show(page: browser.Page) -> Nil {
  let summary =
    page.body
    |> string.replace("<", " <")
    |> strip_tags
    |> string.split(" ")
    |> list.filter(fn(w) { w != "" })
    |> string.join(" ")
  io.println(
    "   "
    <> int.to_string(page.status)
    <> " "
    <> case string.split_once(page.url, "?") {
      Ok(#(path, _)) -> path <> "?..."
      Error(Nil) -> page.url
    }
    <> option.unwrap(option.map(page.location, fn(l) { " -> " <> l }), "")
    <> "\n   "
    <> string.slice(summary, 0, 140),
  )
}

fn strip_tags(html: String) -> String {
  case string.split_once(html, "<") {
    Ok(#(before, rest)) ->
      case string.split_once(rest, ">") {
        Ok(#(_, after)) -> before <> " " <> strip_tags(after)
        Error(Nil) -> before
      }
    Error(Nil) -> html
  }
}

fn sessions(portal: app.App) -> String {
  case session_store.count(portal.db, "user-42") {
    Ok(n) -> int.to_string(n)
    Error(e) -> string.inspect(e)
  }
}
