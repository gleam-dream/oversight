// THROWAWAY: Refresh cannot repeat the authorization-code exchange backend.
import lab/hellhound_transaction as hellhound

pub fn invalid(
  owner: hellhound.CustodyOwner,
  backend: hellhound.VerificationBackend,
  session: hellhound.Session,
  command: hellhound.RefreshCommandId,
) {
  hellhound.refresh_session(owner, backend, session, command)
}
