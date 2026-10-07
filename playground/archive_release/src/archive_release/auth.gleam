import archive_release/domain.{type Principal, Principal}
import fabric/approvers
import fabric/reviewer
import gleam/list
import gleam/result
import relay/authorization
import sinal/correlation
import warden/resource

pub const audience = "https://archive.example.test"

pub fn admit(
  validator: resource.Validator,
  raw: String,
) -> Result(Principal, authorization.AdmissionError) {
  let verify =
    resource.verifier(
      validator,
      authorization.token_value,
      attest,
      on_error: refuse,
    )
  let verifier =
    authorization.verifier("archive-warden", fn(token, _correlation) {
      verify(token)
    })
  let assert Ok(endpoint) = authorization.protected_resource(audience)
  let assert Ok(scope) = authorization.scope("archive:release")
  let protection = authorization.protection(endpoint, [scope])
  use token <- result.try(
    authorization.bearer_token(raw)
    |> result.map_error(fn(_) { authorization.MissingToken }),
  )
  authorization.admit(
    verifier,
    token,
    protection,
    correlation.from_key("archive"),
  )
  |> result.map(authorization.grant_principal)
}

fn attest(
  claims: resource.AccessClaims,
) -> authorization.Attestation(Principal) {
  authorization.attestation(
    Principal(resource.issuer(claims), resource.subject(claims)),
    resource.audiences(claims),
    resource.scopes(claims),
  )
}

fn refuse(kind: resource.ErrorKind) -> authorization.VerificationError {
  case kind {
    resource.Rejected | resource.Forbidden -> authorization.BearerRejected
    resource.WrongAudience -> authorization.IssuedForAnotherResource
    resource.Unavailable -> authorization.VerifierUnavailable
  }
}

/// Build once per driver and share the exact value between agent and handler.
pub fn approvers(validator: resource.Validator) -> approvers.Approvers(String) {
  use token, requirement <- approvers.new("archive-warden")
  use claims <- result.try(
    resource.verify(validator, token) |> result.map_error(denial),
  )
  case list.contains(resource.scopes(claims), "approve:" <> requirement.name) {
    False -> Error(approvers.NotAuthorized("missing approval scope"))
    True ->
      reviewer.new(resource.subject(claims))
      |> result.try(reviewer.with_issuer(_, resource.issuer(claims)))
      |> result.map_error(fn(error) {
        approvers.NotAuthenticated(reviewer.describe_error(error))
      })
  }
}

fn denial(error: resource.TokenError) -> approvers.Denial {
  let detail = resource.describe_error(error)
  case resource.error_kind(error) {
    resource.Rejected | resource.WrongAudience ->
      approvers.NotAuthenticated(detail)
    resource.Forbidden -> approvers.NotAuthorized(detail)
    resource.Unavailable -> approvers.Unavailable(detail)
  }
}
