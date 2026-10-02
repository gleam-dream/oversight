//// A scripted OpenID provider on loopback HTTPS, small enough to read.
////
//// Warden's own scripted provider is Erlang under `warden/test` and cannot be
//// imported, so the app carries this one. It serves discovery, JWKS, an
//// auto-approving authorization endpoint (the user is `login_hint`, default
//// `alice`), the token endpoint with PKCE S256, and RFC 7662 introspection.
//// Access tokens are opaque; their audience is the RFC 8707 `resource`
//// parameter of the authorization request.

import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/http.{Get, Post}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/uri
import mist

pub type Grant {
  Grant(
    subject: String,
    audience: String,
    scopes: List(String),
    expires_at: Int,
    client_id: String,
    revoked: Bool,
  )
}

type Pending {
  Pending(
    subject: String,
    nonce: String,
    challenge: String,
    redirect_uri: String,
    resource: String,
    scope: String,
  )
}

type Message {
  PutCode(String, Pending)
  TakeCode(String, Subject(Result(Pending, Nil)))
  PutToken(String, Grant)
  GetToken(String, Subject(Result(Grant, Nil)))
  Revoke(String)
}

type State {
  State(codes: Dict(String, Pending), tokens: Dict(String, Grant))
}

pub opaque type Provider {
  Provider(
    store: Subject(Message),
    issuer: String,
    ca_pem: String,
    listener: process.Pid,
  )
}

pub type Client {
  Client(id: String, secret: String, redirect_uri: String)
}

type Key

@external(erlang, "secure_mcp_dev_ffi", "generate_rsa")
fn generate_rsa() -> Key

@external(erlang, "secure_mcp_dev_ffi", "public_jwk")
fn public_jwk(key: Key, kid: String) -> String

@external(erlang, "secure_mcp_dev_ffi", "sign_rs256")
fn sign_rs256(key: Key, message: BitArray) -> BitArray

@external(erlang, "secure_mcp_dev_ffi", "generate_tls")
fn generate_tls(dir: String) -> String

@external(erlang, "secure_mcp_dev_ffi", "free_port")
pub fn free_port() -> Int

@external(erlang, "secure_mcp_dev_ffi", "now_seconds")
pub fn now_seconds() -> Int

@external(erlang, "secure_mcp_dev_ffi", "unique")
fn unique() -> Int

const kid = "dev-key-1"

/// Starts the provider on `https://localhost:<port>` for one registered client.
pub fn start(client: Client, tls_dir: String) -> Result(Provider, String) {
  let ca_pem = generate_tls(tls_dir)
  let key = generate_rsa()
  let port = free_port()
  let issuer = "https://localhost:" <> int.to_string(port)
  use store <- result.try(
    actor.new(State(dict.new(), dict.new()))
    |> actor.on_message(handle_store)
    |> actor.start
    |> result.map(fn(started) { started.data })
    |> result.replace_error("provider store failed to start"),
  )
  let handler = fn(req) { route(req, store, issuer, key, client) }
  use started <- result.try(
    mist.new(handler)
    |> mist.bind("127.0.0.1")
    |> mist.port(port)
    |> mist.with_tls(
      certfile: tls_dir <> "/cert.pem",
      keyfile: tls_dir <> "/key.pem",
    )
    |> mist.start
    |> result.map_error(fn(e) { "provider listener: " <> string.inspect(e) }),
  )
  Ok(Provider(store:, issuer:, ca_pem:, listener: started.pid))
}

pub fn stop(provider: Provider) -> Nil {
  shutdown(provider.listener)
}

pub fn issuer(provider: Provider) -> String {
  provider.issuer
}

/// The CA certificate (PEM) that signed the provider's TLS certificate.
pub fn ca_pem(provider: Provider) -> String {
  provider.ca_pem
}

/// Issues an access token outside a browser login, as the provider would for
/// another client. `ttl_seconds` may be negative to model an expired token.
pub fn mint(
  provider: Provider,
  subject subject: String,
  audience audience: String,
  scopes scopes: List(String),
  ttl_seconds ttl: Int,
) -> String {
  let token = random_token()
  process.send(
    provider.store,
    PutToken(
      token,
      Grant(
        subject,
        audience,
        scopes,
        now_seconds() + ttl,
        "other-client",
        False,
      ),
    ),
  )
  token
}

