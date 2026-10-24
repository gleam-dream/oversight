// THROWAWAY: Can an ordinary web consumer require a verified identity?
import lab/warden
import lab/warden_transaction as transaction

pub fn profile(identity: warden.VerifiedIdentity) -> String {
  warden.subject(identity)
}

pub type CallbackResult {
  AuthenticatedProfile(String)
  CustodyRecoveryRequired(transaction.CustodyRecoveryCommand)
}

pub fn callback(
  store: transaction.TransactionStore,
  backend: transaction.VerificationBackend,
  custody_owner: warden.CustodyOwner,
  checked: transaction.CheckedOutcome,
) -> Result(CallbackResult, transaction.CompleteLoginError) {
  case warden.complete_login(store, backend, custody_owner, checked) {
    Ok(transaction.LoginCompleted(session)) ->
      Ok(AuthenticatedProfile(profile(warden.identity(session))))
    Ok(transaction.LoginRecoveryRequired(command)) ->
      Ok(CustodyRecoveryRequired(command))
    Error(e) -> Error(e)
  }
}
