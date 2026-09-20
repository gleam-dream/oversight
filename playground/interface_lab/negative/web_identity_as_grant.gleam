// THROWAWAY: Web login identity cannot replace bearer resource authorization.
import lab/relay_authorization as auth
import lab/warden

pub fn invalid(
  identity: warden.VerifiedIdentity,
) -> auth.GrantedRequest(String) {
  identity
}
