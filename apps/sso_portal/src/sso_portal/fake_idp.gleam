//// A minimal scripted OpenID provider on loopback, written for this app.
////
//// Warden ships a scripted provider only as test-private Erlang
//// (`warden/test/warden_test_provider.erl`, erlang-jose), so a consumer has
//// to write its own. This one serves discovery, JWKS, an auto-approving
//// authorization endpoint, the token endpoint (authorization code with S256
//// PKCE, rotating refresh tokens), userinfo and an end-session endpoint over
//// TLS. ID tokens are signed ES256 with gose. The token state doubles as the
//// billing API's token authority (`check_access`).

import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/time/timestamp
import gleam/uri
import gose
import gose/jose/jwk
import gose/jose/jwt
import kryptos/ec
import sso_portal/pki.{type Pki}
import sso_portal/server.{type Server}
import wisp.{type Request, type Response}

pub type Settings {
  Settings(
    client_id: String,
    client_secret: String,
    subject: String,
    email: String,
    /// Lifetime of issued access tokens.
    access_ttl_seconds: Int,
    /// Added to `iat` of issued ID tokens: a provider clock running ahead.
    iat_skew_seconds: Int,
    /// Delay before answering a refresh grant (to widen refresh races).
    refresh_delay_ms: Int,
  )
}

pub fn default_settings() -> Settings {
  Settings(
    client_id: "portal",
    client_secret: "portal-secret",
    subject: "user-42",
    email: "ada@example.com",
    access_ttl_seconds: 300,
    iat_skew_seconds: 0,
    refresh_delay_ms: 0,
  )
}

pub opaque type Idp {
  Idp(issuer: String, server: Server, state: Subject(Message), pki: Pki)
}

pub type Stats {
  Stats(
    code_grants: Int,
    refresh_grants: Int,
    rejected_refresh_grants: Int,
    end_session_visits: Int,
    active_refresh_tokens: Int,
  )
}

type Grant {
  Grant(nonce: String, challenge: String, redirect_uri: String, auth_time: Int)
}

type RefreshStatus {
  Active
  Rotated
  Revoked
}

type RefreshEntry {
  RefreshEntry(subject: String, status: RefreshStatus)
}

type AccessEntry {
  AccessEntry(subject: String, expires_at: Int, revoked: Bool)
}

type Issued {
  Issued(access: String, refresh: String, expires_in: Int)
}

type State {
  State(
    issuer: String,
    settings: Settings,
    codes: Dict(String, Grant),
    refresh: Dict(String, RefreshEntry),
    access: Dict(String, AccessEntry),
    stats: Stats,
  )
}

type Message {
  SetIssuer(issuer: String)
  GetIssuer(reply: Subject(String))
  GetSettings(reply: Subject(Settings))
  UpdateSettings(update: fn(Settings) -> Settings)
  StoreCode(code: String, grant: Grant)
  TakeCode(code: String, reply: Subject(Result(Grant, Nil)))
  IssueTokens(reply: Subject(Issued))
  RotateRefresh(token: String, reply: Subject(Result(Issued, Nil)))
  CheckAccess(token: String, reply: Subject(Result(String, Nil)))
  RevokeRefreshTokens
  RevokeAccessTokens
  EndSession
  GetStats(reply: Subject(Stats))
}

// ---------------------------------------------------------------------------
// Lifecycle and test controls

pub fn start(settings: Settings, pki: Pki) -> Result(Idp, String) {
  let signing =
    gose.generate_ec(ec.P256)
    |> gose.with_alg(gose.SigningAlg(es256()))
    |> gose.with_kid("idp-key-1")
  use started <- result.try(
    actor.new(State(
      issuer: "",
      settings:,
      codes: dict.new(),
      refresh: dict.new(),
      access: dict.new(),
      stats: Stats(0, 0, 0, 0, 0),
    ))
    |> actor.on_message(handle_message)
    |> actor.start
    |> result.replace_error("idp state did not start"),
  )
  let state = started.data
  // The issuer includes the port, which is known only after binding, so the
  // handler reads it from the state actor, which learns it right after start.
  use server <- result.try(server.start(
    fn(request) {
      handle(request, actor.call(state, 1000, GetIssuer), state, signing)
    },
    wisp.random_string(64),
    Some(server.Tls(certfile: pki.certfile, keyfile: pki.keyfile)),
  ))
  let issuer = "https://localhost:" <> int.to_string(server.port)
  process.send(state, SetIssuer(issuer))
  Ok(Idp(issuer:, server:, state:, pki:))
}

