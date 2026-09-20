// THROWAWAY: Can a pending OIDC login stand in for a verified request identity?
import consumers/request_scoped_tools as request_tools
import lab/warden

pub fn context_from_pending(
  tenant: request_tools.TenantId,
  pending: warden.PendingLogin,
) -> request_tools.RequestContext {
  request_tools.RequestContext(tenant, pending)
}
