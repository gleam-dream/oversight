// THROWAWAY: A storage reference does not attest identity.
import lab/hellhound
import lab/hellhound_transaction as transaction

pub fn invalid(reference: transaction.CustodyReference) {
  hellhound.subject(reference)
}
