// THROWAWAY: Can application policy relate web identity to an independent API grant?
import consumers/request_scoped_tools.{type RequestContext}
import lab/relay
import lab/relay_authorization as auth
import lab/warden
import lab/warden_transaction as login

// This is an application account mapping, not a generic token-claim convention.
pub type ApiPrincipal {
  ApiPrincipal(account_issuer: login.Issuer, account_subject: String)
}

pub fn protect(
  config: auth.ProtectionConfig,
  registry: relay.Registry(RequestContext),
) -> auth.ProtectedRegistry(RequestContext, ApiPrincipal) {
  auth.protect_registry(
    config,
    registry,
    auth.tool_policy(
      fn(context, grant, _declaration) {
        case same_account(context, grant) {
          True -> auth.Visible
          False -> auth.Hidden
        }
      },
      fn(context, grant, _declaration) {
        case same_account(context, grant) {
          True -> auth.ExecutionAuthorized
          False -> auth.ExecutionUnauthorized
        }
      },
    ),
  )
}

fn same_account(
  context: RequestContext,
  grant: auth.GrantedRequest(ApiPrincipal),
) -> Bool {
  let ApiPrincipal(issuer, subject) = auth.grant_principal(grant)
  warden.identity_key(context.identity) == #(issuer, subject)
}
