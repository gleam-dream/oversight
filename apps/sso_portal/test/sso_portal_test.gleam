import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import gleeunit
import hellhound
import hellhound/store
import hellhound/testing
import pog
import sso_portal/app.{type App}
import sso_portal/billing_api
import sso_portal/browser.{type Browser}
import sso_portal/hellhound_records
import sso_portal/server
import sso_portal/session_store
import sso_portal/telemetry
import wisp

pub fn main() -> Nil {
  gleeunit.main()
}

// --- Harness ----------------------------------------------------------------

/// Options with a subject unique to the test, so row counts are per test.
fn options() -> app.Options {
  let defaults = app.default_options()
  app.Options(
    ..defaults,
    subject: "user-" <> int.to_string(int.random(1_000_000_000)),
  )
}

/// Options with the provider's behaviour changed.
fn provider(
  options: app.Options,
  change: fn(testing.ProviderOptions) -> testing.ProviderOptions,
) -> app.Options {
  app.Options(..options, provider: change(options.provider))
}

fn with_app(options: app.Options, run: fn(App, Browser) -> Nil) -> Nil {
  let assert Ok(portal) = app.start(options)
  let b = browser.new(testing.trust_anchor_der(portal.provider))
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
  let assert Ok(n) = session_store.count(portal.db, portal.options.subject)
  n
}

// --- Common path -------------------------------------------------------------

pub fn login_dashboard_logout_test() {
  use portal, b <- with_app(options())
  let b = sign_in(portal, b)
  assert rows(portal) == 1
  assert testing.requests(portal.provider).code_grants == 1
  assert testing.requests(portal.provider).active_refresh_tokens == 1

  let assert Ok(#(b, page)) = browser.post(b, portal.portal_url <> "/logout")
  // RP-initiated logout lands on the provider's end-session endpoint.
  assert string.starts_with(
    page.url,
    testing.issuer(portal.provider) <> "/logout",
  )
  let requests = testing.requests(portal.provider)
  assert requests.end_sessions == 1
  // RFC 7009: logout revoked the refresh token at the provider.
  assert requests.revocations == 1
  assert requests.active_refresh_tokens == 0
  assert rows(portal) == 0

  let assert Ok(#(_, page)) = browser.get(b, portal.portal_url <> "/dashboard")
  assert page.location == Some(portal.portal_url <> "/login")
}

// --- Refresh -----------------------------------------------------------------

pub fn token_near_expiry_is_refreshed_before_billing_test() {
  // Advanced: tokens live 20 s and the portal refreshes 30 s ahead.
  let o =
    options()
    |> provider(testing.with_access_token_ttl(_, duration.seconds(20)))
  let o = app.Options(..o, refresh_margin: Some(duration.seconds(30)))
  use portal, b <- with_app(o)
  let b = sign_in(portal, b)
  assert testing.requests(portal.provider).refresh_grants == 1
  let _ = sign_in(portal, b)
  let stats = testing.requests(portal.provider)
  assert stats.refresh_grants == 2
  // Rotation: only the newest refresh token is live at the provider.
  assert stats.active_refresh_tokens == 1
}

pub fn billing_401_refreshes_and_retries_in_one_request_test() {
  use portal, b <- with_app(options())
  let b = sign_in(portal, b)
  billing_api.deny_accepted_tokens(portal.billing_api)
  let _ = sign_in(portal, b)
  assert testing.requests(portal.provider).refresh_grants == 1

  // One correlation, set on Hellhound's client and on the billing client,
  // joins the Hellhound token call, its refresh outcome and both billing calls.
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
    "[hellhound.http.request] POST /token -> 200",
  ))
  assert list.contains(trace, "[hellhound.refresh] Refreshed")
}

pub fn concurrent_requests_share_one_refresh_test() {
  // Advanced: the provider answers refresh grants slowly, so two dashboard
  // requests that both see a 401 race for the same refresh.
  let o =
    options()
    |> provider(testing.with_refresh_delay(_, duration.milliseconds(300)))
  use portal, b <- with_app(o)
  let b = sign_in(portal, b)
  billing_api.deny_accepted_tokens(portal.billing_api)
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
  let stats = testing.requests(portal.provider)
  // Hellhound's reservation let exactly one refresh token reach the provider,
  // and the request that lost the race waited for it (no polling here).
  assert stats.refresh_grants == 1
  assert stats.rejected_refresh_grants == 0
}

// --- Clock tolerance -----------------------------------------------------------

