// THROWAWAY: Callback binding does not establish a verified login result.
import lab/hellhound_transaction as login

pub fn invalid(checked: login.CheckedOutcome) -> login.Session {
  checked
}
