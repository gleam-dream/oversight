//// Access tokens for downstream calls, with transparent refresh.
////
//// This module is the app's glue around `warden.refresh_session`. Warden
//// guarantees at most one refresh per session generation, but it does not
//// say *when* a token should be refreshed and it does not let a second
//// caller join a refresh that is already running: the loser gets
//// `RefreshInProgress` (or `RefreshSessionStale` if the winner already
//// published) and must poll custody for the new revision itself.

import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/time/timestamp
import warden

pub type AccessError {
  /// The session cannot continue; sign in again.
  Reauthenticate(reason: String)
  /// A dependency is unavailable; the session is intact, retry later.
  TryLater(reason: String)
}

pub type Policy {
  Policy(
    /// Refresh when the token expires within this many seconds.
    expiry_margin_seconds: Int,
    /// How long a request waits for a refresh that another request runs.
    join_timeout_ms: Int,
  )
}

pub fn default_policy() -> Policy {
  Policy(expiry_margin_seconds: 30, join_timeout_ms: 5000)
}

/// A token that is not about to expire, refreshing first when needed.
pub fn usable_token(
  client: warden.Client,
  session: warden.Session,
  policy: Policy,
) -> Result(#(warden.Session, warden.AccessToken), AccessError) {
  case warden.session_access_token(client, session) {
    Ok(#(token, Some(expires_at))) ->
      case expires_at - now_seconds() > policy.expiry_margin_seconds {
        True -> Ok(#(session, token))
        False -> refreshed(client, session, policy)
      }
    Ok(#(token, None)) -> Ok(#(session, token))
    Error(warden.SessionStale) -> current(client, session, policy)
    Error(error) -> Error(session_error(error))
  }
}

/// Refresh now (for example after the resource server answered 401).
pub fn refreshed(
  client: warden.Client,
  session: warden.Session,
  policy: Policy,
) -> Result(#(warden.Session, warden.AccessToken), AccessError) {
  attempt(client, session, policy.join_timeout_ms)
}

fn attempt(
  client: warden.Client,
  session: warden.Session,
  remaining_ms: Int,
) -> Result(#(warden.Session, warden.AccessToken), AccessError) {
  case warden.refresh_session(client, session) {
    Ok(warden.RefreshCompleted(next)) -> token_of(client, next)
    Ok(warden.RefreshPublicationUnresolved(recovery)) ->
      case warden.recover_refresh_publication(client, recovery) {
        Ok(warden.RefreshCompleted(next)) -> token_of(client, next)
        _ -> Error(TryLater("refresh publication unresolved"))
      }
    Ok(warden.RefreshDidNotSend(_)) ->
      Error(TryLater("identity provider unreachable"))
    Ok(warden.RefreshRejectedByEndpoint(warden.InvalidGrant)) ->
      Error(Reauthenticate("refresh token revoked"))
    Ok(warden.RefreshRejectedByEndpoint(_)) ->
      Error(TryLater("refresh refused"))
    Ok(warden.RefreshProviderQuarantined(_))
    | Ok(warden.RefreshResponseQuarantined(_, _))
    | Ok(warden.RefreshReservationUnresolved(_)) ->
      Error(Reauthenticate("refresh outcome uncertain"))
    // Another request is refreshing this generation, or already did.
    Error(warden.RefreshInProgress) | Error(warden.RefreshSessionStale) ->
      join(client, session, remaining_ms)
    Error(warden.RefreshRevoked) -> Error(Reauthenticate("refresh revoked"))
    Error(warden.RefreshQuarantined) ->
      Error(Reauthenticate("refresh quarantined"))
    Error(warden.RefreshTokenUnavailable) ->
      Error(Reauthenticate("no refresh token"))
    Error(warden.RefreshSessionMissing) | Error(warden.RefreshSessionForeign) ->
      Error(Reauthenticate("session ended"))
    Error(warden.RefreshStoreUnavailable)
    | Error(warden.RefreshPublicationRejected)
    | Error(warden.RecoveryForeign) -> Error(TryLater("session store"))
  }
}

/// Wait for the concurrent refresh to publish a newer revision. If it ends
/// without one (it was not sent, or was rejected), try the refresh again so
/// that its outcome reaches this caller too.
fn join(
  client: warden.Client,
  session: warden.Session,
  remaining_ms: Int,
) -> Result(#(warden.Session, warden.AccessToken), AccessError) {
  case warden.restore_session(client, warden.session_reference(session)) {
    Ok(latest) ->
      case warden.session_revision(latest) > warden.session_revision(session) {
        True -> token_of(client, latest)
        False ->
          case remaining_ms <= 0 {
            True -> Error(TryLater("concurrent refresh did not finish"))
            False -> {
              process.sleep(20)
              attempt(client, session, remaining_ms - 20)
            }
          }
      }
    Error(error) -> Error(session_error(error))
  }
}

fn current(
  client: warden.Client,
  session: warden.Session,
  policy: Policy,
) -> Result(#(warden.Session, warden.AccessToken), AccessError) {
  case warden.restore_session(client, warden.session_reference(session)) {
    Ok(latest) -> usable_token(client, latest, policy)
    Error(error) -> Error(session_error(error))
  }
}

fn token_of(
  client: warden.Client,
  session: warden.Session,
) -> Result(#(warden.Session, warden.AccessToken), AccessError) {
  case warden.session_access_token(client, session) {
    Ok(#(token, _)) -> Ok(#(session, token))
    Error(error) -> Error(session_error(error))
  }
}

fn session_error(error: warden.SessionError) -> AccessError {
  case error {
    warden.SessionStoreUnavailable -> TryLater("session store")
    warden.SessionNotFound
    | warden.SessionForeign
    | warden.SessionStale
    | warden.SessionHasNoAccessToken -> Reauthenticate("session ended")
  }
}

fn now_seconds() -> Int {
  let #(seconds, _) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  seconds
}
