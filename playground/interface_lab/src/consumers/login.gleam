// THROWAWAY: Can an ordinary web consumer require a verified identity?
import lab/hellhound
import lab/hellhound_transaction as transaction

pub fn profile(identity: hellhound.VerifiedIdentity) -> String {
  hellhound.subject(identity)
}

pub type CallbackResult {
  AuthenticatedProfile(String)
  CustodyRecoveryRequired(transaction.CustodyRecoveryCommand)
}

pub fn callback(
  store: transaction.TransactionStore,
  backend: transaction.VerificationBackend,
  custody_owner: hellhound.CustodyOwner,
  checked: transaction.CheckedOutcome,
) -> Result(CallbackResult, transaction.CompleteLoginError) {
  case hellhound.complete_login(store, backend, custody_owner, checked) {
    Ok(transaction.LoginCompleted(session)) ->
      Ok(AuthenticatedProfile(profile(hellhound.identity(session))))
    Ok(transaction.LoginRecoveryRequired(command)) ->
      Ok(CustodyRecoveryRequired(command))
    Error(e) -> Error(e)
  }
}
