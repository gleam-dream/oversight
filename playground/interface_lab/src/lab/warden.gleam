// THROWAWAY: Can only the canonical login owner issue a verified identity?
import lab/warden_transaction as transaction

pub type VerifiedIdentity =
  transaction.VerifiedIdentity

pub type Session =
  transaction.Session

pub fn complete_login(
  store: transaction.TransactionStore,
  backend: transaction.VerificationBackend,
  checked: transaction.CheckedOutcome,
) -> Result(Session, transaction.CompleteLoginError) {
  transaction.complete_login(store, backend, checked)
}

pub fn identity(session: Session) -> VerifiedIdentity {
  transaction.session_identity(session)
}

pub fn subject(identity: VerifiedIdentity) -> String {
  transaction.verified_subject(identity)
}

pub fn identity_key(
  identity: VerifiedIdentity,
) -> #(transaction.Issuer, String) {
  #(transaction.verified_issuer(identity), subject(identity))
}