pub fn stop(idp: Idp) -> Nil {
  server.stop(idp.server)
}

pub fn issuer(idp: Idp) -> String {
  idp.issuer
}

pub fn pki(idp: Idp) -> Pki {
  idp.pki
}

pub fn settings(idp: Idp) -> Settings {
  actor.call(idp.state, 1000, GetSettings)
}

pub fn update_settings(idp: Idp, update: fn(Settings) -> Settings) -> Nil {
  process.send(idp.state, UpdateSettings(update))
}

/// The resource-server view: is this access token live, and for whom?
pub fn check_access(idp: Idp, token: String) -> Result(String, Nil) {
  actor.call(idp.state, 1000, CheckAccess(token, _))
}

/// Revoke every refresh token (an administrator ended the grant).
pub fn revoke_refresh_tokens(idp: Idp) -> Nil {
  process.send(idp.state, RevokeRefreshTokens)
}

/// Revoke every access token before its expiry (the API will answer 401).
pub fn revoke_access_tokens(idp: Idp) -> Nil {
  process.send(idp.state, RevokeAccessTokens)
}

pub fn stats(idp: Idp) -> Stats {
  actor.call(idp.state, 1000, GetStats)
}

// ---------------------------------------------------------------------------
// State

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  let stats = state.stats
  case message {
    SetIssuer(issuer) -> actor.continue(State(..state, issuer:))
    GetIssuer(reply) -> {
      process.send(reply, state.issuer)
      actor.continue(state)
    }
    GetSettings(reply) -> {
      process.send(reply, state.settings)
      actor.continue(state)
    }
    UpdateSettings(update) ->
      actor.continue(State(..state, settings: update(state.settings)))
    StoreCode(code, grant) ->
      actor.continue(
        State(..state, codes: dict.insert(state.codes, code, grant)),
      )
    TakeCode(code, reply) -> {
      process.send(reply, dict.get(state.codes, code))
      actor.continue(
        State(
          ..state,
          codes: dict.delete(state.codes, code),
          stats: Stats(..stats, code_grants: stats.code_grants + 1),
        ),
      )
    }
    IssueTokens(reply) -> {
      let #(state, issued) = issue(state)
      process.send(reply, issued)
      actor.continue(state)
    }
    RotateRefresh(token, reply) ->
      case dict.get(state.refresh, token) {
        Ok(RefreshEntry(subject:, status: Active)) -> {
          let state =
            State(
              ..state,
              refresh: dict.insert(
                state.refresh,
                token,
                RefreshEntry(subject:, status: Rotated),
              ),
              stats: Stats(..stats, refresh_grants: stats.refresh_grants + 1),
            )
          let #(state, issued) = issue(state)
          process.send(reply, Ok(issued))
          actor.continue(state)
        }
        _ -> {
          process.send(reply, Error(Nil))
          actor.continue(
            State(
              ..state,
              stats: Stats(
                ..stats,
                rejected_refresh_grants: stats.rejected_refresh_grants + 1,
              ),
            ),
          )
        }
      }
    CheckAccess(token, reply) -> {
      let now = now_seconds()
      process.send(reply, case dict.get(state.access, token) {
        Ok(AccessEntry(subject:, expires_at:, revoked: False))
          if expires_at > now
        -> Ok(subject)
        _ -> Error(Nil)
      })
      actor.continue(state)
    }
    RevokeRefreshTokens ->
      actor.continue(
        State(
          ..state,
          refresh: dict.map_values(state.refresh, fn(_, entry) {
            RefreshEntry(..entry, status: Revoked)
          }),
        ),
      )
    RevokeAccessTokens ->
      actor.continue(
        State(
          ..state,
          access: dict.map_values(state.access, fn(_, entry) {
            AccessEntry(..entry, revoked: True)
          }),
        ),
      )
    EndSession ->
      actor.continue(
        State(
          ..state,
          stats: Stats(
            ..stats,
            end_session_visits: stats.end_session_visits + 1,
          ),
        ),
      )
    GetStats(reply) -> {
      let active =
        dict.values(state.refresh)
        |> list.count(fn(entry) { entry.status == Active })
      process.send(reply, Stats(..stats, active_refresh_tokens: active))
      actor.continue(state)
    }
  }
}

