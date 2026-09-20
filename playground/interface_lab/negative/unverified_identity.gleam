// THROWAWAY: Reject a pending login where verification is required.
import consumers/login
import lab/warden_transaction as login_state

pub fn invalid(pending: login_state.Transaction) -> String {
  login.profile(pending)
}
