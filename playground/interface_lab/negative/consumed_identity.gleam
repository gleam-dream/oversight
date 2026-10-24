// THROWAWAY: Consumption does not establish token verification.
import lab/hellhound
import lab/hellhound_transaction as login

pub fn invalid(consumed: login.PublicConsumption) -> String {
  hellhound.subject(consumed)
}