fn issue(state: State) -> #(State, Issued) {
  let access = token(24)
  let refresh = token(24)
  let ttl = state.settings.access_ttl_seconds
  let subject = state.settings.subject
  let state =
    State(
      ..state,
      access: dict.insert(
        state.access,
        access,
        AccessEntry(subject:, expires_at: now_seconds() + ttl, revoked: False),
      ),
      refresh: dict.insert(
        state.refresh,
        refresh,
        RefreshEntry(subject:, status: Active),
      ),
    )
  #(state, Issued(access:, refresh:, expires_in: ttl))
}

// ---------------------------------------------------------------------------
// HTTP

fn handle(
  request: Request,
  issuer: String,
  state: Subject(Message),
  signing: gose.Key(String),
) -> Response {
  case request.method, wisp.path_segments(request) {
    http.Get, [".well-known", "openid-configuration"] -> discovery(issuer)
    http.Get, ["jwks"] -> jwks(signing)
    http.Get, ["authorize"] -> authorize(request, issuer, state)
    http.Post, ["token"] -> token_endpoint(request, issuer, state, signing)
    http.Get, ["userinfo"] -> userinfo(request, state)
    http.Get, ["logout"] -> {
      process.send(state, EndSession)
      wisp.html_response("<p>Signed out at the provider.</p>", 200)
    }
    _, _ -> wisp.not_found()
  }
}

fn discovery(issuer: String) -> Response {
  json.object([
    #("issuer", json.string(issuer)),
    #("authorization_endpoint", json.string(issuer <> "/authorize")),
    #("token_endpoint", json.string(issuer <> "/token")),
    #("userinfo_endpoint", json.string(issuer <> "/userinfo")),
    #("end_session_endpoint", json.string(issuer <> "/logout")),
    #("jwks_uri", json.string(issuer <> "/jwks")),
    #("response_types_supported", json.array(["code"], json.string)),
    #("response_modes_supported", json.array(["query"], json.string)),
    #(
      "grant_types_supported",
      json.array(["authorization_code", "refresh_token"], json.string),
    ),
    #("subject_types_supported", json.array(["public"], json.string)),
    #("scopes_supported", json.array(["openid", "email"], json.string)),
    #(
      "id_token_signing_alg_values_supported",
      json.array(["ES256"], json.string),
    ),
    #("code_challenge_methods_supported", json.array(["S256"], json.string)),
    #(
      "token_endpoint_auth_methods_supported",
      json.array(["client_secret_basic"], json.string),
    ),
    #("authorization_response_iss_parameter_supported", json.bool(True)),
  ])
  |> json.to_string
  |> wisp.json_response(200)
}

