// THROWAWAY: Can callers distinguish pending login from verified identity?
pub opaque type PendingLogin {
  PendingLogin(state: String, nonce: String)
}

pub opaque type VerifiedIdentity {
  VerifiedIdentity(issuer: String, subject: String)
}

pub type VerificationError {
  InvalidState
  InvalidNonce
  InvalidIssuer
  InvalidSignature
  Expired
  ProviderUnavailable
}

pub fn begin_login() -> Result(PendingLogin, VerificationError) {
  todo as "OIDC provider and secure state generation are not implemented"
}

pub fn verify_callback(
  _pending: PendingLogin,
  _callback: String,
) -> Result(VerifiedIdentity, VerificationError) {
  todo as "oidcc verification and caller-owned replay checks are not implemented"
}

pub fn subject(identity: VerifiedIdentity) -> String {
  identity.subject
}
