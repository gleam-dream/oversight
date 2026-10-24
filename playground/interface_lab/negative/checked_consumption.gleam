// THROWAWAY: Checking a callback does not establish consumption.
import lab/warden_transaction as login

pub fn invalid(checked: login.CheckedOutcome) -> login.PublicConsumption {
  checked
}
