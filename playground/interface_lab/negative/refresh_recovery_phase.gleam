// THROWAWAY: Reservation status cannot substitute for an exact publication command.
import lab/hellhound_transaction as hellhound

pub fn invalid(
  owner: hellhound.CustodyOwner,
  recovery: hellhound.RefreshReservationRecovery,
) {
  hellhound.recover_refresh_publication(owner, recovery)
}
