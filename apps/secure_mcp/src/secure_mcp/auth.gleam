//// Bearer verification for `/mcp`: Relay verifiers backed by Hellhound. Relay's
//// `http.new_protected` reads the token, admits the request (audience and
//// endpoint scope) and renders every challenge; this module only turns
//// Hellhound's answer into Relay's attestation.

import gleam/option.{type Option, None, Some}
import hellhound
import hellhound/resource
import relay/authorization.{type Attestation, type Verifier}

/// The authenticated caller that tool handlers act for.
pub type Principal {
  Principal(subject: String, client_id: Option(String), scopes: List(String))
}

/// Local RFC 9068 validation: signature against the issuer's cached keys,
/// `typ` `at+jwt`, issuer, exact audience, `exp`, `nbf`/`iat`. No request per
/// token, so a revoked token stays valid until it expires.
pub fn jwt_verifier(validator: resource.Validator) -> Verifier(Principal) {
  let verify =
    resource.verifier(
      validator,
      authorization.token_value,
      attest,
      on_error: refuse,
    )
  use token, _correlation <- authorization.verifier("hellhound-jwt")
  verify(token)
}

fn refuse(kind: resource.ErrorKind) -> authorization.VerificationError {
  case kind {
    resource.Rejected | resource.Forbidden -> authorization.BearerRejected
    resource.WrongAudience -> authorization.IssuedForAnotherResource
    resource.Unavailable -> authorization.VerifierUnavailable
  }
}

fn attest(claims: resource.AccessClaims) -> Attestation(Principal) {
  let scopes = resource.scopes(claims)
  authorization.attestation(
    Principal(resource.subject(claims), resource.client_id(claims), scopes),
    resource.audiences(claims),
    scopes,
  )
}

/// RFC 7662 introspection: one provider request per MCP request, so a token
/// revoked at the provider is refused at once. The request's correlation tags
/// the provider call, so it joins the MCP request in telemetry.
pub fn introspection_verifier(client: hellhound.Client) -> Verifier(Principal) {
  use token, correlation <- authorization.verifier("hellhound-introspection")
  let client = hellhound.with_correlation(client, correlation)
  case hellhound.introspect(client, authorization.token_value(token)) {
    Ok(hellhound.ActiveToken(
      hellhound.TokenInfo(subject: Some(subject), ..) as info,
    )) ->
      Ok(authorization.attestation(
        Principal(subject, info.client_id, info.scopes),
        info.audiences,
        info.scopes,
      ))
    Ok(hellhound.ActiveToken(hellhound.TokenInfo(subject: None, ..))) ->
      Error(authorization.VerifierUnmapped)
    Ok(hellhound.InactiveToken) | Error(hellhound.IntrospectionTokenTooLarge) ->
      Error(authorization.BearerRejected)
    Error(hellhound.IntrospectionNotSupported)
    | Error(hellhound.IntrospectionFailed(_)) ->
      Error(authorization.VerifierUnavailable)
  }
}
