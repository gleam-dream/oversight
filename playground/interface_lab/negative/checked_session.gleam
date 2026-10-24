// THROWAWAY: Callback binding does not establish a verified login result.
import lab/warden_transaction as login

pub fn invalid(checked: login.CheckedOutcome) -> login.Session {
  checked
}
