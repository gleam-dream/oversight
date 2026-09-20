// THROWAWAY: A storage reference does not attest identity.
import lab/warden
import lab/warden_transaction as transaction

pub fn invalid(reference: transaction.CustodyReference) {
  warden.subject(reference)
}