fn jwks(signing: gose.Key(String)) -> Response {
  let assert Ok(public) = gose.public_key(signing)
  json.object([#("keys", json.preprocessed_array([jwk.to_json(public)]))])
  |> json.to_string
  |> wisp.json_response(200)
}

fn authorize(
  request: Request,
  issuer: String,
  state: Subject(Message),
) -> Response {
  let query = wisp.get_query(request)
  let param = fn(name) { list.key_find(query, name) }
  let settings = actor.call(state, 1000, GetSettings)
  case
    param("client_id"),
    param("redirect_uri"),
    param("state"),
    param("nonce"),
    param("code_challenge"),
    param("code_challenge_method")
  {
    Ok(client_id),
      Ok(redirect_uri),
      Ok(st),
      Ok(nonce),
      Ok(challenge),
      Ok("S256")
      if client_id == settings.client_id
    -> {
      let code = token(16)
      process.send(
        state,
        StoreCode(
          code,
          Grant(nonce:, challenge:, redirect_uri:, auth_time: now_seconds()),
        ),
      )
      let callback =
        uri.query_to_string([#("code", code), #("state", st), #("iss", issuer)])
      wisp.redirect(redirect_uri <> "?" <> callback)
    }
    _, _, _, _, _, _ -> wisp.bad_request("invalid authorization request")
  }
}

fn token_endpoint(
  request: Request,
  issuer: String,
  state: Subject(Message),
  signing: gose.Key(String),
) -> Response {
  use form <- wisp.require_form(request)
  let settings = actor.call(state, 1000, GetSettings)
  let field = fn(name) { list.key_find(form.values, name) }
  case client_authenticated(request, settings) {
    False -> oauth_error(401, "invalid_client")
    True ->
      case field("grant_type") {
        Ok("authorization_code") ->
          case field("code"), field("code_verifier"), field("redirect_uri") {
            Ok(code), Ok(verifier), Ok(redirect_uri) -> {
              let challenge = pkce_challenge(verifier)
              case actor.call(state, 1000, TakeCode(code, _)) {
                Ok(grant)
                  if grant.redirect_uri == redirect_uri
                  && grant.challenge == challenge
                -> {
                  let issued = actor.call(state, 1000, IssueTokens)
                  let id_token = id_token(issuer, settings, grant, signing)
                  token_response(issued, Some(id_token))
                }
                _ -> oauth_error(400, "invalid_grant")
              }
            }
            _, _, _ -> oauth_error(400, "invalid_request")
          }
        Ok("refresh_token") ->
          case field("refresh_token") {
            Ok(refresh) -> {
              process.sleep(settings.refresh_delay_ms)
              case actor.call(state, 1000, RotateRefresh(refresh, _)) {
                // OIDC Core 12.2: the refresh response may omit the ID token.
                Ok(issued) -> token_response(issued, None)
                Error(Nil) -> oauth_error(400, "invalid_grant")
              }
            }
            Error(Nil) -> oauth_error(400, "invalid_request")
          }
        _ -> oauth_error(400, "unsupported_grant_type")
      }
  }
}

fn userinfo(request: Request, state: Subject(Message)) -> Response {
  let settings = actor.call(state, 1000, GetSettings)
  case bearer(request) {
    Ok(token) ->
      case actor.call(state, 1000, CheckAccess(token, _)) {
        Ok(subject) ->
          json.object([
            #("sub", json.string(subject)),
            #("email", json.string(settings.email)),
          ])
          |> json.to_string
          |> wisp.json_response(200)
        Error(Nil) -> wisp.response(401)
      }
    Error(Nil) -> wisp.response(401)
  }
}

fn id_token(
  issuer: String,
  settings: Settings,
  grant: Grant,
  signing: gose.Key(String),
) -> String {
  let now = now_seconds()
  let claims =
    jwt.claims()
    |> jwt.with_issuer(issuer)
    |> jwt.with_subject(settings.subject)
    |> jwt.with_audience(settings.client_id)
    |> jwt.with_issued_at(timestamp.from_unix_seconds(
      now + settings.iat_skew_seconds,
    ))
    |> jwt.with_expiration(timestamp.from_unix_seconds(now + 600))
  let assert Ok(claims) =
    jwt.with_claim(claims, key: "nonce", value: json.string(grant.nonce))
  let assert Ok(claims) =
    jwt.with_claim(claims, key: "auth_time", value: json.int(grant.auth_time))
  let assert Ok(claims) =
    jwt.with_claim(claims, key: "email", value: json.string(settings.email))
  let assert Ok(signed) = jwt.sign(es256(), claims, signing)
  jwt.serialize(signed)
}

fn token_response(issued: Issued, id_token: Option(String)) -> Response {
  let fields = [
    #("access_token", json.string(issued.access)),
    #("token_type", json.string("Bearer")),
    #("expires_in", json.int(issued.expires_in)),
    #("refresh_token", json.string(issued.refresh)),
    #("scope", json.string("openid email")),
  ]
  let fields = case id_token {
    Some(value) -> [#("id_token", json.string(value)), ..fields]
    None -> fields
  }
  json.object(fields) |> json.to_string |> wisp.json_response(200)
}

fn oauth_error(status: Int, code: String) -> Response {
  json.object([#("error", json.string(code))])
  |> json.to_string
  |> wisp.json_response(status)
}

fn client_authenticated(request: Request, settings: Settings) -> Bool {
  let expected =
    bit_array.base64_encode(
      <<{ settings.client_id <> ":" <> settings.client_secret }:utf8>>,
      True,
    )
  request.get_header(request, "authorization") == Ok("Basic " <> expected)
}

fn bearer(request: Request) -> Result(String, Nil) {
  case request.get_header(request, "authorization") {
    Ok("Bearer " <> token) -> Ok(token)
    _ -> Error(Nil)
  }
}

fn pkce_challenge(verifier: String) -> String {
  crypto.hash(crypto.Sha256, <<verifier:utf8>>)
  |> bit_array.base64_url_encode(False)
}

fn es256() -> gose.SigningAlg {
  gose.DigitalSignature(gose.Ecdsa(gose.EcdsaP256))
}

fn token(bytes: Int) -> String {
  crypto.strong_random_bytes(bytes) |> bit_array.base64_url_encode(False)
}

fn now_seconds() -> Int {
  let #(seconds, _) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  seconds
}
