// THROWAWAY: Can an ordinary web consumer require a verified identity?
import lab/warden
import lab/warden_transaction as transaction

pub fn profile(identity: warden.VerifiedIdentity) -> String {
  warden.subject(identity)
}

pub fn callback(
  store: transaction.TransactionStore,
  backend: transaction.VerificationBackend,
  checked: transaction.CheckedOutcome,
) -> Result(String, transaction.CompleteLoginError) {
  case warden.complete_login(store, backend, checked) {
    Ok(session) -> Ok(profile(warden.identity(session)))
    Error(e) -> Error(e)
  }
}
