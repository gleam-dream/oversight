// THROWAWAY: A raw token is not an accepted resource grant.
import lab/relay_authorization as auth

pub fn invalid(token: auth.BearerToken) -> auth.GrantedRequest(String) {
  token
}
