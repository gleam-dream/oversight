// THROWAWAY: Only the canonical owner may construct an identity.
import lab/hellhound_transaction as login

pub fn invalid(
  issuer: login.Issuer,
  subject: String,
) -> login.VerifiedIdentity {
  login.VerifiedIdentity(issuer, subject)
}
