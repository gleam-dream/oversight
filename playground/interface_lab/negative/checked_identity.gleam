// THROWAWAY: Callback checks are not token verification.
import lab/hellhound
import lab/hellhound_transaction as login

pub fn invalid(checked: login.CheckedOutcome) {
  hellhound.subject(checked)
}
