// THROWAWAY: Can only the canonical login owner issue a verified identity?
import lab/hellhound_transaction as transaction

pub type VerifiedIdentity =
  transaction.VerifiedIdentity

pub type Session =
  transaction.Session

pub type CustodyOwner =
  transaction.CustodyOwner

pub type LoginCompletion =
  transaction.LoginCompletion

pub type CustodyRecoveryCommand =
  transaction.CustodyRecoveryCommand

pub type CustodyRecoveryResult =
  transaction.CustodyRecoveryResult

pub type CustodyRecoveryError =
  transaction.CustodyRecoveryError

pub type CustodyReference =
  transaction.CustodyReference

pub type CustodyRevision =
  transaction.CustodyRevision

pub type ProviderBinding =
  transaction.ProviderBinding

pub fn complete_login(
  store: transaction.TransactionStore,
  backend: transaction.VerificationBackend,
  custody_owner: CustodyOwner,
  checked: transaction.CheckedOutcome,
) -> Result(LoginCompletion, transaction.CompleteLoginError) {
  transaction.complete_login(store, backend, custody_owner, checked)
}

pub fn recover_custody(
  owner: CustodyOwner,
  recovery: CustodyRecoveryCommand,
) -> Result(CustodyRecoveryResult, CustodyRecoveryError) {
  transaction.recover_custody(owner, recovery)
}

pub fn identity(session: Session) -> VerifiedIdentity {
  transaction.session_identity(session)
}

pub fn custody_reference(session: Session) -> CustodyReference {
  transaction.session_custody_reference(session)
}

pub fn custody_revision(session: Session) -> CustodyRevision {
  transaction.session_custody_revision(session)
}

pub fn provider_binding(session: Session) -> ProviderBinding {
  transaction.session_provider_binding(session)
}

pub fn subject(identity: VerifiedIdentity) -> String {
  transaction.verified_subject(identity)
}

pub fn identity_key(
  identity: VerifiedIdentity,
) -> #(transaction.Issuer, String) {
  #(transaction.verified_issuer(identity), subject(identity))
}
