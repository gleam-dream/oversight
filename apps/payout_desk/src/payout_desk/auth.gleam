//// Bearer verification for the desk's MCP endpoint: a Relay verifier backed
//// by Hellhound, as `secure_mcp` does it. Relay's `http.new_protected`
//// reads the token, admits the request (audience and endpoint scope) and
//// renders every challenge; this module turns Hellhound's answer into
//// Relay's attestation.
////
//// The token proves who the caller is. It does not say which decision sets
//// they hold: the application decides that (`db.validator`).

import hellhound/resource
import relay/authorization.{type Attestation, type Verifier}

/// The authenticated person a desk tool acts for.
pub type Principal {
  Principal(subject: String)
}

/// The endpoint scope every desk call must carry.
pub const scope = "payouts"

/// Local RFC 9068 validation: signature against the issuer's keys, `typ`
/// `at+jwt`, issuer, exact audience, `exp`, `nbf` and `iat`.
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
    Principal(resource.subject(claims)),
    resource.audiences(claims),
    scopes,
  )
}
