// THROWAWAY: Consumption does not establish token verification.
import lab/warden
import lab/warden_transaction as login

pub fn invalid(consumed: login.PublicConsumption) -> String {
  warden.subject(consumed)
}
