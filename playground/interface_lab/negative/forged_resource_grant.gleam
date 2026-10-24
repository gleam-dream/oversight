// THROWAWAY: Resource grants are constructed only after admission.
import lab/relay_authorization as auth

pub fn invalid(
  principal: String,
  resource: auth.Resource,
  scopes: List(auth.Scope),
) -> auth.GrantedRequest(String) {
  auth.GrantedRequest(principal, resource, scopes)
}
