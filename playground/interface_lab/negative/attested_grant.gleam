// THROWAWAY: An adapter assertion has not passed resource admission.
import lab/relay_authorization as auth

pub fn invalid(
  assertion: auth.VerifierAttestation(String),
) -> auth.GrantedRequest(String) {
  assertion
}
