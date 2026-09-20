// THROWAWAY: Can a pending OIDC login stand in for a verified request identity?
import consumers/request_scoped_tools as request_tools
import lab/warden_transaction as login_state

pub fn context_from_pending(
  tenant: request_tools.TenantId,
  pending: login_state.Transaction,
) -> request_tools.RequestContext {
  request_tools.RequestContext(tenant, pending)
}
