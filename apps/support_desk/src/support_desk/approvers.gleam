//// Who may answer a refund approval: an approver proves who they are with
//// a bearer access token from the desk's OIDC provider, and the desk builds
//// fabric's `Reviewer` from the validated claims. Nothing here takes a
//// name: the `sub` and `iss` come from a token that Warden verified.

import fabric/reviewer.{type Reviewer}
import gleam/result
import warden/resource

/// What an approver presents. The bearer value is the access token the
/// provider issued when the approver signed in.
pub type Credential {
  Bearer(token: String)
  /// Nothing was presented: an unauthenticated caller.
  Anonymous
}

/// Why a credential did not become a reviewer.
pub type Error {
  /// No credential: the caller is not signed in.
  NotSignedIn
  /// The token failed validation (expired, forged, wrong issuer, unsigned,
  /// malformed). The reason is for logs, not for the caller.
  Rejected(reason: String)
  /// A valid token issued for another resource.
  WrongAudience
  /// The issuer's keys are unavailable: nothing was decided, try again.
  Unavailable
  /// The claims are valid but fabric refuses them as a reviewer (an empty or
  /// over-long `sub` or `iss`).
  Unusable(reason: String)
}

/// The validator of the desk's approver tokens.
pub opaque type Approvers {
  Approvers(validator: resource.Validator)
}

pub fn new(validator: resource.Validator) -> Approvers {
  Approvers(validator)
}

/// The reviewer a credential vouches for: its validated `sub`, vouched for
/// by its validated `iss`.
pub fn authenticate(
  approvers: Approvers,
  credential: Credential,
) -> Result(Reviewer, Error) {
  case credential {
    Anonymous -> Error(NotSignedIn)
    Bearer(token) -> {
      use claims <- result.try(
        resource.verify(approvers.validator, token)
        |> result.map_error(fn(error) {
          case resource.error_kind(error) {
            resource.WrongAudience -> WrongAudience
            resource.Unavailable -> Unavailable
            resource.Rejected | resource.Forbidden ->
              Rejected(resource.describe_error(error))
          }
        }),
      )
      reviewer.new(resource.subject(claims))
      |> result.try(reviewer.with_issuer(_, resource.issuer(claims)))
      |> result.map_error(fn(error) { Unusable(reviewer.describe_error(error)) })
    }
  }
}

pub fn describe(error: Error) -> String {
  case error {
    NotSignedIn -> "the approver is not signed in"
    Rejected(reason) -> "the approver's token was refused: " <> reason
    WrongAudience -> "the approver's token was issued for another resource"
    Unavailable -> "the identity provider's keys are unavailable"
    Unusable(reason) -> "the token's identity is unusable: " <> reason
  }
}
