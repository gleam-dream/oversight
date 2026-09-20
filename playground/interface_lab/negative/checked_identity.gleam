// THROWAWAY: Callback checks are not token verification.
import lab/warden
import lab/warden_transaction as login

pub fn invalid(checked: login.CheckedCallback) {
  warden.subject(checked)
}