pub fn provider_clock_ahead_needs_tolerance_test() {
  // The provider's clock runs 20 s ahead: `iat` is in the future.
  {
    use portal, b <- with_app(options())
    testing.set_clock_skew(portal.provider, duration.seconds(20))
    let assert Ok(#(_, page)) =
      browser.visit(b, portal.portal_url <> "/dashboard")
    assert page.status == 401
    assert string.contains(page.body, "not_yet_valid")
    assert rows(portal) == 0
  }
  let tolerant =
    app.Options(..options(), clock_tolerance: Some(duration.seconds(60)))
  use portal, b <- with_app(tolerant)
  testing.set_clock_skew(portal.provider, duration.seconds(20))
  let _ = sign_in(portal, b)
  assert rows(portal) == 1
}

// --- Failure paths ---------------------------------------------------------------

pub fn tampered_callback_state_is_rejected_test() {
  use portal, b <- with_app(options())
  let assert Ok(#(b, login)) = browser.get(b, portal.portal_url <> "/login")
  // The login redirect goes to the provider's /authorize, which signs the
  // scripted user in and redirects to the callback.
  let assert Some(authorize) = login.location
  let assert Ok(#(b, approved)) = browser.get(b, authorize)
  let assert Some(callback) = approved.location
  let assert Ok(#(before, after)) = string.split_once(callback, "state=")
  let tampered = before <> "state=x" <> after
  let assert Ok(#(_, page)) = browser.get(b, tampered)
  assert page.status == 400
  assert string.contains(page.body, "unknown state")
  // The code was never exchanged and no session exists.
  assert testing.requests(portal.provider).code_grants == 0
  assert rows(portal) == 0
}

pub fn revoked_refresh_token_forces_relogin_test() {
  use portal, b <- with_app(options())
  let b = sign_in(portal, b)
  testing.revoke_refresh_tokens(portal.provider, portal.options.subject)
  billing_api.deny_accepted_tokens(portal.billing_api)
  let assert Ok(#(b, page)) = browser.get(b, portal.portal_url <> "/dashboard")
  assert page.location == Some(portal.portal_url <> "/login")
  assert testing.requests(portal.provider).rejected_refresh_grants == 1
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
  assert string.contains(page.body, "Connection failed")
  assert string.contains(page.body, "not sent")
  assert rows(portal) == 1
  assert testing.requests(portal.provider).refresh_grants == 0
}

// --- Durable sessions --------------------------------------------------------------

pub fn occupied_port_start_failure_does_not_kill_the_caller_test() {
  let handler = fn(_) { wisp.response(200) }
  let secret = wisp.random_string(64)
  let assert Ok(held) = server.start(handler, secret, None)
  let replies = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      let assert Error(_) = server.start_on(handler, secret, held.port, None)
      // A refused bind is a returned error. The caller must remain able to
      // start and stop another listener after handling it.
      let assert Ok(recovered) = server.start(handler, secret, None)
      server.stop(recovered)
      process.send(replies, True)
    })
  let monitor = process.monitor(caller)
  let observed =
    process.new_selector()
    |> process.select(replies)
    |> process.select_specific_monitor(monitor, fn(_) { False })
    |> process.selector_receive(5000)
  server.stop(held)
  assert observed == Ok(True)
}

pub fn caller_exit_releases_its_listener_test() {
  let handler = fn(_) { wisp.response(200) }
  let secret = wisp.random_string(64)
  let replies = process.new_subject()
  let _caller =
    process.spawn_unlinked(fn() {
      let release = process.new_subject()
      let assert Ok(listener) = server.start(handler, secret, None)
      process.send(replies, #(listener, release))
      let assert Ok(Nil) = process.receive(release, 5000)
    })
  let assert Ok(#(listener, release)) = process.receive(replies, 5000)
  let monitor = process.monitor(listener.pid)
  process.send(release, Nil)
  let assert Ok(Nil) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(5000)
  let assert Ok(rebound) = server.start_on(handler, secret, listener.port, None)
  server.stop(rebound)
}

pub fn sessions_survive_web_and_hellhound_restarts_test() {
  let assert Ok(portal) = app.start(options())
  let b =
    sign_in(portal, browser.new(testing.trust_anchor_der(portal.provider)))

  // The web tier restarts: row and custody carry the session.
  let assert Ok(portal) = app.restart_portal(portal)
  let assert Ok(#(b, page)) = browser.get(b, portal.portal_url <> "/dashboard")
  assert page.status == 200

  // Hellhound restarts: a new client with empty processes. Custody lives in
  // Postgres, so the same browser session still works and nobody
  // signed in again.
  let assert Ok(portal) = app.restart_hellhound(portal)
  let assert Ok(#(b, page)) = browser.get(b, portal.portal_url <> "/dashboard")
  assert page.status == 200
  assert string.contains(page.body, "INV-1001")
  assert rows(portal) == 1
  assert testing.requests(portal.provider).code_grants == 1

  // The restarted Hellhound can still refresh and log out the session.
  billing_api.deny_accepted_tokens(portal.billing_api)
  let assert Ok(#(b, page)) = browser.get(b, portal.portal_url <> "/dashboard")
  assert page.status == 200
  assert testing.requests(portal.provider).refresh_grants == 1
  let assert Ok(#(b, _)) = browser.post(b, portal.portal_url <> "/logout")
  assert testing.requests(portal.provider).active_refresh_tokens == 0
  browser.close(b)
  app.stop(portal)
}

pub fn hellhound_records_hold_nothing_readable_test() {
  use portal, b <- with_app(options())
  let _ = sign_in(portal, b)
  let reference = custody_reference(portal)
  let assert Ok(session) =
    hellhound.restore_session(portal.hellhound, reference)
  let assert Ok(access) = hellhound.access_token(portal.hellhound, session)
  let assert Ok(pog.Returned(rows: sealed, ..)) =
    pog.query("select sealed from hellhound_records")
    |> pog.returning(decode.at([0], decode.bit_array))
    |> pog.execute(portal.db)
  // Custody and the pending login are in the table, sealed: neither the
  // token nor the reference nor the subject appears in any row.
  assert sealed != []
  let forbidden = [
    hellhound.access_token_value(access.token),
    reference,
    portal.options.subject,
  ]
  assert list.all(sealed, fn(row) {
    list.all(forbidden, fn(text) {
      !string.contains(
        bit_array.base16_encode(row),
        bit_array.base16_encode(<<text:utf8>>),
      )
    })
  })
}

pub fn the_postgres_store_passes_hellhound_conformance_test() {
  let assert Ok(db) = app.connect_database()
  let table = "hellhound_conformance_records"
  let assert Ok(Nil) = hellhound_records.migrate(db, table)
  assert testing.check_store(hellhound_records.new(db, table)) == Ok(Nil)
}

pub fn a_session_ended_elsewhere_sends_the_user_to_login_test() {
  use portal, b <- with_app(options())
  let b = sign_in(portal, b)
  let assert Ok(session) =
    hellhound.restore_session(portal.hellhound, custody_reference(portal))
  let assert Ok(_) =
    hellhound.logout(portal.hellhound, session, hellhound.default_logout())
  let assert Ok(#(_, page)) = browser.get(b, portal.portal_url <> "/dashboard")
  assert page.location == Some(portal.portal_url <> "/login")
  assert rows(portal) == 0
}

pub fn logout_with_a_stale_session_revision_ends_custody_test() {
  // Two requests hold the same session; one refreshes, the other logs out
  // with the revision it read before the refresh. Logout is by reference.
  use portal, b <- with_app(options())
  let _ = sign_in(portal, b)
  let reference = custody_reference(portal)
  let assert Ok(held) = hellhound.restore_session(portal.hellhound, reference)
  let assert Ok(_) = hellhound.refresh(portal.hellhound, held)
  let assert Ok(hellhound.LoggedOut(revocation: hellhound.Revoked, ..)) =
    hellhound.logout(portal.hellhound, held, hellhound.default_logout())
  // The session the user asked to end is gone from custody.
  let assert Error(hellhound.SessionNotFound) =
    hellhound.restore_session(portal.hellhound, reference)
  Nil
}

fn custody_reference(portal: App) -> String {
  let assert Ok(pog.Returned(rows: [reference], ..)) =
    pog.query(
      "select hellhound_reference from portal_sessions where subject = $1",
    )
    |> pog.parameter(pog.text(portal.options.subject))
    |> pog.returning(decode.at([0], decode.string))
    |> pog.execute(portal.db)
  reference
}

// The writer must actually wait on PostgreSQL's row lock before expiry.
pub fn guarded_write_waiting_on_a_row_lock_cannot_outlive_its_deadline_test() {
  let assert Ok(db) = app.connect_database()
  let table = "hellhound_deadline_records"
  let assert Ok(Nil) = hellhound_records.migrate(db, table)
  let records = hellhound_records.new(db, table)
  let original =
    store.Record(
      key: "queued",
      version: 1,
      expires_at: timestamp.add(timestamp.system_time(), duration.hours(1)),
      sealed: <<1, 2, 3>>,
    )
  let assert Ok(store.Written) = store.put(records, original, store.Absent)
  let assert Ok(Some(original)) = store.get(records, original.key)
  let replies = process.new_subject()
  let assert Ok(Nil) =
    pog.transaction(db, fn(connection) {
      let assert Ok(_) =
        pog.query(
          "select version from hellhound_deadline_records where key = 'queued' for update",
        )
        |> pog.execute(connection)
      let assert Ok(pog.Returned(rows: [deadline], ..)) =
        pog.query(
          "select (extract(epoch from clock_timestamp() + interval '2 seconds') * 1000000)::bigint",
        )
        |> pog.returning(decode.at([0], pog.timestamp_decoder()))
        |> pog.execute(connection)
      process.spawn(fn() {
        process.send(
          replies,
          store.put(
            records,
            store.Record(..original, version: 2, sealed: <<9>>),
            store.AtVersionBefore(1, deadline),
          ),
        )
      })
      let assert Ok(pog.Returned(rows: [holder], ..)) =
        pog.query("select pg_backend_pid()")
        |> pog.returning(decode.at([0], decode.int))
        |> pog.execute(connection)
      wait_for_guarded_writer(db, holder, 100)
      // Assert that the observed lock wait began while the guard was valid.
      let #(seconds, nanos) =
        timestamp.to_unix_seconds_and_nanoseconds(deadline)
      let assert Ok(pog.Returned(rows: [True], ..)) =
        pog.query(
          "select clock_timestamp() < to_timestamp($1::bigint / 1000000.0)",
        )
        |> pog.parameter(pog.int(seconds * 1_000_000 + nanos / 1000))
        |> pog.returning(decode.at([0], decode.bool))
        |> pog.execute(connection)
      let assert Ok(_) =
        pog.query("select 1 from pg_sleep(2.1)") |> pog.execute(connection)
      Ok(Nil)
    })
  assert process.receive(replies, 3000) == Ok(Ok(store.DeadlineElapsed))
  assert store.get(records, original.key) == Ok(Some(original))
}

fn wait_for_guarded_writer(
  db: pog.Connection,
  holder: Int,
  remaining: Int,
) -> Nil {
  let assert Ok(pog.Returned(rows: [waiting], ..)) =
    pog.query(
      "select exists (select 1 from pg_stat_activity where $1 = any(pg_blocking_pids(pid)))",
    )
    |> pog.parameter(pog.int(holder))
    |> pog.returning(decode.at([0], decode.bool))
    |> pog.execute(db)
  case waiting {
    True -> Nil
    False -> {
      assert remaining > 0
      process.sleep(10)
      wait_for_guarded_writer(db, holder, remaining - 1)
    }
  }
}

// A connection lost during COMMIT is not a confirmed storage refusal.
pub fn commit_connection_loss_preserves_unknown_outcome_test() {
  let assert Ok(db) = app.connect_database()
  let table = "hellhound_commit_loss_records"
  let assert Ok(Nil) = hellhound_records.migrate(db, table)
  let records = hellhound_records.new(db, table)
  let original =
    store.Record(
      key: "commit_loss",
      version: 1,
      expires_at: timestamp.add(timestamp.system_time(), duration.hours(1)),
      sealed: <<1, 2, 3>>,
    )
  let assert Ok(store.Written) = store.put(records, original, store.Absent)
  let assert Ok(Some(original)) = store.get(records, original.key)
  let assert Ok(_) =
    pog.query(
      "create function disconnect_custody_commit() returns trigger language plpgsql as $$ begin perform pg_terminate_backend(pg_backend_pid()); return new; end $$",
    )
    |> pog.execute(db)
  let assert Ok(_) =
    pog.query(
      "create constraint trigger disconnect_custody_commit after update on hellhound_commit_loss_records deferrable initially deferred for each row execute function disconnect_custody_commit()",
    )
    |> pog.execute(db)
  assert store.put(
      records,
      store.Record(..original, version: 2, sealed: <<9>>),
      store.AtVersionBefore(
        1,
        timestamp.add(timestamp.system_time(), duration.minutes(1)),
      ),
    )
    == Error(store.StoreOutcomeUnknown)
  // Independent subsequent evidence can settle this attempt; the failed
  // acknowledgement itself must not claim that knowledge.
  assert store.get(records, original.key) == Ok(Some(original))
}
