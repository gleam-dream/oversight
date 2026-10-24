// THROWAWAY: Public consumption does not grant a reusable exchange capability.
import lab/warden_transaction as login

pub fn invalid(consumed: login.PublicConsumption) -> login.ExchangeRequest {
  consumed
}
