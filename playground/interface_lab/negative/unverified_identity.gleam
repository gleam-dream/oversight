// THROWAWAY: Reject a pending login where verification is required.
import consumers/login
import lab/warden

pub fn invalid(pending: warden.PendingLogin) -> String {
  login.profile(pending)
}
