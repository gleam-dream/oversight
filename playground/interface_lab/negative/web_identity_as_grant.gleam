// THROWAWAY: Web login identity cannot replace bearer resource authorization.
import lab/hellhound
import lab/relay_authorization as auth

pub fn invalid(
  identity: hellhound.VerifiedIdentity,
) -> auth.GrantedRequest(String) {
  identity
}