/// Revokes an access token; introspection then reports it inactive.
pub fn revoke(provider: Provider, token: String) -> Nil {
  process.send(provider.store, Revoke(token))
  // Round-trip so the revocation is applied before the caller continues.
  let _ = lookup(provider.store, token)
  Nil
}

fn handle_store(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    PutCode(code, pending) ->
      actor.continue(
        State(..state, codes: dict.insert(state.codes, code, pending)),
      )
    TakeCode(code, reply) -> {
      process.send(reply, dict.get(state.codes, code))
      actor.continue(State(..state, codes: dict.delete(state.codes, code)))
    }
    PutToken(token, grant) ->
      actor.continue(
        State(..state, tokens: dict.insert(state.tokens, token, grant)),
      )
    GetToken(token, reply) -> {
      process.send(reply, dict.get(state.tokens, token))
      actor.continue(state)
    }
    Revoke(token) ->
      actor.continue(
        State(
          ..state,
          tokens: dict.upsert(state.tokens, token, fn(existing) {
            case existing {
              Some(grant) -> Grant(..grant, revoked: True)
              None -> Grant("", "", [], 0, "", True)
            }
          }),
        ),
      )
  }
}

fn lookup(store: Subject(Message), token: String) -> Result(Grant, Nil) {
  process.call(store, 1000, GetToken(token, _))
}

// --- HTTP --------------------------------------------------------------------

fn route(
  req: Request(mist.Connection),
  store: Subject(Message),
  issuer: String,
  key: Key,
  client: Client,
) -> Response(mist.ResponseData) {
  case req.method, req.path {
    Get, "/.well-known/openid-configuration" -> discovery(issuer)
    Get, "/jwks" -> respond(200, "{\"keys\":[" <> public_jwk(key, kid) <> "]}")
    Get, "/authorize" -> authorize(req, store, issuer, client)
    Post, "/token" ->
      with_client(req, client, fn(form) {
        token(form, store, issuer, key, client)
      })
    Post, "/introspect" ->
      with_client(req, client, fn(form) { introspect(form, store, issuer) })
    _, _ -> respond(404, "{\"error\":\"not_found\"}")
  }
}

fn discovery(issuer: String) -> Response(mist.ResponseData) {
  let strings = fn(values) { json.array(values, json.string) }
  json.object([
    #("issuer", json.string(issuer)),
    #("authorization_endpoint", json.string(issuer <> "/authorize")),
    #("token_endpoint", json.string(issuer <> "/token")),
    #("introspection_endpoint", json.string(issuer <> "/introspect")),
    #("jwks_uri", json.string(issuer <> "/jwks")),
    #("response_types_supported", strings(["code"])),
    #("response_modes_supported", strings(["query"])),
    #("grant_types_supported", strings(["authorization_code"])),
    #("subject_types_supported", strings(["public"])),
    #("scopes_supported", strings(["openid", "reports"])),
    #("id_token_signing_alg_values_supported", strings(["RS256"])),
    #("code_challenge_methods_supported", strings(["S256"])),
    #("token_endpoint_auth_methods_supported", strings(["client_secret_basic"])),
    #("authorization_response_iss_parameter_supported", json.bool(True)),
  ])
  |> json.to_string
  |> respond(200, _)
}

fn authorize(
  req: Request(mist.Connection),
  store: Subject(Message),
  issuer: String,
  client: Client,
) -> Response(mist.ResponseData) {
  let query = request.get_query(req) |> result.unwrap([])
  let param = fn(name) { list.key_find(query, name) |> result.unwrap("") }
  case
    param("client_id") == client.id
    && param("redirect_uri") == client.redirect_uri
    && param("code_challenge_method") == "S256"
  {
    False -> respond(400, "{\"error\":\"invalid_request\"}")
    True -> {
      let code = random_token()
      let subject = case param("login_hint") {
        "" -> "alice"
        hint -> hint
      }
      process.send(
        store,
        PutCode(
          code,
          Pending(
            subject:,
            nonce: param("nonce"),
            challenge: param("code_challenge"),
            redirect_uri: param("redirect_uri"),
            resource: param("resource"),
            scope: param("scope"),
          ),
        ),
      )
      let location =
        client.redirect_uri
        <> "?"
        <> uri.query_to_string([
          #("code", code),
          #("state", param("state")),
          #("iss", issuer),
        ])
      response.new(302)
      |> response.set_header("location", location)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
    }
  }
}

