// THROWAWAY: Reservation status cannot substitute for an exact publication command.
import lab/warden_transaction as warden

pub fn invalid(
  owner: warden.CustodyOwner,
  recovery: warden.RefreshReservationRecovery,
) {
  warden.recover_refresh_publication(owner, recovery)
}
