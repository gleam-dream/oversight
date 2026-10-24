// THROWAWAY: Token roles cannot be substituted.
import lab/hellhound_transaction as transaction

pub fn invalid(
  refresh: transaction.RefreshToken,
  expiry: transaction.TokenExpiry,
) {
  transaction.token_material(
    refresh,
    transaction.NoRefreshToken,
    transaction.NoLogoutIdToken,
    expiry,
    [],
  )
}
