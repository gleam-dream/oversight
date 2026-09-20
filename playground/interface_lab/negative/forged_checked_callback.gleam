// THROWAWAY: A callback witness cannot be rebound to another transaction.
import lab/warden_transaction as login

pub fn invalid(
  transaction: login.Transaction,
  revision: login.StoredRevision,
  code: login.AuthorizationCode,
) -> login.CheckedCallback {
  login.CheckedCallback(transaction, revision, code)
}