fn token(
  form: List(#(String, String)),
  store: Subject(Message),
  issuer: String,
  key: Key,
  client: Client,
) -> Response(mist.ResponseData) {
  let param = fn(name) { list.key_find(form, name) |> result.unwrap("") }
  let taken = process.call(store, 1000, TakeCode(param("code"), _))
  case param("grant_type"), taken {
    "authorization_code", Ok(pending) -> {
      let verifier_ok =
        bit_array.base64_url_encode(
          crypto.hash(crypto.Sha256, <<param("code_verifier"):utf8>>),
          False,
        )
        == pending.challenge
      case verifier_ok && param("redirect_uri") == pending.redirect_uri {
        False -> respond(400, "{\"error\":\"invalid_grant\"}")
        True -> {
          let now = now_seconds()
          let access = random_token()
          let scopes =
            string.split(pending.scope, " ") |> list.filter(fn(s) { s != "" })
          process.send(
            store,
            PutToken(
              access,
              Grant(
                pending.subject,
                pending.resource,
                scopes,
                now + 300,
                client.id,
                False,
              ),
            ),
          )
          let id_token =
            sign_jwt(key, [
              #("iss", json.string(issuer)),
              #("sub", json.string(pending.subject)),
              #("aud", json.string(client.id)),
              #("exp", json.int(now + 300)),
              #("iat", json.int(now)),
              #("auth_time", json.int(now)),
              #("nonce", json.string(pending.nonce)),
              #("name", json.string(string.capitalise(pending.subject))),
            ])
          json.object([
            #("access_token", json.string(access)),
            #("token_type", json.string("Bearer")),
            #("expires_in", json.int(300)),
            #("id_token", json.string(id_token)),
            #("scope", json.string(pending.scope)),
          ])
          |> json.to_string
          |> respond(200, _)
        }
      }
    }
    _, _ -> respond(400, "{\"error\":\"invalid_grant\"}")
  }
}

fn introspect(
  form: List(#(String, String)),
  store: Subject(Message),
  issuer: String,
) -> Response(mist.ResponseData) {
  let token = list.key_find(form, "token") |> result.unwrap("")
  case lookup(store, token) {
    Ok(grant) if !grant.revoked -> {
      case grant.expires_at > now_seconds() {
        False -> respond(200, "{\"active\":false}")
        True ->
          json.object([
            #("active", json.bool(True)),
            #("sub", json.string(grant.subject)),
            #("username", json.string(grant.subject)),
            #("aud", json.string(grant.audience)),
            #("scope", json.string(string.join(grant.scopes, " "))),
            #("exp", json.int(grant.expires_at)),
            #("client_id", json.string(grant.client_id)),
            #("token_type", json.string("Bearer")),
            #("iss", json.string(issuer)),
          ])
          |> json.to_string
          |> respond(200, _)
      }
    }
    _ -> respond(200, "{\"active\":false}")
  }
}

/// Reads the form body after checking HTTP Basic client authentication.
fn with_client(
  req: Request(mist.Connection),
  client: Client,
  next: fn(List(#(String, String))) -> Response(mist.ResponseData),
) -> Response(mist.ResponseData) {
  let expected =
    "Basic "
    <> bit_array.base64_encode(
      <<client.id:utf8, ":", client.secret:utf8>>,
      True,
    )
  let body =
    mist.read_body(req, 65_536)
    |> result.replace_error(Nil)
    |> result.try(fn(r) { bit_array.to_string(r.body) })
    |> result.try(uri.parse_query)
  case request.get_header(req, "authorization"), body {
    Ok(header), Ok(form) if header == expected -> next(form)
    _, _ -> respond(401, "{\"error\":\"invalid_client\"}")
  }
}

fn sign_jwt(key: Key, claims: List(#(String, json.Json))) -> String {
  let header =
    json.object([
      #("alg", json.string("RS256")),
      #("kid", json.string(kid)),
      #("typ", json.string("JWT")),
    ])
  let encode = fn(j) {
    bit_array.base64_url_encode(<<json.to_string(j):utf8>>, False)
  }
  let input = encode(header) <> "." <> encode(json.object(claims))
  input
  <> "."
  <> bit_array.base64_url_encode(sign_rs256(key, <<input:utf8>>), False)
}

fn respond(status: Int, body: String) -> Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_header("cache-control", "no-store")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn random_token() -> String {
  crypto.strong_random_bytes(24)
  |> bit_array.base64_url_encode(False)
  |> string.append(int.to_string(unique()))
}

@external(erlang, "secure_mcp_dev_ffi", "shutdown")
fn shutdown(pid: process.Pid) -> Nil
