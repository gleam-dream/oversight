// THROWAWAY: A configured backend assertion alone cannot issue identity.
import lab/hellhound
import lab/hellhound_transaction as login

pub fn invalid(attestation: login.BackendAttestation) -> String {
  hellhound.subject(attestation)
}
