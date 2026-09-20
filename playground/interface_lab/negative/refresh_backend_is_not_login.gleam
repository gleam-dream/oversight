// THROWAWAY: Refresh cannot repeat the authorization-code exchange backend.
import lab/warden_transaction as warden

pub fn invalid(
  owner: warden.CustodyOwner,
  backend: warden.VerificationBackend,
  session: warden.Session,
  command: warden.RefreshCommandId,
) {
  warden.refresh_session(owner, backend, session, command)
}
