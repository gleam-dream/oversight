//// Resource-server authorization for `/mcp`: bearer extraction, a Relay
//// verifier backed by Warden introspection, and RFC 6750 / RFC 9728
//// challenges. Relay owns admission (`authorization.admit`: audience and
//// endpoint scope); Warden owns the provider call; this module translates.

import gleam/dynamic/decode
import gleam/http/request
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import relay/authorization.{
  type GrantedRequest, type ProtectionConfig, type VerifierAttestation,
}
import warden
import wisp

/// The authenticated caller that tool handlers act for.
pub type Principal {
  Principal(subject: String, client_id: Option(String), scopes: List(String))
}

pub type AuthFailure {
  /// No `Authorization: Bearer` header (RFC 6750 §3.1: no error code).
  NoToken
  /// Inactive, expired, revoked, malformed or unknown token.
  InvalidToken(description: String)
  /// Active token issued for another resource.
  WrongAudience
  InsufficientScope(scope: String)
  /// The provider could not be asked.
  AuthorizationUnavailable
}

/// Authenticates one HTTP request and admits it for the protected resource.
pub fn authenticate(
  req: wisp.Request,
  client: warden.Client,
  protection: ProtectionConfig,
  now: Int,
) -> Result(GrantedRequest(Principal), AuthFailure) {
  use raw <- result.try(bearer(req))
  use token <- result.try(
    authorization.bearer_token(raw)
    |> result.replace_error(InvalidToken("empty bearer token")),
  )
  // GLUE (SMCP-3): `BearerToken` is opaque with no accessor, so a verifier
  // closure cannot read the token it is given. The verifier is rebuilt per
  // request around the raw string instead of once at startup.
  let verifier =
    authorization.verifier("warden-introspection", "1", fn(_opaque) {
      verify(client, raw, now)
    })
  authorization.admit(verifier, token, protection)
  |> result.map_error(fn(error) {
    case error {
      authorization.VerificationFailed(authorization.BearerRejected) ->
        InvalidToken("the access token is not active")
      authorization.VerificationFailed(authorization.VerifierUnmapped) ->
        InvalidToken("the access token could not be interpreted")
      authorization.VerificationFailed(authorization.VerifierUnavailable) ->
        AuthorizationUnavailable
      authorization.ResourceNotGranted -> WrongAudience
      authorization.MissingEndpointScope(scope) ->
        InsufficientScope(scope_name(scope))
    }
  })
}

fn bearer(req: wisp.Request) -> Result(String, AuthFailure) {
  case request.get_header(req, "authorization") {
    Error(Nil) -> Error(NoToken)
    Ok(value) ->
      case string.split_once(value, " ") {
        Ok(#(scheme, token)) ->
          case string.lowercase(scheme) {
            "bearer" -> Ok(string.trim(token))
            _ -> Error(NoToken)
          }
        Error(Nil) -> Error(NoToken)
      }
  }
}

/// The verifier body: Warden introspection mapped to a Relay attestation.
fn verify(
  client: warden.Client,
  raw: String,
  now: Int,
) -> Result(VerifierAttestation(Principal), authorization.VerificationError) {
  case warden.introspect(client, raw) {
    Ok(warden.InactiveToken) -> Error(authorization.BearerRejected)
    Error(warden.IntrospectionNotSupported) ->
      Error(authorization.VerifierUnmapped)
    Error(warden.IntrospectionFailed(_)) ->
      Error(authorization.VerifierUnavailable)
    Ok(warden.ActiveToken(info)) ->
      // GLUE (SMCP-4): Warden reports an active token without checking `exp`
      // and `TokenInfo` has no audience; both are dug out here.
      case info.expires_at {
        option.Some(exp) if exp <= now -> Error(authorization.BearerRejected)
        _ -> {
          let audiences =
            decode.run(info.claims, audience_decoder())
            |> result.unwrap([])
            |> list.filter_map(authorization.resource)
          let scopes = list.filter_map(info.scopes, authorization.scope)
          case info.subject {
            option.None -> Error(authorization.VerifierUnmapped)
            option.Some(subject) ->
              Ok(authorization.attestation(
                Principal(
                  subject:,
                  client_id: info.client_id,
                  scopes: info.scopes,
                ),
                audiences,
                scopes,
              ))
          }
        }
      }
  }
}

fn audience_decoder() -> decode.Decoder(List(String)) {
  let one_or_many =
    decode.one_of(decode.string |> decode.map(fn(a) { [a] }), [
      decode.list(decode.string),
    ])
  use audiences <- decode.optional_field("aud", [], one_or_many)
  decode.success(audiences)
}

// GLUE (SMCP-3): `Scope` is opaque without an accessor, so the scope name for
// the challenge is recovered by comparison with the known endpoint scope.
fn scope_name(scope: authorization.Scope) -> String {
  case authorization.scope("reports") {
    Ok(known) if known == scope -> "reports"
    _ -> "unknown"
  }
}

/// RFC 6750 §3 challenge with the RFC 9728 `resource_metadata` parameter.
pub fn challenge(failure: AuthFailure, metadata_url: String) -> wisp.Response {
  let metadata = "resource_metadata=\"" <> metadata_url <> "\""
  let #(status, header) = case failure {
    NoToken -> #(401, "Bearer " <> metadata)
    InvalidToken(description) -> #(
      401,
      "Bearer error=\"invalid_token\", error_description=\""
        <> description
        <> "\", "
        <> metadata,
    )
    WrongAudience -> #(
      401,
      "Bearer error=\"invalid_token\", error_description=\"the access token was issued for another resource\", "
        <> metadata,
    )
    InsufficientScope(scope) -> #(
      403,
      "Bearer error=\"insufficient_scope\", scope=\""
        <> scope
        <> "\", "
        <> metadata,
    )
    AuthorizationUnavailable -> #(503, "")
  }
  let response = wisp.response(status)
  case header {
    "" -> response
    _ -> wisp.set_header(response, "www-authenticate", header)
  }
}
