// THROWAWAY: A configured backend assertion alone cannot issue identity.
import lab/warden
import lab/warden_transaction as login

pub fn invalid(attestation: login.BackendAttestation) -> String {
  warden.subject(attestation)
}
